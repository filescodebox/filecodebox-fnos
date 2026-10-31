#!/usr/bin/env bash
# fnOS 真机验收：/beam（信鸽直传）完整生命周期（fnos#115）。
#
# **为什么需要这个脚本**：fnos#115 的 4 步验收判据此前只能靠人手点、
# 人眼判 ⇒ 每次复验都要重新想一遍「怎么算通过」⇒ 结论不可复现、
# 也留不下证据。
# ⇒ 本脚本把判据**逐条机械化**：跑完输出一份可归档的结论（退出码非 0 = 有项未通过）。
#
# **前置**：正式 fpk 安装后的 fnOS 设备 + **root** 会话
#   （装 fpk、读 /usr/local/Apps、查进程都要 root）。
#   非 root ⇒ 脚本会明确报「前置不满足」而不是给出假结论。
#
# 用法（在设备上）：
#   sudo ./scripts/verify-beam-lifecycle.sh [数据目录]
#   数据目录缺省从应用包的环境变量/常见路径推断。
#
# 验收判据（逐条对应 fnos#115 的待办）：
#   1. 正式安装路径下 **p2pcweb 自起**（不是手工拉起）：
#      进程在、监听端口、令牌文件落数据卷；
#   2. **/beam 入口**：未登录 → 401 文字提示；已登录 → 302 到 p2pcweb（带持久令牌）；
#   3. **重启后自恢复**：token/config 持久；
#   4. **卸载/升级不残留**：数据卷清理正常。
set -uo pipefail

# ── 定位应用 ───────────────────────────────────────────────────────────
APP_ROOT="${PB_APP_ROOT:-/usr/local/Apps/pigeonbox}"
DATA_DIR="${1:-${PB_DATA_PATH:-}}"
BEAM_PORT="${PB_P2PCWEB_PORT:-12348}"
SERVER_PORT="${PB_SERVER_PORT:-12345}"
TOKEN_FILE="${DATA_DIR}/.p2pcweb_token"

PASS=0
FAIL=0
declare -a RESULTS=()

record() { # record <ok|no|skip> <名称> <详情>
  case "$1" in
    ok)   PASS=$((PASS+1)); RESULTS+=("PASS | $2 | $3") ;;
    no)   FAIL=$((FAIL+1)); RESULTS+=("FAIL | $2 | $3") ;;
    skip) RESULTS+=("SKIP | $2 | $3") ;;
  esac
  printf '  [%s] %s — %s\n' "$1" "$2" "$3"
}

echo "══ fnOS /beam 生命周期验收 ══"
echo "应用根: ${APP_ROOT}"
echo "数据目录: ${DATA_DIR:-（未确定）}"
echo "p2pcweb 端口: ${BEAM_PORT}"

# ── 前置：必须 root ────────────────────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
  record skip "前置" "非 root（uid=$(id -u)）——正式 fpk 安装路径与进程检查都需要 root"
  echo
  echo "结论: 前置不满足，无法判定（不是「通过」）"
  printf '%s\n' "${RESULTS[@]}"
  exit 2
fi
record ok "前置" "root 会话"

# ── 数据目录推断 ───────────────────────────────────────────────────────
if [ -z "${DATA_DIR}" ]; then
  for cand in /var/apps/pigeonbox/data /usr/local/Apps/pigeonbox/data \
              "${APP_ROOT}/data" /volume1/docker/pigeonbox/data; do
    [ -d "$cand" ] && DATA_DIR="$cand" && break
  done
fi
if [ -z "${DATA_DIR}" ] || [ ! -d "${DATA_DIR}" ]; then
  record no "数据目录" "找不到数据目录（PB_DATA_PATH 未设且常见路径都不存在）"
  TOKEN_FILE=""
else
  record ok "数据目录" "${DATA_DIR}"
  TOKEN_FILE="${DATA_DIR}/.p2pcweb_token"
fi

# ── 判据 1：p2pcweb 自起 ───────────────────────────────────────────────
echo
echo "── 判据 1：正式安装路径下 p2pcweb 自起 ──"
BIN="${APP_ROOT}/target/bin/p2pcweb-linux-$(uname -m)"
case "$(uname -m)" in
  x86_64|amd64) BIN="${APP_ROOT}/target/bin/p2pcweb-linux-amd64" ;;
  aarch64|arm64) BIN="${APP_ROOT}/target/bin/p2pcweb-linux-arm64" ;;
esac
if [ -f "${BIN}" ]; then
  record ok "p2pcweb 二进制" "${BIN}"
else
  record no "p2pcweb 二进制" "缺失 ${BIN}（正式包应随包携带）"
fi

PIDS="$(pgrep -f p2pcweb 2>/dev/null | tr '\n' ' ')"
if [ -n "${PIDS}" ]; then
  record ok "p2pcweb 进程" "运行中 (pid: ${PIDS})"
else
  record no "p2pcweb 进程" "未运行——**自起**失败（由生命周期脚本拉起，不该靠手工）"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":${BEAM_PORT}\b"; then
    record ok "p2pcweb 监听" "端口 ${BEAM_PORT} 在听"
  else
    record no "p2pcweb 监听" "端口 ${BEAM_PORT} 未监听"
  fi
else
  record skip "p2pcweb 监听" "无 ss 命令"
fi

# ── 判据 1b：令牌落数据卷 ───────────────────────────────────────────────
if [ -n "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
  record ok "令牌文件" "${TOKEN_FILE}（非空）"
else
  record no "令牌文件" "缺失或为空：${TOKEN_FILE:-（数据目录未知）}"
fi

# ── 判据 2：/beam 入口 ─────────────────────────────────────────────────
echo
echo "── 判据 2：/beam 入口行为 ──"
if command -v curl >/dev/null 2>&1; then
  # 未登录 → 401（文字提示），不是 302
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
          "http://127.0.0.1:${SERVER_PORT}/beam" 2>/dev/null || echo 000)"
  if [ "${CODE}" = "401" ]; then
    record ok "/beam 未登录" "401（提示先登录）"
  else
    record no "/beam 未登录" "期望 401，实际 ${CODE}"
  fi
  # p2pcweb 自身令牌门禁：裸请求应被拒（不是 200）
  if [ -n "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
    TOK="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
    PCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
             "http://127.0.0.1:${BEAM_PORT}/" 2>/dev/null || echo 000)"
    RCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
             "http://127.0.0.1:${BEAM_PORT}/?t=${TOK}" 2>/dev/null || echo 000)"
    if [ "${PCODE}" != "200" ]; then
      record ok "p2pcweb 令牌门禁" "裸请求 ${PCODE}（非 200）"
    else
      record no "p2pcweb 令牌门禁" "裸请求 200——令牌门禁失效"
    fi
    if [ "${RCODE}" = "200" ]; then
      record ok "p2pcweb 带令牌" "200（令牌可用）"
    else
      record no "p2pcweb 带令牌" "带令牌仍 ${RCODE}"
    fi
  else
    record skip "p2pcweb 令牌门禁" "令牌文件不可读"
  fi
else
  record skip "/beam 入口" "无 curl 命令"
fi

# ── 判据 3：重启后自恢复 ───────────────────────────────────────────────
echo
echo "── 判据 3：重启后自恢复 ──"
echo "  （需要重启设备/服务后**再跑一次**本脚本对比本节结论）"
if [ -n "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
  SHA="$(sha256sum "${TOKEN_FILE}" 2>/dev/null | cut -d' ' -f1)"
  echo "${SHA}" > /tmp/.beam_token_sha 2>/dev/null || true
  record ok "令牌持久化基线" "已记录 sha256=${SHA:0:16}…（重启后再跑本脚本比对）"
else
  record no "令牌持久化基线" "令牌文件不可读"
fi
record skip "重启后自恢复" "需人工重启后再跑本脚本核对（本节只记录基线）"

# ── 判据 4：卸载/升级不残留 ────────────────────────────────────────────
echo
echo "── 判据 4：卸载/升级不残留 ──"
record skip "卸载/升级不残留" "需实际执行卸载/升级后再核对数据卷与进程残留"

# ── 结论 ───────────────────────────────────────────────────────────────
echo
echo "── 结论 ──"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo
echo "PASS=${PASS} FAIL=${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo "✗ 有 ${FAIL} 项未通过"
  exit 1
fi
echo "✓ 已判定的项全部通过（SKIP 项需另行验证）"
exit 0
