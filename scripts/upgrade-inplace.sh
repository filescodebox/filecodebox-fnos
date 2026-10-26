#!/usr/bin/env bash
# fnOS 原地换装(官方姿势固化,2026-10-12):
#   appcenter-cli install-fpk 对已装应用是 no-op("is installed" 直接退出),
#   升级一律走本脚本。干净换装=先清 www/bin 再解包——根除历代产物残留
#   (五代 chunk 曾累积 423 个 js,旧版本戳制造「页脚版本陈旧」幽灵伪差异)。
# 用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>
# 升级后验真: curl -s http://127.0.0.1:12345/version.txt
set -euo pipefail

FPK="${1:?用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>}"
# 应用目录(默认生产路径;可覆盖 ⇒ 门禁脚本能离线自检而不碰真机)
T="${PB_UPGRADE_TARGET:-/var/apps/pigeonbox/target}"
[ -f "$FPK" ] || { echo "✗ 找不到 $FPK"; exit 1; }

echo "[1/6] 备份机器配置(config/configs,解包会覆盖)"
BK=/tmp/pigeonbox-cfg-backup-$(date +%s)
mkdir -p "$BK"
cp -a "$T/config" "$BK/config"
cp -a "$T/configs" "$BK/configs"

# cmd/main 全程依赖框架注入的 TRIM_PKGVAR(数据根/.env/.admin_reset/日志路径),
# 手工调用必须显式注入——否则数据根漂到包目录、重置标记不消费(2026-10-13 实锤)。
# 优先从运行中进程 environ 取(多卷场景),否则默认 vol1。
#
# ⚠️ 2026-10-26 审计 P1:原实现是**一条含命令替换的赋值**:
#   PKGVAR=$(tr "\0" "\n" < /proc/$(pgrep -f "target/bin/pigeonbox" | head -1)/environ \
#            2>/dev/null | grep "^TRIM_PKGVAR=" | cut -d= -f2)
# 在 `set -e` + `pipefail` 下,**赋值语句的退出码取自命令替换** ⇒
#   · 进程不存在   ⇒ 重定向失败 ⇒ 管道返回 1;
#   · 进程在但 environ 无该变量 ⇒ grep 返回 1 ⇒ pipefail 传导 ⇒ 同样返回 1;
# ⇒ set -e 立刻终止脚本 ⇒ 脚本**死在读 PKGVAR 这步**(连 "[2/6] 停应用"都到不了),
#   错误信息还被 2>/dev/null 吞掉 ⇒ 用户只看到一条无上下文的退出。
#   而这恰恰是「应用已停/已崩/上一轮升级中途失败 ⇒ 正需要重试」的场景;
#   任何非 fnOS 框架方式启动的实例首次升级也必然失败。
# ⇒ 修法:取值与赋值**拆开**,逐段显式兜底(取不到就当「没取到」,绝不因此终止脚本)。
PBGVAR_PID="$(pgrep -f 'target/bin/pigeonbox' 2>/dev/null | head -1 || true)"
PBGVAR_RAW=""
if [ -n "$PBGVAR_PID" ] && [ -r "/proc/$PBGVAR_PID/environ" ]; then
  PBGVAR_RAW="$(tr '\0' '\n' < "/proc/$PBGVAR_PID/environ" 2>/dev/null | grep '^TRIM_PKGVAR=' | cut -d= -f2 || true)"
fi
PKGVAR="${PBGVAR_RAW:-/vol1/@appdata/pigeonbox}"

echo "[2/6] 停应用(TRIM_PKGVAR=$PKGVAR)"
# 干跑:解析出 PKGVAR 后立刻退出,不做任何变更。
# 用途:门禁脚本要能验证「取不到 PKGVAR 时脚本仍能走到 [2/6]」(见同目录
# check-upgrade-inplace-pkgvar.sh)。
if [ "${PB_UPGRADE_DRYRUN:-0}" = "1" ]; then
  echo "[dryrun] 已解析 PKGVAR=$PKGVAR —— 不停应用/不解包"
  exit 0
fi
TRIM_PKGVAR="$PKGVAR" bash /var/apps/pigeonbox/cmd/main stop 2>/dev/null || true
sleep 2
pkill -f "target/bin/pigeonbox" 2>/dev/null || true
sleep 1

echo "[3/6] 干净解包(rm -rf www bin ui → 解包,杜绝旧产物残留)"
rm -rf /tmp/fpk-unpack && mkdir /tmp/fpk-unpack
tar xzf "$FPK" -C /tmp/fpk-unpack
[ -f /tmp/fpk-unpack/app.tgz ] || { echo "✗ fpk 无 app.tgz"; exit 1; }
rm -rf "${T:?}/www" "${T:?}/bin" "${T:?}/ui"
tar xzf /tmp/fpk-unpack/app.tgz -C "$T"

echo "[4/6] 还原机器配置"
cp -a "$BK/config/." "$T/config/"
cp -a "$BK/configs/." "$T/configs/"

echo "[5/6] 属主归位"
chown -R pigeonbox:pigeonbox "$T"

echo "[5.5/6] 数据目录属主归位(root 实例曾写花 app.log→框架起不来,2.1.0 真机实锤)"
chown -R pigeonbox:pigeonbox "$PKGVAR" 2>/dev/null || true

echo "[6/6] 启应用(TRIM_PKGVAR=$PKGVAR,看门狗后台,勿占管道)"
# 必须以应用用户启动:sudo 跑本脚本时直接 start 会拉起 root 实例,占端口+写花
# 数据目录,fnOS 框架随后「端口被占用」拒启(2026-10-19 真机实锤;对齐框架
# appcenter-cli start 的应用用户语义)。
nohup sudo -u pigeonbox env TRIM_PKGVAR="$PKGVAR" bash /var/apps/pigeonbox/cmd/main start >/dev/null 2>&1 &
for _i in $(seq 1 30); do pgrep -f "target/bin/pigeonbox" >/dev/null && break; sleep 1; done
if pgrep -f "target/bin/pigeonbox" >/dev/null; then
  echo "✓ 进程已起"
else
  echo "✗ 启动失败"
  exit 1
fi
echo "── 验真: curl -s http://127.0.0.1:12345/version.txt"
