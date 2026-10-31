#!/usr/bin/env bash
# 构建原生 fpk 产物:双架构静态二进制 + 前端 dist,落入 fnos/(打包目录)。
#
# 产物(均被 gitignore,fnpack build 前必须先跑本脚本):
#   fnos/app/bin/pigeonbox-linux-amd64
#   fnos/app/bin/pigeonbox-linux-arm64
#   fnos/app/www/            (前端构建产物)
#
# 前端来源(2026-10-09 拆仓:web 适配器+构建自包含在本仓 web/):
#   1. FRONTEND_DIST 环境变量指定的现成 dist 目录(直接拷贝,跳过构建)
#   2. 本仓 web/(fnOS 宿主适配器+@pigeonbox/frontend-core tgz 钉版,见 web/package.json)
# 不再克隆 frontend 仓——fpk web 内容随本仓提交可复现;类型检查由 fnos CI 把守。
#
# 版本注入:VERSION/COMMIT 环境变量优先,缺省取 git describe/rev-parse。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK_DIR="$ROOT/fnos"
BIN_DIR="$PACK_DIR/app/bin"
WWW_DIR="$PACK_DIR/app/www"

VERSION=${VERSION:-"$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)"}
COMMIT=${COMMIT:-"$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"}
BUILD_TIME=${BUILD_TIME:-"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LDFLAGS="-w -s -X 'github.com/oekit/core/version.Version=${VERSION}' -X 'github.com/oekit/core/version.BuildCommit=${COMMIT}' -X 'github.com/oekit/core/version.BuildTime=${BUILD_TIME}'"

echo "==> 构建原生二进制 (CGO_ENABLED=0 静态链接,纯 Go sqlite)"
mkdir -p "$BIN_DIR"
for arch in amd64 arm64; do
  echo "    GOOS=linux GOARCH=${arch}"
  # GOWORK=off:保证构建严格按 go.mod 钉版(否则 hub go.work 联编本地 core main,
  # 产物含未发布代码且不可复现——真机修复到位性依赖钉版)。
  CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH=${arch} \
    go build -C "$ROOT" -ldflags="${LDFLAGS}" \
    -o "$BIN_DIR/pigeonbox-linux-${arch}" ./cmd/fnos-adapter
done

# ── 随包 p2pc/p2pcweb 设备直传(2026-10-14 对称节点 P2b;A2 起含网页客户端) ──
# 版本=DEPS.env P2PC_REF(列车写 terminal.p2pc_ref;缺省跳过=直传不可用优雅降级)。
# 下载顺序 curl → gh release download(本机 github 直连被断时兜底);
# checksums.txt 侧车强制校验(供应链:资产完整性)。
fetch_p2pc() {
  local ref="$1" dest="$2" triple="$3" prefix="$4"
  local asset="${prefix}-${triple}" base="https://github.com/pigeonbox/p2p/releases/download/${ref}"
  local tmp; tmp="$(mktemp -d)"
  local ok=""
  if curl -fsSL -m 60 -o "$tmp/checksums.txt" "${base}/p2pc-checksums.txt" 2>/dev/null \
     && curl -fsSL -m 300 -o "$tmp/${asset}" "${base}/${asset}" 2>/dev/null; then
    ok=1
  elif command -v gh >/dev/null 2>&1; then
    gh release download "$ref" -R pigeonbox/p2p -p "${asset}" -O "$tmp/${asset}" --clobber \
      && gh release download "$ref" -R pigeonbox/p2p -p p2pc-checksums.txt -O "$tmp/checksums.txt" --clobber \
      && ok=1
  fi
  if [ -z "$ok" ]; then
    echo "✗ ${asset}@${ref} 下载失败(curl/gh 均不可用或失败)"; rm -rf "$tmp"; return 1
  fi
  if ! (cd "$tmp" && grep " ${asset}\$" checksums.txt | shasum -a 256 -c - >/dev/null); then
    echo "✗ ${asset}@${ref} sha256 校验失败"; rm -rf "$tmp"; return 1
  fi
  install -m 0755 "$tmp/${asset}" "$dest"
  rm -rf "$tmp"
  echo "    ✓ ${prefix} ${triple} @ ${ref}"
}

echo "==> 随包 p2pc/p2pcweb(设备直传+网页客户端)"
P2PC_REF=$(sed -n 's/^P2PC_REF=//p' "$ROOT/DEPS.env" | tr -d ' \r')
if [ -n "$P2PC_REF" ]; then
  for arch in amd64 arm64; do
    case "$arch" in
      amd64) triple=x86_64-unknown-linux-gnu ;;
      arm64) triple=aarch64-unknown-linux-gnu ;;
    esac
    fetch_p2pc "$P2PC_REF" "$BIN_DIR/p2pc-linux-${arch}" "$triple" p2pc
    fetch_p2pc "$P2PC_REF" "$BIN_DIR/p2pcweb-linux-${arch}" "$triple" p2pc-web
  done
else
  echo "    (DEPS.env 无 P2PC_REF,跳过——包内直传不可用,优雅降级)"
fi

# ── 随包 pb CLI(官方命令行客户端:doctor 自检等)────────────────────────
#
# # 为什么从**源码**编译而不是下载 server Release 的二进制资产
#
# fnOS 与 server 的 Release 由**同号 tag 同时触发** ⇒ 若这里去下载 server
# Release 的 `pb_linux_amd64` 资产,就会与 server 的 Release 流水线**竞态**
# (资产还没构建完就下载 ⇒ 拿不到 ⇒ fpk 构建失败)。
# ⇒ 改为**检出 server 同号 tag 的源码**本地编译 ⇒ **git tag 立即可见**
# (不需要等任何流水线) ⇒ 零竞态。
#
# # 为什么 pb 适合这么干
#
# `cmd/pb` 是**纯 HTTP 客户端**:不链接 core(只用 oekit/pkg/cli)⇒
# 依赖极小(实测 199 个包 / 编译 3.5 秒 / 产物 6.5MB)⇒ 不拖慢 fpk 构建。
#
# # 版本对齐
#
# server 的 tag 与 fnOS 的 tag **同号**(列车的 terminal.fnos.tag = images.server
# 的号,如都是 v4.6.5)⇒ pb 的版本天然与包内服务端一致 ⇒ 不需要额外版本位。
#
# # 失败怎么办
#
# 编译失败 ⇒ **优雅降级**(包内无 pb,应用照常可用)⇒ 不阻断 fpk 发布。
# (与 p2pc「包内无此文件时优雅跳过」同款纪律。)
echo "==> 构建 pb CLI(官方命令行客户端)"
# server 的同号 tag（如 v4.6.5）——**取自仓内 VERSION 文件**（列车写的真相源）。
#
# ⚠️ 不要用 `git describe`：CI 是**浅克隆且无 tag** ⇒ describe 退化成 commit 哈希
#   （实测得到 "97732e1"）⇒ 拼出的 "v97732e1" 在 GitHub 上不存在
#   ⇒ 检出失败 ⇒ pb 静默降级 ⇒ **门禁会红但看不出根因**。
#
# ⚠️ 也不要用环境变量 ${VERSION}：CI 的原生产物构建步骤**不注入** VERSION
#   （release.yml 才有）⇒ 本地/CI 行为不一致 ⇒ 同一份代码两种结果。
#
# 兜底：PB_SERVER_REF 可由构建环境显式指定（本地调试用）。
PB_SERVER_REF="${PB_SERVER_REF:-}"
if [ -z "$PB_SERVER_REF" ]; then
  _pb_ver="$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null || true)"
  if [ -n "$_pb_ver" ]; then
    PB_SERVER_REF="v${_pb_ver}"
  else
    PB_SERVER_REF="v${VERSION}"
  fi
fi
echo "    server ref = ${PB_SERVER_REF}"
PB_SRC=""
_pb_ok=1
for arch in amd64 arm64; do
  if [ -z "$PB_SRC" ]; then
    PB_SRC="$(mktemp -d)/server"
    echo "    检出 server ${PB_SERVER_REF} 源码"
    if ! git clone -q --depth 1 --branch "$PB_SERVER_REF" \
         https://github.com/pigeonbox/server.git "$PB_SRC" 2>/dev/null; then
      echo "    ✗ server ${PB_SERVER_REF} 源码检出失败——pb 优雅降级(包内无 pb)"
      _pb_ok=0
      break
    fi
  fi
  echo "    GOOS=linux GOARCH=${arch}"
  if ! (cd "$PB_SRC" && CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH="${arch}" \
        go build -trimpath -ldflags="-w -s" \
        -o "$BIN_DIR/pb-linux-${arch}" ./cmd/pb) 2>/dev/null; then
    echo "    ✗ pb(${arch}) 编译失败——该架构无 pb(其余架构照常)"
    rm -f "$BIN_DIR/pb-linux-${arch}" 2>/dev/null || true
    continue
  fi
  echo "    ✓ pb-linux-${arch} ($(du -h "$BIN_DIR/pb-linux-${arch}" | cut -f1))"
done
# ⚠️ 只有**两个架构都没成**时才判整体降级；单个架构失败不牵连另一个
#   （NAS 上 x86_64 与 arm64 各占一半，删掉能用的那个等于半数用户拿不到 pb）。
if [ "$_pb_ok" = "1" ] && ! ls "$BIN_DIR"/pb-linux-* >/dev/null 2>&1; then
  echo "    ✗ pb 两个架构均不可用——优雅降级(包内无 pb,应用照常)"
fi
if [ -n "$PB_SRC" ]; then
  rm -rf "$(dirname "$PB_SRC")" 2>/dev/null || true
fi

echo "==> 构建前端 dist → $WWW_DIR"
rm -rf "$WWW_DIR"
if [ -n "${FRONTEND_DIST:-}" ]; then
  cp -R "$FRONTEND_DIST/." "$WWW_DIR"
  echo "    使用现成 dist: $FRONTEND_DIST"
else
  SRC="$ROOT/web"
  cd "$SRC"
  [ -d node_modules ] || npm ci --no-audit --no-fund
  # APP_VERSION=页脚「前端版本」(缺省=web/package.json version,与
  # frontend-core tgz 钉版同步;可由构建环境覆盖)
  APP_VERSION="${APP_VERSION:-$(node -p "require('./package.json').version")}" \
    npx vite build --outDir "$WWW_DIR" --emptyOutDir
fi


# ── 版本戳自证：二进制内嵌版本必须 == 本次构建的 VERSION（构建即断言）──────
# 为什么加这条（2026-10-26 审计 P2）：`make fpack` 曾**不重建任何产物** ⇒
# 工作区里 fnos/app/bin/ 的陈旧二进制会被打进一个「能装」的 fpk（版本幽灵）。
# ⇒ 打包前先重建（Makefile 的 fpack 目标已改为先跑本脚本）+ 这里断言
#   「产物里的版本戳 == 本次构建声明的版本」⇒ 陈旧产物进不了包。
for _arch in amd64 arm64; do
  _bin="$BIN_DIR/pigeonbox-linux-${_arch}"
  _stamp="$(go version -m "$_bin" 2>/dev/null | sed -n 's/.*version\.Version=\([^ '"'"']*\).*/\1/p' | head -1)"
  if [ "$_stamp" != "$VERSION" ]; then
    echo "✗ ${_bin} 内嵌版本戳 = ${_stamp:-无} ≠ 本次构建 VERSION=${VERSION}（ldflags 没生效?）" >&2
    exit 1
  fi
done
echo "    版本自证 ✓ 双架构二进制内嵌版本戳 = ${VERSION}"

# 陈旧 fpk 清理（2026-10-26 审计 P2）：二进制刚被重建 ⇒ 上一次打出来的
# pigeonbox.fpk **内容已过期** ⇒ 删掉，免得它被误当成新包发出去/装到 NAS 上。
if [ -f "$PACK_DIR/pigeonbox.fpk" ]; then
  rm -f "$PACK_DIR/pigeonbox.fpk"
  echo "    已清理陈旧 fpk（二进制已重建 ⇒ 旧包内容过期；需重新 fnpack build）"
fi

# ── 版本戳自证(2026-10-12 版本幽灵根治) ──────────────────────────
# web 版本单一来源 = APP_VERSION 环境变量 / web/package.json;构建即写
# version.txt 并断言 dist 内戳一致,不一致=构建红。运维验收一条
# curl -s <host>/version.txt 即可验真,永别「页脚是几」猜谜与缓存伪影。
WEB_VERSION="${APP_VERSION:-$(node -p "require('$ROOT/web/package.json').version")}"
printf '%s\n' "$WEB_VERSION" > "$WWW_DIR/version.txt"
grep -rqF "$WEB_VERSION" "$WWW_DIR/assets" 2>/dev/null || { echo "✗ dist 未发现版本戳 $WEB_VERSION(__APP_VERSION__ 注入失效?)"; exit 1; }
echo "    版本自证 ✓ version.txt=$WEB_VERSION 与 dist 戳一致"
echo "==> 完成"
ls -lh "$BIN_DIR"
du -sh "$WWW_DIR"

# 打包配置:与 configs/config.yaml 单源同步(fnpack 打包目录内为只读副本)
mkdir -p "$PACK_DIR/app/configs"
cp "$ROOT/configs/config.yaml" "$PACK_DIR/app/configs/config.yaml"
echo "==> 配置副本就绪: $PACK_DIR/app/configs/config.yaml"
