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
LDFLAGS="-w -s -X 'github.com/pigeonbox/kit/version.Version=${VERSION}' -X 'github.com/pigeonbox/kit/version.BuildCommit=${COMMIT}' -X 'github.com/pigeonbox/kit/version.BuildTime=${BUILD_TIME}'"

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
