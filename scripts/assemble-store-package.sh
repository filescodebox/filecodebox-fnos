#!/usr/bin/env bash
# 组装飞牛应用中心上架材料包——fpk + 图标 + 截图 + 提交说明,一键成包。
# 产物: dist/store-submission/pigeonbox-fnos-store-v<版本>.zip(已 gitignore,不入库)
#
# 用法: ./scripts/assemble-store-package.sh [版本]
#   版本缺省读 VERSION;fpk 缺省从 hub Release fnos-v<版本> 下载(需 gh 登录),
#   本地构建的包用 FPK_SRC=/path/to/pigeonbox.fpk 指定。
# 截图缺省取工作区 docs-site/public/screenshots(须与所发 fpk 的前端 UI 对齐),
# 可用 SHOTS_DIR 覆盖。
# 每列车发版后重跑一次,即得该版本的重新提交材料。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_ROOT/VERSION")}"
FPK_SRC="${FPK_SRC:-}"
SHOTS_DIR="${SHOTS_DIR:-$REPO_ROOT/../docs-site/public/screenshots}"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/dist/store-submission}"
PKG_NAME="pigeonbox-fnos-store-v${VERSION}"
WORK="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# 截图清单: 源文件|成品名(编号即建议展示顺序;包内一律 ASCII 文件名防 Windows 解压乱码,
# 中文名称写在 README 对照表;全部应为本版本真实 UI,禁止占位图)
SHOT_LIST='
send-text|01-send-text
send-file|02-send-file
share-success|03-share-success
home-pickup|04-home-pickup
pickup-password|05-pickup-password
pickup-unlocked|06-pickup-text
pickup-multifile|07-pickup-files
admin-dashboard|08-admin-dashboard
'

log() { printf '[store] %s\n' "$*"; }

# ---- 1. fpk 就位 ----
if [ -z "$FPK_SRC" ]; then
  log "从 hub Release 下载 pigeonbox.fpk (fnos-v${VERSION})"
  FPK_SRC="$WORK/pigeonbox.fpk"
  gh release download "fnos-v${VERSION}" --repo pigeonbox/pigeonbox \
    --pattern 'pigeonbox.fpk' --output "$FPK_SRC" --clobber
fi
[ -f "$FPK_SRC" ] || { log "fpk 不存在: $FPK_SRC"; exit 1; }

# ---- 2. 从 fpk 自解析 manifest(说明与产物自洽;勿读工作区——可能含未发版改动) ----
# 注意: fnpack 打包后 manifest 键值会对齐等号(desc   = ...),匹配须容忍空白
tar -xzf "$FPK_SRC" -C "$WORK" manifest ICON.PNG ICON_256.PNG
FPK_DESC="$(grep -E '^desc[[:space:]]*=' "$WORK/manifest" | head -1 | sed 's/^desc[[:space:]]*=[[:space:]]*//' || true)"
FPK_VER="$(grep -E '^version[[:space:]]*=' "$WORK/manifest" | head -1 | sed 's/^version[[:space:]]*=[[:space:]]*//' | tr -d '[:space:]' || true)"
[ -n "$FPK_DESC" ] || { log "✗ fpk 内 manifest 无 desc 字段"; exit 1; }
# 应用介绍可为富文本(应用中心按 HTML 白名单渲染),README 表格只留纯文本
FPK_DESC_PLAIN="$(printf '%s' "$FPK_DESC" | sed 's/<[^>]*>//g')"
if [ "$FPK_VER" != "$VERSION" ]; then
  log "⚠ fpk 内版本($FPK_VER)与请求版本($VERSION)不一致,以 fpk 为准继续"
  VERSION="$FPK_VER"
  PKG_NAME="pigeonbox-fnos-store-v${VERSION}"
fi

# 品牌代际校验: fpk 内图标须与打包源一致(防旧代图标混入;图标重生成后务必看本告警)
if ! cmp -s "$WORK/ICON.PNG" "$REPO_ROOT/fnos/ICON.PNG"; then
  log "⚠ fpk 内 ICON.PNG 与打包源不一致——确认是否旧代图标随包(图标重生成未随该 fpk 发布)"
fi

# ---- 3. 组目录 ----
PKG_DIR="$OUT_ROOT/$PKG_NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/screenshots"
cp "$FPK_SRC" "$PKG_DIR/pigeonbox.fpk"
cp "$WORK/ICON.PNG" "$WORK/ICON_256.PNG" "$PKG_DIR/"

while IFS='|' read -r src dst; do
  [ -z "$src" ] && continue
  if [ ! -f "$SHOTS_DIR/$src.png" ]; then
    log "✗ 缺截图 $src.png(于 $SHOTS_DIR)——先跑 docs-site 截图流水线或用 SHOTS_DIR 指定"
    exit 1
  fi
  cp "$SHOTS_DIR/$src.png" "$PKG_DIR/screenshots/$dst.png"
done <<< "$SHOT_LIST"

# 尺寸一致性检查(macOS;不硬失败,提交前人工确认)
if command -v sips >/dev/null 2>&1; then
  for f in "$PKG_DIR"/screenshots/*.png; do
    dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
    [ "$dims" != "1366x900" ] && log "⚠ $(basename "$f") 尺寸 $dims ≠ 1366x900,展示会缩放不齐"
  done
fi

# ---- 4. 提交说明(给飞牛工作人员/审核者看;文件名用 README.md,内容中文) ----
TODAY="$(date +%Y-%m-%d)"
cat > "$PKG_DIR/README.md" <<EOF
# PigeonBox(文件快递柜)上架申请材料

> 组装于 $TODAY,对应应用包版本 v${VERSION}。联系方式请在提交前按工作人员要求补充。

## 应用基本信息

| 项 | 内容 |
|---|---|
| 应用名称 | PigeonBox(文件快递柜) |
| 包名 | pigeonbox |
| 版本 | ${VERSION} |
| 应用类型 | thirdparty 原生进程模式(免 Docker,包内自带双架构静态二进制+内嵌前端) |
| 应用介绍(与应用中心同款,已去 HTML 标签) | ${FPK_DESC_PLAIN} |
| 开源地址 | https://github.com/pigeonbox(Apache-2.0,全生态开源) |
| 维护者 | zhangyi(https://github.com/zy84338719) |
| 联系方式 | <提交时补充微信号/QQ> |

## 功能亮点

1. **文本/文件匿名分享**:对方无需注册,凭分享码或链接即可取件;支持访问密码保护、有效期到期自动销毁。
2. **双码体系**:8 位分享码(区分大小写)+ 6 位快捷取件码(全大写),支持二维码与完整链接三种取件方式。
3. **数据落 NAS**:上传文件与数据库全部存在应用数据目录(NAS 共享路径),文件管理器可直接查看、备份。
4. **完整管理控制台**:用户管理、14 种存储后端、公告、审计与传输日志、回收站。
5. **内容合规**:默认关闭开放注册;生产模式强制管理员密码;内置敏感词审核钩子;页面明示遵守《中华人民共和国网络安全法》的合规声明。

## 测试情况

- 测试设备:飞牛 fnOS 1.2.0701(x86_64 真机)。
- 覆盖项:全新安装、桌面入口、应用内启停、应用内升级、卸载重装、进程看门狗自愈、分享-取件全流程(文本/多文件/密码保护)。
- 双架构:包内自带 x86_64 与 aarch64 静态二进制,单进程单端口(默认 12345),安装即用。

## 材料清单

- \`pigeonbox.fpk\`:应用包(本包根目录)。
- \`ICON.PNG\` / \`ICON_256.PNG\`:应用图标(64/256)。
- \`README.md\`:本说明。
- \`screenshots/\`:8 张真实界面截图(1366×900),覆盖发送-分享-取件-管理核心流程:

| 文件 | 界面 |
|---|---|
| 01-send-text.png | 发送页·文本分享(粘贴文本/设有效期/可选密码) |
| 02-send-file.png | 发送页·文件分享(拖拽多文件上传,单文件最大 5GB) |
| 03-share-success.png | 分享成功·双码体系(6 位取件码 + 8 位分享码 + 二维码/完整链接) |
| 04-home-pickup.png | 首页·快捷取件(6 位取件码输满自动取件) |
| 05-pickup-password.png | 取件·密码保护(受保护分享需输入访问密码) |
| 06-pickup-text.png | 取件·文本内容展示(免注册在线查看/一键复制) |
| 07-pickup-files.png | 取件·多文件下载(文件列表/单个下载/打包 ZIP) |
| 08-admin-dashboard.png | 管理控制台·仪表盘(用户/存储/公告/审计集中管理) |

## 上架后更新

本项目按版本列车发版,每个新版本将主动向应用中心提交新版 fpk 与更新说明(changelog 见应用包内 manifest)。
EOF

# ---- 5. 成包(先删旧包——zip 对已存在的包是追加不是重建,旧条目会残留) ----
rm -f "$OUT_ROOT/$PKG_NAME.zip"
( cd "$OUT_ROOT" && zip -rq "$PKG_NAME.zip" "$PKG_NAME" )
log "完成: $OUT_ROOT/$PKG_NAME.zip"
log "  目录: $PKG_DIR"
ls -lh "$PKG_NAME.zip" 2>/dev/null || ls -lh "$OUT_ROOT/$PKG_NAME.zip"
OK=1
