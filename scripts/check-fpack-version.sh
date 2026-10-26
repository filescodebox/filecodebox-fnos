#!/usr/bin/env bash
# 门禁：fnos 应用包(fpk)里的二进制版本戳必须 == 仓内 VERSION（不许打进旧产物）。
#
# 缺陷实录（2026-10-26 审计 P2）：`make fpack` **不重建任何产物**（只
# `cd fnos && fnpack build`）⇒ 工作区里 fnos/app/bin/ 躺着的**陈旧二进制**
# （gitignored 但真实存在）会被打进一个「能装」的 fpk ⇒ 用户装到 NAS 上的是
# 旧版本，而包本身看起来是新的（manifest 的 version 是新的）⇒ 版本幽灵。
#
# 本门禁断言：
#   V1 打包目录里的双架构二进制存在，且**内嵌版本戳 == VERSION**；
#   V2 若已有 fpk ⇒ 解包 ⇒ app.tgz 里的二进制版本戳同样 == VERSION
#      （这是真正发出去的那一份）；
#   V3 前端 version.txt == web/package.json 的 version（复用 build-native.sh
#      的版本自证口径）。
#
# 负对照：跳过 build-native.sh 直接打包（用旧 app/bin）⇒ V1/V2 必须红。
#
# 用法: bash scripts/check-fpack-version.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

VERSION="$(cat VERSION 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "找不到 VERSION"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 二进制内嵌的版本戳（go build -ldflags -X version.Version=… ⇒ 记在 build info 里）
stamp_of() { # <二进制>
  go version -m "$1" 2>/dev/null \
    | sed -n 's/.*version\.Version=\([^ '"'"']*\).*/\1/p' \
    | head -1
}

# 版本戳是否匹配 VERSION（允许 "4.0.1" / "v4.0.1" / "v4.0.1-3-gabc" 形态）
stamp_matches() { # <stamp>
  local s="$1"
  [ -n "$s" ] || return 1
  s="${s#v}"
  [ "$s" = "$VERSION" ] && return 0
  case "$s" in "$VERSION"|"$VERSION"-*|"$VERSION".*) return 0 ;; esac
  return 1
}

echo "── V1 打包目录里的二进制版本戳必须 == VERSION(${VERSION})"
for arch in amd64 arm64; do
  BIN="fnos/app/bin/pigeonbox-linux-${arch}"
  if [ ! -f "$BIN" ]; then
    bad "V1 缺 $BIN" "先跑 scripts/build-native.sh"
    continue
  fi
  ST="$(stamp_of "$BIN")"
  if stamp_matches "$ST"; then
    ok "V1 ${arch} 版本戳 = ${ST}"
  else
    bad "V1 ${arch} 版本戳 = ${ST:-无}" "≠ VERSION ${VERSION} ⇒ 陈旧产物（先跑 scripts/build-native.sh）"
  fi
done

echo "── V3 前端版本戳（打包目录）必须 == web/package.json 的 version"
PKGV="$(node -p "require('./web/package.json').version" 2>/dev/null || echo "")"
if [ -f "fnos/app/www/version.txt" ]; then
  WEBV="$(tr -d ' \t\r\n' < "fnos/app/www/version.txt")"
  if [ -z "$PKGV" ] || [ "$WEBV" = "$PKGV" ]; then
    ok "V3 打包目录前端版本戳 = ${WEBV}"
  else
    bad "V3 打包目录前端版本戳 = ${WEBV}" "≠ web/package.json ${PKGV} ⇒ 前端产物也是陈旧的"
  fi
else
  bad "V3 打包目录缺 fnos/app/www/version.txt" "先跑 scripts/build-native.sh"
fi

echo "── V2 已产出的 fpk 内嵌二进制版本戳必须 == VERSION"
FPK="fnos/pigeonbox.fpk"
if [ ! -f "$FPK" ]; then
  ok "V2 尚无 fpk（跳过；make fpack 产出后再验）"
else
  ( cd "$WORK" && tar xzf "$ROOT/$FPK" ) 2>/dev/null \
    || { bad "V2 fpk 解不开" "$FPK"; }
  if [ -f "$WORK/app.tgz" ]; then
    ( cd "$WORK" && tar xzf app.tgz ) 2>/dev/null || true
    for arch in amd64 arm64; do
      BIN="bin/pigeonbox-linux-${arch}"
      if [ ! -f "$WORK/$BIN" ]; then
        bad "V2 fpk 内缺 $BIN" "-"
        continue
      fi
      ST="$(stamp_of "$WORK/$BIN")"
      if stamp_matches "$ST"; then
        ok "V2 fpk 内 ${arch} 版本戳 = ${ST}"
      else
        bad "V2 fpk 内 ${arch} 版本戳 = ${ST:-无}" "≠ VERSION ${VERSION} ⇒ 打进的是陈旧二进制"
      fi
    done
    # 前端版本戳（复用 build-native.sh 的版本自证口径）
    if [ -f "$WORK/www/version.txt" ]; then
      WEBV="$(tr -d ' \t\r\n' < "$WORK/www/version.txt")"
      PKGV="$(node -p "require('./web/package.json').version" 2>/dev/null || echo "")"
      if [ -z "$PKGV" ] || [ "$WEBV" = "$PKGV" ]; then
        ok "V3 fpk 内前端版本戳 = ${WEBV}"
      else
        bad "V3 fpk 内前端版本戳 = ${WEBV}" "≠ web/package.json ${PKGV}"
      fi
    else
      bad "V3 fpk 内缺 www/version.txt" "-"
    fi
  else
    bad "V2 fpk 内无 app.tgz" "-"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✓ fnos fpack 版本戳守卫通过（== ${VERSION}）"
