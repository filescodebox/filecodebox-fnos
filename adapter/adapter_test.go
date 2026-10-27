package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/ut"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	fclogger "github.com/pigeonbox/core/pkg/logger"

	"github.com/pigeonbox/fnos/adapter/gateway"
	"github.com/pigeonbox/fnos/adapter/internal/fnosconfig"
)

// TestMain 初始化最小 logger,避免 Mount 内 logger 输出在全局变量为 nil 时 panic。
func TestMain(m *testing.M) {
	_ = fclogger.Init(&fclogger.Config{Level: "error"}) // 测试只需 error 级,降噪
	os.Exit(m.Run())
}

// newTestEngine 建一个空 Hertz + 探针路由,挂载指定 cfg 的 adapter。
// 不调用 bootstrap.Bootstrap(),零 DB/Redis/JWT 副作用。
func newTestEngine(t *testing.T, cfg fnosconfig.Config) *server.Hertz {
	t.Helper()
	h := server.Default()
	// 探针路由:模拟 PigeonBox 业务路由,验证 adapter 不影响它
	h.GET("/api/v1/ping", func(ctx context.Context, c *app.RequestContext) {
		c.JSON(consts.StatusOK, map[string]string{"msg": "pong"})
	})
	Mount(h, cfg)
	return h
}

// 全降级模式(非 fnOS 环境):capabilities 如实回报,业务路由不受影响。
func TestMount_DisabledMode_Capabilities(t *testing.T) {
	cfg := fnosconfig.Config{DisabledReason: "未检测到 fnOS 运行环境"}
	h := newTestEngine(t, cfg)

	w := ut.PerformRequest(h.Engine, consts.MethodGet, "/api/fnos/capabilities", nil)
	resp := w.Result()
	assert.Equal(t, consts.StatusOK, resp.StatusCode())
	var body struct {
		Data map[string]any `json:"data"`
	}
	require.NoError(t, json.Unmarshal(resp.Body(), &body))
	assert.Equal(t, false, body.Data["gateway"])
	assert.Equal(t, false, body.Data["trimapi"])
	assert.Equal(t, true, body.Data["disabled"])

	// SSO/shares 端点在降级模式不注册 → 404(比 503 更诚实:能力不存在)
	w = ut.PerformRequest(h.Engine, consts.MethodPost, "/api/fnos/login", nil)
	assert.Equal(t, consts.StatusNotFound, w.Result().StatusCode(), "降级模式不应注册 login 路由")

	// 业务探针不受影响
	w = ut.PerformRequest(h.Engine, consts.MethodGet, "/api/v1/ping", nil)
	assert.Equal(t, consts.StatusOK, w.Result().StatusCode())
}

// 挂载/停机不产生残留 socket 文件。
func TestMount_GatewayDisabled_NoSocketSideEffects(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "app.sock")
	cfg := fnosconfig.Config{
		GatewayEnabled: false,
		SocketPath:     sock,
		ServerPort:     "19999",
	}
	h := newTestEngine(t, cfg)
	_ = h
	_, err := os.Stat(sock)
	assert.True(t, os.IsNotExist(err), "网关未启用时不得创建 socket 文件")
}

// 网关反代端到端:stripPrefix + nonce 注入 + 入站伪造头剥离。
func TestGateway_ProxyStripsPrefixAndInjectsNonce(t *testing.T) {
	// 上游:真实 HTTP server,回显收到的 path 与头。
	upstream := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{
				"path":     r.URL.Path,
				"nonce":    r.Header.Get(gateway.NonceHeader),
				"trim_uid": r.Header.Get("X-Trim-Userid"),
			})
		}),
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	go upstream.Serve(ln)
	defer upstream.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	// macOS sun_path 上限 104 字节,t.TempDir() 前缀过长,用 /tmp 短路径。
	sock := filepath.Join("/tmp", fmt.Sprintf("pb-gw-test-%d.sock", time.Now().UnixNano()))
	gw, err := gateway.Listen(sock, "/app/pigeonbox", fmt.Sprintf("%d", port), nil)
	require.NoError(t, err)
	go gw.Serve()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = gw.Shutdown(ctx)
	}()

	// 等 socket 就绪
	require.Eventually(t, func() bool {
		_, err := os.Stat(sock)
		return err == nil
	}, 2*time.Second, 20*time.Millisecond)

	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}

	// ① 前缀路径剥离 + 入站伪造头剥离(客户端模拟携带伪造头打 socket)
	req, err := http.NewRequest(http.MethodGet, "http://localhost/app/pigeonbox/api/v1/ping", nil)
	require.NoError(t, err)
	req.Header.Set("X-Trim-Userid", "999")
	req.Header.Set(gateway.NonceHeader, "forged-nonce")
	resp, err := client.Do(req)
	require.NoError(t, err)
	var body map[string]string
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&body))
	resp.Body.Close()
	assert.Equal(t, "/api/v1/ping", body["path"], "网关前缀应被剥离")
	assert.NotEmpty(t, body["nonce"], "代理应注入真实 nonce")
	assert.NotEqual(t, "forged-nonce", body["nonce"], "入站伪造 nonce 应被剥离")
	assert.Empty(t, body["trim_uid"], "入站伪造的 X-Trim-* 应被剥离")

	// ② 前缀根路径 → /
	resp2, err := client.Get("http://localhost/app/pigeonbox")
	require.NoError(t, err)
	var body2 map[string]string
	require.NoError(t, json.NewDecoder(resp2.Body).Decode(&body2))
	resp2.Body.Close()
	assert.Equal(t, "/", body2["path"])

	// ②b 裸前缀(无尾斜杠)→ 301 重定向到带斜杠(相对资源解析的前提)
	noRedirect := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Transport: client.Transport,
	}
	respN, err := noRedirect.Get("http://localhost/app/pigeonbox")
	require.NoError(t, err)
	respN.Body.Close()
	assert.Equal(t, http.StatusMovedPermanently, respN.StatusCode, "裸前缀应 301")
	assert.Equal(t, "/app/pigeonbox/", respN.Header.Get("Location"))

	// ③ 段边界防误剥:/app/pigeonboxfoo 不剥离
	resp3, err := client.Get("http://localhost/app/pigeonboxfoo/x")
	require.NoError(t, err)
	var body3 map[string]string
	require.NoError(t, json.NewDecoder(resp3.Body).Decode(&body3))
	resp3.Body.Close()
	assert.Equal(t, "/app/pigeonboxfoo/x", body3["path"], "段边界误剥应被拒绝")

	// ④ 停机清理 socket
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	require.NoError(t, gw.Shutdown(ctx))
	_, err = os.Stat(sock)
	assert.True(t, os.IsNotExist(err), "停机应清理 socket 文件")
}
