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
# 当前 HEAD 的短哈希 =「产物是不是当次构建」的判据（见 stamp_commit_of 的口径说明）
HEAD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"

WORK="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# 二进制内嵌的**构建 commit**（go build -ldflags -X version.BuildCommit=… ⇒ 记在 build info 里）
#
# ⚠️ 口径说明（2026-10-26 实测修正）：**不能拿它跟仓内 VERSION 文件比**。
#   build-native.sh 的 VERSION 缺省取 `git describe --tags --always`
#   ⇒ CI 的浅克隆/游离 HEAD **没有 tag** ⇒ describe 退化成**短 commit 哈希**
#   ⇒ 实测 fnos CI 里版本戳是 "bd70064"（commit）而不是 "4.0.2"（包版本号）
#   ⇒ 拿包版本号去比 ⇒ 门禁**恒红**（4.0.2 列车 PR 上就红了）。
#
#   真正要判的是「**打进包的是不是陈旧产物**」⇒ 正确的判据是
#   **二进制的 BuildCommit == 当前 HEAD 的短哈希**：
#   陈旧产物是从旧 commit 构建的 ⇒ 哈希不等 ⇒ 变红 ✓；
#   而「包版本号」由 VERSION 文件与前端 version.txt 另行对账（V3）。
stamp_commit_of() { # <二进制>
  go version -m "$1" 2>/dev/null \
    | sed -n 's/.*version\.BuildCommit=\([^ '"'"']*\).*/\1/p' \
    | head -1
}

# 二进制的内嵌版本串（非空即可 ⇒ ldflags 生效）
stamp_version_of() { # <二进制>
  go version -m "$1" 2>/dev/null \
    | sed -n 's/.*version\.Version=\([^ '"'"']*\).*/\1/p' \
    | head -1
}

# 构建 commit 是否 == 当前 HEAD（防陈旧产物）
stamp_matches() { # <stamp>
  local s="$1"
  [ -n "$s" ] || return 1
  [ -n "$HEAD_COMMIT" ] || return 1
  [ "$s" = "$HEAD_COMMIT" ]
}

echo "── V1 打包目录里的二进制必须是当次构建（BuildCommit == HEAD ${HEAD_COMMIT}）"
for arch in amd64 arm64; do
  BIN="fnos/app/bin/pigeonbox-linux-${arch}"
  if [ ! -f "$BIN" ]; then
    bad "V1 缺 $BIN" "先跑 scripts/build-native.sh"
    continue
  fi
  ST="$(stamp_commit_of "$BIN")"
  SV="$(stamp_version_of "$BIN")"
  if stamp_matches "$ST"; then
    ok "V1 ${arch} 构建 commit = ${ST}（版本串 ${SV:-无}）"
  else
    bad "V1 ${arch} 构建 commit = ${ST:-无}" "≠ HEAD ${HEAD_COMMIT} ⇒ 陈旧产物（先跑 scripts/build-native.sh）"
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

echo "── V2 已产出的 fpk 内嵌二进制必须是当次构建（BuildCommit == HEAD）"
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
      ST="$(stamp_commit_of "$WORK/$BIN")"
      if stamp_matches "$ST"; then
        ok "V2 fpk 内 ${arch} 构建 commit = ${ST}"
      else
        bad "V2 fpk 内 ${arch} 构建 commit = ${ST:-无}" "≠ HEAD ${HEAD_COMMIT} ⇒ 打进的是陈旧二进制"
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
echo "✓ fnos fpack 产物新鲜度守卫通过（构建 commit == HEAD ${HEAD_COMMIT}）"
OK=1
