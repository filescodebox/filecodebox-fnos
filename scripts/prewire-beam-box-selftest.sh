#!/usr/bin/env bash
# prewire-beam-box.sh 的自测（变异测试：判据失效必须红）。
#
# 为什么需要：本脚本干两件「错了也不会有人喊」的事——
#   ① 建/复用一把 Box API Key；② 把地址+Key 写进 p2pcweb 的配置。
#   若它「每启动一次就建一把新 Key」，Key 列表会无声膨胀；
#   若它「发了空字段把用户配的 registry 冲掉」，用户配的直传注册中心会丢。
#   ⇒ 两类都必须有**能判红的**判据。
#
# 本自测跑**真的脚本**（临时工作区 + 假 Box + 假 p2pcweb）：
#   ① 首次执行：建 1 把 Key、scope 精确为 admin/user/share、配置收到地址+Key；
#   ② 二次执行：**不得再建 Key**（幂等）、配置里的 Key 与首次一致；
#   ③ 负对照 A：把「缓存有效则复用」改坏 ⇒ 二次执行建了 2 把 ⇒ 判据 ② 必须红；
#   ④ 负对照 B：把 scope 改窄 ⇒ 判据 ① 必须红；
#   ⑤ 负对照 C：把「只发非空字段」改成发空 registry ⇒ 判据 ③ 必须红。
#
# 用法: bash scripts/prewire-beam-box-selftest.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREWIRE="$SCRIPT_DIR/../fnos/cmd/prewire_beam_box"

fails=0
note_fail() { echo "  ✗ $1"; fails=$((fails + 1)); }
note_ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"
OK=0
MOCK_PID=""
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# ── 假 Box + 假 p2pcweb（同一 handler，两个端口）─────────────────────────
cat > "$TMP/mock.py" <<'PYEOF'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"created": 0, "scopes": None, "config": None, "keys": {}}
STATE_PATH = sys.argv[2]

def save():
    with open(STATE_PATH, "w") as f:
        json.dump(STATE, f)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/ping":
            return self._send(200, "pong")
        if path == "/api/v1/user/shares":
            # ⚠️ 真实契约：**只读 + 认 X-API-Key**（UserOrAPIKey）
            #   ⇒ 预接线若拿 /user/api-keys（会话面）去校验 ⇒ 恒 401 ⇒ 每次重建。
            key = self.headers.get("X-API-Key", "")
            if key and key in STATE["keys"]:
                return self._send(200, json.dumps({"code": 0, "data": {"shares": []}}))
            return self._send(401, json.dumps({"code": 10001, "message": "unauthorized"}))
        if path == "/user/api-keys":
            # 会话面：只认 Bearer（真实行为）⇒ API Key 调它恒 401
            if self.headers.get("Authorization", "").startswith("Bearer "):
                return self._send(200, json.dumps({"code": 0, "keys": []}))
            return self._send(401, json.dumps({"code": 10001, "message": "unauthorized"}))
        return self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n).decode() if n else "{}"
        path = self.path.split("?")[0]
        if path == "/admin/login":
            try:
                if json.loads(raw).get("password") != "admin123":
                    return self._send(401, json.dumps({"code": 10001}))
            except Exception:
                pass
            return self._send(200, json.dumps({"code": 0, "data": {"token": "TESTTOKEN"}}))
        if path == "/user/api-keys":
            try:
                body = json.loads(raw)
            except Exception:
                body = {}
            STATE["created"] += 1
            STATE["scopes"] = body.get("scopes")
            key = "pb_sk_test%d" % STATE["created"]
            STATE["keys"][key] = True
            save()
            return self._send(200, json.dumps({"code": 0, "data": {"key": key}}))
        if path == "/api/config":
            # ⚠️ 真实契约：令牌走 **X-P2PCWEB 头**；只有首页 `/` 才认 `?t=`
            #   ⇒ 预接线若用 `?t=` 调 API ⇒ 403 ⇒ 配置写不进去（真机实录）。
            if self.headers.get("X-P2PCWEB", "") != "BEAMTOKEN123":
                return self._send(403, "403：令牌无效，请从启动时打印的完整地址进入")
            try:
                STATE["config"] = json.loads(raw)
            except Exception:
                STATE["config"] = {}
            save()
            return self._send(200, json.dumps({"ok": "1"}))
        return self._send(404, "{}")

def serve(port):
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()

p1, p2 = int(sys.argv[1]), int(sys.argv[3])
threading.Thread(target=serve, args=(p1,), daemon=True).start()
serve(p2)
PYEOF

BOX_PORT=18871
BEAM_PORT=18872
STATE="$TMP/state.json"
# ⚠️ mock 日志留档：自测自身失效时能看到它到底报了什么（CI 上排查的唯一线索）
python3 "$TMP/mock.py" "$BOX_PORT" "$STATE" "$BEAM_PORT" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!

# 等 mock 就绪（⚠️ CI runner 比本机慢 ⇒ 等待放宽到 60×0.2s=12s；
#   4s 在本机够、在 CI 上偶发不够 ⇒ 表现为「自测自身失效」的**假红**）
ready=0
for _ in $(seq 1 60); do
    if curl -s -m 1 "http://127.0.0.1:${BOX_PORT}/ping" 2>/dev/null | grep -q pong; then
        ready=1
        break
    fi
    sleep 0.2
done
if [ "$ready" != "1" ]; then
    echo "✗ 假 Box 未就绪——自测自身失效（mock 日志：）"
    tail -20 "$TMP/mock.log" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

DATA="$TMP/data"
mkdir -p "$DATA"
printf 'BEAMTOKEN123' > "$DATA/.p2pcweb_token"

run_prewire() { # <脚本路径> → 退出码
    PB_SERVER_PORT="$BOX_PORT" \
    PB_P2PCWEB_PORT="$BEAM_PORT" \
    PB_DATA_PATH="$DATA" \
    PB_ADMIN_PASSWORD=admin123 \
    PB_PREWIRE_WAIT_MAX="${PB_PREWIRE_WAIT_MAX:-30}" \
        bash "$1" >/dev/null 2>&1
}

state_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE" "$1" 2>/dev/null; }

# ── 判据 ①：首次执行建 1 把 Key、scope 精确、配置收到地址+Key ───────────
echo "── 判据 ①：首次执行（建 1 把 Key + scope 精确 + 配置写入）"
run_prewire "$PREWIRE"
CREATED1=$(state_get created)
SCOPES=$(state_get scopes)
CFG=$(state_get config)
if [ "$CREATED1" = "1" ]; then
    note_ok "首次执行建了 1 把 Key"
else
    note_fail "首次执行建了 ${CREATED1:-0} 把 Key（期望 1）"
fi
if [ "$SCOPES" = "['admin', 'user', 'share']" ]; then
    note_ok "scope 精确为 admin/user/share"
else
    note_fail "scope 不是 admin/user/share（实得：${SCOPES:-无}）"
fi
case "$CFG" in
    *server_url*box_api_key*) note_ok "配置同时含 server_url 与 box_api_key" ;;
    *) note_fail "配置缺字段：${CFG:-无}" ;;
esac
if [ -r "$DATA/.beam_box_api_key" ]; then
    note_ok "Key 明文已缓存到数据卷"
else
    note_fail "Key 明文未落缓存（下次启动会重建 ⇒ Key 列表膨胀）"
fi

# ── 判据 ②：二次执行不得再建 Key（幂等）────────────────────────────────
echo "── 判据 ②：二次执行（幂等，不得再建 Key）"
run_prewire "$PREWIRE"
CREATED2=$(state_get created)
if [ "$CREATED2" = "1" ]; then
    note_ok "二次执行未再建 Key（创建计数仍 1）"
else
    note_fail "二次执行又建了 Key（创建计数 ${CREATED2}）⇒ 每次启动都多一把"
fi

# ── 判据 ③：不得冲掉用户已配的 registry（只发非空字段）──────────────────
echo "── 判据 ③：配置里不得出现空 registry（不得冲掉用户已配项）"
if printf '%s' "${CFG:-}" | grep -q '"registry"'; then
    note_fail "配置里带 registry（应只发 server_url + box_api_key）"
else
    note_ok "配置只发 server_url + box_api_key"
fi

# ── 判据 ④：令牌文件晚出现 ⇒ 预接线仍须等到就绪后完成 ──────────────────
#   openwrt 的 Box 与 p2pcweb 由 procd **异步**拉起 ⇒ 调用时刻可能早于就绪
#   ⇒ 「等待就绪」必须**在脚本里**（各端包装函数只管后台调用）
#   ⇒ 否则会**偶发**跳过 ⇒ 表现为「装完还是得手填」，且极难复现。
echo "── 判据 ④：等待就绪（令牌文件晚出现）"
rm -f "$DATA/.p2pcweb_token"
( sleep 3; printf 'BEAMTOKEN123' > "$DATA/.p2pcweb_token" ) &
DELAY_PID=$!
PB_PREWIRE_WAIT_MAX=20 run_prewire "$PREWIRE"
wait "$DELAY_PID" 2>/dev/null
CFG4=$(state_get config)
case "$CFG4" in
    *box_api_key*) note_ok "令牌晚到也能等到就绪并完成预置" ;;
    *) note_fail "令牌晚到时未完成预置（等待逻辑失效）" ;;
esac

# ── 负对照 A：改坏「缓存有效则复用」⇒ 判据 ② 必须红 ───────────────────
echo "── 负对照 A：改坏复用逻辑（判据 ② 必须红）"
BAD="$TMP/prewire-bad.sh"
# 只把校验分支的匹配值改掉 ⇒ 走「已失效 ⇒ 清空 ⇒ 重建」分支 ⇒ 每次都建新 Key。
# ⚠️ **只能改这一处**：若同时删掉「清空 cached_key」，变异会互相抵消 ⇒ 变异无效。
# shellcheck disable=SC2016  # 单引号里的 $code 是**要匹配的字面量**，不可展开
sed 's|^    case "\$code" in$|    case "forced" in|' "$PREWIRE" > "$BAD"
rm -f "$DATA/.beam_box_api_key"
run_prewire "$BAD"
BAD_FIRST=$(state_get created)
run_prewire "$BAD"
BAD_SECOND=$(state_get created)
if [ "${BAD_SECOND:-0}" -gt "${BAD_FIRST:-0}" ]; then
    note_ok "坏副本每次都建 Key（${BAD_FIRST}→${BAD_SECOND}）⇒ 判据 ② 会红（有牙齿）"
else
    note_fail "坏副本未体现「不复用」（${BAD_FIRST}→${BAD_SECOND}）⇒ 变异无效，判据 ② 无牙齿"
fi

# ── 负对照 B：改窄 scope ⇒ 判据 ① 必须红 ───────────────────────────────
echo "── 负对照 B：改窄 scope（判据 ① 必须红）"
BAD2="$TMP/prewire-bad2.sh"
sed "s|^SCOPES_JSON=.*|SCOPES_JSON='[\"share\"]'|" "$PREWIRE" > "$BAD2"
rm -f "$DATA/.beam_box_api_key"
run_prewire "$BAD2"
SCOPES2=$(state_get scopes)
if [ "$SCOPES2" = "['share']" ]; then
    note_ok "坏副本确实改窄了 scope（判据 ① 能抓住它）"
else
    note_fail "坏副本未改窄 scope（${SCOPES2:-无}）⇒ 变异无效"
fi

if [ "$fails" -gt 0 ]; then
    echo
    echo "✗ $fails 条判据失效"
    exit 1
fi
echo
echo "✓ prewire-beam-box.sh 的判据全部有效"
OK=1
exit 0
