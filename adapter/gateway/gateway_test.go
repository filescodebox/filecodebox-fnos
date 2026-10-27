package gateway

// 网关反代对**身份断言头(X-Trim-*)**的处理(2026-10-28 真机实证)。
//
// ## 为什么要拆开测
//
// 网关上曾有两类头被混为一谈:
//   · X-PB-Trim-Gateway = 本代理自己的 nonce(证明"请求经由 socket 而非直连 TCP 端口");
//   · X-Trim-*          = **飞牛网关替我们断言**的登录用户(官方文档的转发示例即此三行)。
// 此前把 X-Trim-* 与 nonce 一并剥离 ⇒ 消费端永远拿不到身份 ⇒ 真机上
// /api/fnos/login 恒 401、「统一网关免登录」从未成功过一次。
//
// ## 判据
//
// ① 可信对端(飞牛网关 worker/root/自身)⇒ X-Trim-* **必须转发**给上游;
// ② 不可信对端 ⇒ X-Trim-* 必须被剥离(否则任何能连 socket 的本地用户都能冒充
//    任意 NAS 用户——真机实测 socket 权限不是可靠边界);
// ③ 取不到对端凭据 ⇒ 按不可信处理;
// ④ 入站伪造的 nonce 一律被本代理的 nonce 覆盖。

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// echoHeaders 上游:把收到的头与路径回显成 JSON。
func echoHeaders(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := json.Marshal(map[string]any{
			"path":    r.URL.Path,
			"headers": r.Header,
		})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// startGateway 起真实网关 socket(上游为 echo 服务),并注入对端 uid 判定。
func startGateway(t *testing.T, upstream *httptest.Server, trusted []uint32, peerUID uint32, known bool) *Server {
	t.Helper()
	u, err := url.Parse(upstream.URL)
	require.NoError(t, err)
	port := u.Port()
	require.NotEmpty(t, port)

	// socket 路径要短:macOS 的 unix socket 路径上限 ~104 字节(t.TempDir() 的
	// 长路径会 bind 失败),故用短前缀的临时目录。
	dir, err := os.MkdirTemp("", "pbgw")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "a.sock")
	s, err := Listen(sock, "/app/pigeonbox", port, trusted)
	require.NoError(t, err)
	// 注入对端 uid(测试不依赖运行用户的真实 uid)。
	s.peerUIDFn = func(net.Conn) (uint32, bool) { return peerUID, known }

	go s.Serve()
	t.Cleanup(func() { _ = s.Shutdown(context.Background()) })

	// 等 socket 可连。
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("unix", sock, 200*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return s
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("网关 socket 未就绪: %s", sock)
	return nil
}

// socketGet 经 unix socket 发请求,返回上游回显的 path 与头。
func socketGet(t *testing.T, sock, path string, headers map[string]string) (string, http.Header) {
	t.Helper()
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}
	req, err := http.NewRequest(http.MethodGet, "http://gateway"+path, nil)
	require.NoError(t, err)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	require.NoError(t, err)
	defer func() { _ = resp.Body.Close() }()

	var out struct {
		Path    string      `json:"path"`
		Headers http.Header `json:"headers"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&out))
	return out.Path, out.Headers
}

// TestGateway_TrustedPeer_ForwardsIdentity 可信对端 ⇒ 身份断言必须转发到上游。
func TestGateway_TrustedPeer_ForwardsIdentity(t *testing.T) {
	upstream := echoHeaders(t)
	s := startGateway(t, upstream, []uint32{712}, 712, true)

	path, headers := socketGet(t, s.socketPath, "/app/pigeonbox/api/fnos/login", map[string]string{
		"X-Trim-Userid":   "1000",
		"X-Trim-Username": "zhangyi",
		"X-Trim-Isadmin":  "true",
	})
	assert.Equal(t, "/api/fnos/login", path, "网关前缀应被剥离")
	assert.Equal(t, "1000", headers.Get("X-Trim-Userid"), "可信对端的身份断言必须转发")
	assert.Equal(t, "zhangyi", headers.Get("X-Trim-Username"))
	assert.Equal(t, "true", headers.Get("X-Trim-Isadmin"))
}

// TestGateway_UntrustedPeer_StripsIdentity 不可信对端 ⇒ 身份断言必须被剥离。
//
// 真机背景:socket 权限不是可靠边界(非属主本地用户仍能 connect)⇒ 不能只凭
// "能连 socket"就采信其携带的身份断言。
func TestGateway_UntrustedPeer_StripsIdentity(t *testing.T) {
	upstream := echoHeaders(t)
	s := startGateway(t, upstream, []uint32{712}, 1000, true)

	_, headers := socketGet(t, s.socketPath, "/app/pigeonbox/api/fnos/login", map[string]string{
		"X-Trim-Userid":   "1000",
		"X-Trim-Username": "attacker",
		"X-Trim-Isadmin":  "true",
	})
	assert.Empty(t, headers.Get("X-Trim-Userid"), "不可信对端的身份断言必须被剥离")
	assert.Empty(t, headers.Get("X-Trim-Username"))
	assert.Empty(t, headers.Get("X-Trim-Isadmin"))
}

// TestGateway_UnknownPeer_StripsIdentity 取不到对端凭据 ⇒ 按不可信处理。
func TestGateway_UnknownPeer_StripsIdentity(t *testing.T) {
	upstream := echoHeaders(t)
	s := startGateway(t, upstream, []uint32{712}, 712, false)

	_, headers := socketGet(t, s.socketPath, "/app/pigeonbox/api/fnos/login", map[string]string{
		"X-Trim-Userid": "1000",
	})
	assert.Empty(t, headers.Get("X-Trim-Userid"), "对端凭据未知时不得采信身份断言")
}

// TestGateway_NonceAlwaysReplaced 入站伪造的来源凭证一律被本代理的 nonce 覆盖。
func TestGateway_NonceAlwaysReplaced(t *testing.T) {
	upstream := echoHeaders(t)
	s := startGateway(t, upstream, []uint32{712}, 712, true)

	_, headers := socketGet(t, s.socketPath, "/app/pigeonbox/beam", map[string]string{
		NonceHeader: "forged-nonce-xxx",
	})
	assert.NotEqual(t, "forged-nonce-xxx", headers.Get(NonceHeader), "入站伪造 nonce 必须被覆盖")
	assert.Equal(t, s.Nonce(), headers.Get(NonceHeader), "上游必须看到本代理注入的 nonce")
}

// TestGateway_TrustedPeerList_EmptyMeansUntrusted 未配置可信 uid ⇒ 谁都不信任。
func TestGateway_TrustedPeerList_EmptyMeansUntrusted(t *testing.T) {
	upstream := echoHeaders(t)
	s := startGateway(t, upstream, nil, 0, true)

	_, headers := socketGet(t, s.socketPath, "/app/pigeonbox/api/fnos/login", map[string]string{
		"X-Trim-Userid": "0",
	})
	assert.Empty(t, headers.Get("X-Trim-Userid"))
}

// TestListen_NonceUnique 每次启动的 nonce 必须不同(来源凭证不可复用)。
func TestListen_NonceUnique(t *testing.T) {
	upstream := echoHeaders(t)
	u, err := url.Parse(upstream.URL)
	require.NoError(t, err)

	dir, err := os.MkdirTemp("", "pbgw")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	s1, err := Listen(filepath.Join(dir, "a.sock"), "/app/pigeonbox", u.Port(), nil)
	require.NoError(t, err)
	s2, err := Listen(filepath.Join(dir, "b.sock"), "/app/pigeonbox", u.Port(), nil)
	require.NoError(t, err)

	assert.NotEqual(t, s1.Nonce(), s2.Nonce())
	_, err = strconv.Atoi("0")
	require.NoError(t, err)
}
