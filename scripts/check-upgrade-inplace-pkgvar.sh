#!/usr/bin/env bash
# 门禁：fnos 原地换装脚本取 PKGVAR 时**不得因「取不到」而终止**。
#
# 缺陷实录（2026-10-26 审计 P1）：脚本里是**一条含命令替换的赋值**
#   PKGVAR=$(tr "\0" "\n" < /proc/$(pgrep -f "target/bin/pigeonbox" | head -1)/environ \
#            2>/dev/null | grep "^TRIM_PKGVAR=" | cut -d= -f2)
# 在 `set -e` + `pipefail` 下，**赋值语句的退出码取自命令替换**：
#   · 进程不存在   ⇒ 重定向失败 ⇒ 管道返回 1；
#   · 进程在但 environ 无该变量 ⇒ grep 返回 1 ⇒ pipefail 传导 ⇒ 同样返回 1；
# ⇒ set -e 立刻终止脚本 ⇒ 脚本死在读 PKGVAR 这步（连 "[2/6] 停应用"都到不了），
#   错误信息还被 2>/dev/null 吞掉 ⇒ 用户只看到一条无上下文的退出。
# 而这正是「应用已停/已崩/上一轮升级中途失败 ⇒ 正需要重试」的场景。
#
# 本门禁用**干跑模式**（PB_UPGRADE_DRYRUN=1 + PB_UPGRADE_TARGET 指向临时目录）
# 跑真实脚本，断言：
#   C1 无同名进程时脚本必须走到 "[2/6]"（而不是死在读 PKGVAR 时）；
#   C2 此时解析出的 PKGVAR 必须是兜底默认值；
#   C3 结构断言：PKGVAR 的取值与赋值必须**拆开**且带显式兜底；
#   C4 **负对照**：把取值改回「无兜底」（去掉 || true）⇒ 必须变红。
#
# 用法: bash scripts/check-upgrade-inplace-pkgvar.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/upgrade-inplace.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT"; exit 1; }

WORK="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# 假的应用目录(脚本 [1/6] 会 cp -a 它)与假 fpk
FAKE_T="$WORK/target"
mkdir -p "$FAKE_T/config" "$FAKE_T/configs"
echo "keep" > "$FAKE_T/config/app.conf"
echo "keep" > "$FAKE_T/configs/config.yaml"
: > "$WORK/pigeonbox.fpk"

run_dry() { # <脚本> ; 打印 "<退出码>|<输出>"
  local out rc
  out="$(PB_UPGRADE_TARGET="$FAKE_T" PB_UPGRADE_DRYRUN=1 \
        bash "$1" "$WORK/pigeonbox.fpk" 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "── C1/C2 无同名进程时必须走到 [2/6] 并落到兜底 PKGVAR"
RES="$(run_dry "$SCRIPT")"
RC="${RES%%|*}"
OUT="${RES#*|}"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "\[2/6\]"; then
  ok "C1 脚本走到 [2/6]（退出码 0）"
else
  bad "C1 脚本没走到 [2/6]" "退出码=$RC 输出=$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q "TRIM_PKGVAR=/vol1/@appdata/pigeonbox"; then
  ok "C2 兜底 PKGVAR 生效（/vol1/@appdata/pigeonbox）"
else
  bad "C2 兜底 PKGVAR 不对" "$(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
fi

echo "── C3 结构断言：取值与赋值必须拆开且带显式兜底"
if grep -qE '^\s*PKGVAR="\$\{PBGVAR_RAW:-/vol1/@appdata/pigeonbox\}"' "$SCRIPT"; then
  ok "C3 PKGVAR 赋值带显式兜底"
else
  bad "C3 PKGVAR 赋值没有显式兜底" "-"
fi
if grep -qE "^\s*PBGVAR_PID=.*\|\| true" "$SCRIPT"; then
  ok "C3b 取进程 PID 的管道带 || true（取不到不终止脚本）"
else
  bad "C3b 取 PID 的管道没有 || true" "⇒ set -e + pipefail 下取不到就终止脚本（原缺陷）"
fi

echo "── C4 负对照：去掉 || true（还原缺陷态）必须变红"
MUT="$WORK/upgrade-inplace.mutated.sh"
sed -e '/^PBGVAR_PID=/ s/ || true)"/)"/' \
    -e '/^PBGVAR_RAW=/ s/ || true)"/)"/' \
    "$SCRIPT" > "$MUT"
if diff -q "$SCRIPT" "$MUT" >/dev/null 2>&1; then
  bad "C4 变异未生效" "没能在脚本里定位那两行（脚本结构变了？）"
else
  RES="$(run_dry "$MUT")"
  RC="${RES%%|*}"
  OUT="${RES#*|}"
  if [ "$RC" != "0" ] || ! printf '%s' "$OUT" | grep -q "\[2/6\]"; then
    ok "C4 缺陷态确实走不到 [2/6]（退出码=${RC}）⇒ 门禁能抓住原缺陷"
  else
    bad "C4 缺陷态竟然仍能走到 [2/6]" "退出码=$RC ⇒ 变异没复现原缺陷，门禁空转"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✓ fnos 原地换装 PKGVAR 取值守卫通过（取不到不终止脚本）"
OK=1
