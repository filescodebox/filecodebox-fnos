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

# ── 外部探针可注入（默认仍是真命令）──────────────────────────────────────
# 为什么可注入：这份脚本是 fnos#115 **关单的证据工具** ⇒ 判据必须能判红；
# 而判据依赖真机（curl / pgrep / ss / id）⇒ 没法在 CI 里驱动它进「异常态」
# ⇒ 把探针做成可注入 ⇒ --selfcheck 用**假设备**证明每条判据都会红。
#
# ⚠️ **只认环境变量里的探针** ⇒ 真机上不设这些变量 ⇒ 行为与从前完全一致。
CMD_CURL="${PB_CMD_CURL:-curl}"
CMD_PGREP="${PB_CMD_PGREP:-pgrep}"
CMD_SS="${PB_CMD_SS:-ss}"
CMD_ID="${PB_CMD_ID:-id}"

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

# ── 自证模式：证明每条判据**能判红** ──────────────────────────────────────
# 这份脚本是 fnos#115 **关单的证据工具** ⇒ 若某条判据静默失效，脚本照样报
# 「✓ 已判定的项全部通过」⇒ **关单证据不可信**。
# ⇒ 用**假设备**（假 curl / 假 pgrep / 假 ss / 假 id）驱动**脚本自己**
#   （"$0" + 注入的探针 ⇒ 真实代码路径，不是副本）⇒ 每条判据都能被驱动进「异常态」。
if [ "${1:-}" = "--selfcheck" ]; then
  SELF_DIR="$(mktemp -d)"
  # EXIT trap 必须**保留退出码**（成功哨兵形态）。
  #
  # ⚠️ 原写法 `trap 'rm -rf "$SELF_DIR"' EXIT` 会**吞掉退出码**：
  #   脚本用 `set -uo pipefail`（**无 -e**）⇒ 未定义变量失败时 $? 可能是 0；
  #   且 trap 体最后一条命令（rm）成功 ⇒ 最终退出码恒 0
  #   ⇒ 本脚本是 **fnos#115 的关单证据工具** ⇒ 「判据该红时没红」会被
  #     报成 exit 0 ⇒ **证据不可信**（这正是自证模式要防的事）。
  #   ⇒ 正确形态：`OK=1` 标记「跑到了结尾」；trap 里 rc≠0 原样保留，
  #     rc=0 且 OK≠1 ⇒ 没跑到结尾却没留失败码 ⇒ 判失败。
  #   （与 hub 门禁 scripts/check-shell-trap-exit-code.sh 的判据一致）
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$SELF_DIR"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  OK=0
  FAKE="$SELF_DIR/bin"
  mkdir -p "$FAKE" "$SELF_DIR/app/target/bin" "$SELF_DIR/data"

  # 假 curl：按 URL 返回状态码（模式由 PB_FAKE_CURL 决定）
  cat > "$FAKE/curl" <<'CURL_EOF'
#!/bin/sh
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  */beam)                 code=401 ;;
  *"/?t="*)               code=200 ;;
  *)                      code=401 ;;
esac
case "${PB_FAKE_CURL:-good}" in
  beam200)  case "$url" in */beam) code=200 ;; esac ;;
  bare200)  case "$url" in *"/?t="*) code=200 ;; *) code=200 ;; esac ;;
esac
printf '%s' "$code"
CURL_EOF
  # 假 pgrep：PB_FAKE_PGREP=none ⇒ 找不到进程
  cat > "$FAKE/pgrep" <<'PGREP_EOF'
#!/bin/sh
[ "${PB_FAKE_PGREP:-yes}" = "none" ] && exit 1
printf '1234\n'
PGREP_EOF
  # 假 ss：PB_FAKE_SS=none ⇒ 端口没在听
  cat > "$FAKE/ss" <<'SS_EOF'
#!/bin/sh
[ "${PB_FAKE_SS:-yes}" = "none" ] && exit 0
printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "${PB_FAKE_PORT:-12348}"
SS_EOF
  # 假 id：PB_FAKE_ID=1000 ⇒ 非 root
  cat > "$FAKE/id" <<'ID_EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && printf '%s\n' "${PB_FAKE_ID:-0}" && exit 0
printf 'uid=%s\n' "${PB_FAKE_ID:-0}"
ID_EOF
  chmod +x "$FAKE"/*

  # 假设备：二进制在（按本机架构）+ 令牌文件
  case "$(uname -m)" in
    x86_64|amd64) FAKE_BIN="p2pcweb-linux-amd64" ;;
    *)           FAKE_BIN="p2pcweb-linux-arm64" ;;
  esac
  : > "$SELF_DIR/app/target/bin/$FAKE_BIN"
  printf 'faketoken\n' > "$SELF_DIR/data/.p2pcweb_token"

  fail=0
  # ① 一切正常 ⇒ 退出码 0
  out=$(PB_CMD_CURL="$FAKE/curl" PB_CMD_PGREP="$FAKE/pgrep" PB_CMD_SS="$FAKE/ss" \
        PB_CMD_ID="$FAKE/id" PB_APP_ROOT="$SELF_DIR/app" PB_DATA_PATH="$SELF_DIR/data" \
        bash "$0" "$SELF_DIR/data" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ 正常态应退出 0，实际 $rc" >&2; printf '%s\n' "$out" | sed 's/^/      /' >&2; fail=1
  else
    echo "  ✓ 正常态 ⇒ 退出码 0（判据不会无脑报红）"
  fi

  # ②③④⑤⑥⑥ 每条判据各驱动一次「异常态」⇒ 必须判红且退出码 1
  for case_spec in \
    "进程不在:PB_FAKE_PGREP=none" \
    "端口没在听:PB_FAKE_SS=none" \
    "裸请求被放行:PB_FAKE_CURL=bare200" \
    "/beam 未登录却返回 200:PB_FAKE_CURL=beam200"; do
    label="${case_spec%%:*}"
    envs="${case_spec#*:}"
    env_val="${envs#*=}"
    env_key="${envs%%=*}"
    out=$(env "${env_key}=${env_val}" \
          PB_CMD_CURL="$FAKE/curl" PB_CMD_PGREP="$FAKE/pgrep" PB_CMD_SS="$FAKE/ss" \
          PB_CMD_ID="$FAKE/id" PB_APP_ROOT="$SELF_DIR/app" PB_DATA_PATH="$SELF_DIR/data" \
          bash "$0" "$SELF_DIR/data" 2>&1)
    rc=$?
    if [ "$rc" -ne 1 ]; then
      echo "  ✗ 「${label}」应判红（退出码 1），实际 $rc" >&2
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      fail=1
    else
      echo "  ✓ 「${label}」⇒ 判红且退出码 1"
    fi
  done

  # ④ 令牌文件为空 ⇒ 判红
  : > "$SELF_DIR/data/.p2pcweb_token"
  out=$(PB_CMD_CURL="$FAKE/curl" PB_CMD_PGREP="$FAKE/pgrep" PB_CMD_SS="$FAKE/ss" \
        PB_CMD_ID="$FAKE/id" PB_APP_ROOT="$SELF_DIR/app" PB_DATA_PATH="$SELF_DIR/data" \
        bash "$0" "$SELF_DIR/data" 2>&1)
  rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "  ✗ 「令牌文件为空」应判红，实际 $rc" >&2; fail=1
  else
    echo "  ✓ 「令牌文件为空」⇒ 判红且退出码 1"
  fi
  printf 'faketoken\n' > "$SELF_DIR/data/.p2pcweb_token"

  # ⑦ 非 root ⇒ 退出码 2（无法判定 ≠ 通过）
  out=$(PB_CMD_CURL="$FAKE/curl" PB_CMD_PGREP="$FAKE/pgrep" PB_CMD_SS="$FAKE/ss" \
        PB_CMD_ID="$FAKE/id" PB_FAKE_ID=1000 PB_APP_ROOT="$SELF_DIR/app" \
        PB_DATA_PATH="$SELF_DIR/data" bash "$0" "$SELF_DIR/data" 2>&1)
  rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "  ✗ 非 root 应退出 2（无法判定），实际 $rc" >&2; fail=1
  else
    echo "  ✓ 非 root ⇒ 退出码 2（无法判定 ≠ 通过）"
  fi

  if [ "$fail" -ne 0 ]; then
    echo "✗ 自证失败：至少有一条判据没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：正常态绿、每条异常态都红、非 root 报无法判定 ⇒ 判据有牙齿"
  OK=1   # 跑到了结尾 ⇒ EXIT trap 允许以 0 退出（成功哨兵）
  exit 0
fi

echo "══ fnOS /beam 生命周期验收 ══"
echo "应用根: ${APP_ROOT}"
echo "数据目录: ${DATA_DIR:-（未确定）}"
echo "p2pcweb 端口: ${BEAM_PORT}"

# ── 前置：必须 root ────────────────────────────────────────────────────
if [ "$(${CMD_ID} -u)" != "0" ]; then
  record skip "前置" "非 root（uid=$(${CMD_ID} -u)）——正式 fpk 安装路径与进程检查都需要 root"
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

PIDS="$(${CMD_PGREP} -f p2pcweb 2>/dev/null | tr '\n' ' ')"
if [ -n "${PIDS}" ]; then
  record ok "p2pcweb 进程" "运行中 (pid: ${PIDS})"
else
  record no "p2pcweb 进程" "未运行——**自起**失败（由生命周期脚本拉起，不该靠手工）"
fi

if command -v "${CMD_SS}" >/dev/null 2>&1; then
  if ${CMD_SS} -ltn 2>/dev/null | grep -q ":${BEAM_PORT}\b"; then
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
if command -v "${CMD_CURL}" >/dev/null 2>&1; then
  # 未登录 → 401（文字提示），不是 302
  CODE="$(${CMD_CURL} -s -o /dev/null -w '%{http_code}' --max-time 8 \
          "http://127.0.0.1:${SERVER_PORT}/beam" 2>/dev/null || echo 000)"
  if [ "${CODE}" = "401" ]; then
    record ok "/beam 未登录" "401（提示先登录）"
  else
    record no "/beam 未登录" "期望 401，实际 ${CODE}"
  fi
  # p2pcweb 自身令牌门禁：裸请求应被拒（不是 200）
  if [ -n "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
    TOK="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
    PCODE="$(${CMD_CURL} -s -o /dev/null -w '%{http_code}' --max-time 8 \
             "http://127.0.0.1:${BEAM_PORT}/" 2>/dev/null || echo 000)"
    RCODE="$(${CMD_CURL} -s -o /dev/null -w '%{http_code}' --max-time 8 \
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
