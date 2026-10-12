#!/usr/bin/env bash
# fnOS 原地换装(官方姿势固化,2026-10-12):
#   appcenter-cli install-fpk 对已装应用是 no-op("is installed" 直接退出),
#   升级一律走本脚本。干净换装=先清 www/bin 再解包——根除历代产物残留
#   (五代 chunk 曾累积 423 个 js,旧版本戳制造「页脚版本陈旧」幽灵伪差异)。
# 用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>
# 升级后验真: curl -s http://127.0.0.1:12345/version.txt
set -euo pipefail

FPK="${1:?用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>}"
T=/var/apps/pigeonbox/target
[ -f "$FPK" ] || { echo "✗ 找不到 $FPK"; exit 1; }

echo "[1/6] 备份机器配置(config/configs,解包会覆盖)"
BK=/tmp/pigeonbox-cfg-backup-$(date +%s)
mkdir -p "$BK"
cp -a "$T/config" "$BK/config"
cp -a "$T/configs" "$BK/configs"

echo "[2/6] 停应用"
bash /var/apps/pigeonbox/cmd/main stop 2>/dev/null || true
sleep 2
pkill -f "target/bin/pigeonbox" 2>/dev/null || true
sleep 1

echo "[3/6] 干净解包(rm -rf www bin ui → 解包,杜绝旧产物残留)"
rm -rf /tmp/fpk-unpack && mkdir /tmp/fpk-unpack
tar xzf "$FPK" -C /tmp/fpk-unpack
[ -f /tmp/fpk-unpack/app.tgz ] || { echo "✗ fpk 无 app.tgz"; exit 1; }
rm -rf "$T/www" "$T/bin" "$T/ui"
tar xzf /tmp/fpk-unpack/app.tgz -C "$T"

echo "[4/6] 还原机器配置"
cp -a "$BK/config/." "$T/config/"
cp -a "$BK/configs/." "$T/configs/"

echo "[5/6] 属主归位"
chown -R pigeonbox:pigeonbox "$T"

echo "[6/6] 启应用(看门狗后台,勿占管道)"
nohup bash /var/apps/pigeonbox/cmd/main start >/dev/null 2>&1 &
for i in $(seq 1 30); do pgrep -f "target/bin/pigeonbox" >/dev/null && break; sleep 1; done
pgrep -f "target/bin/pigeonbox" >/dev/null && echo "✓ 进程已起" || { echo "✗ 启动失败"; exit 1; }
echo "── 验真: curl -s http://127.0.0.1:12345/version.txt"
