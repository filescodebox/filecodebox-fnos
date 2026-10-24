// Package gateway 实现飞牛「统一网关」接入(developer.fnnas.com/docs/core-concepts/gateway-registration)。
//
// 官方模型:应用入口声明 gatewayPrefix(/app/pigeonbox)+gatewaySocket(app.sock),
// 飞牛框架校验 NAS 登录态后,把网关路径请求转发到应用 target 目录下的 Unix Socket,
// 并注入可信用户头(X-Trim-Userid / X-Trim-Isadmin / X-Trim-Username)。
//
// 本包在该 socket 上运行一个 stripPrefix 反向代理:
//
//	/app/pigeonbox/user/login  →(剥前缀)→  127.0.0.1:PORT/user/login
//
// 业务与前端资源全部复用既有 Hertz 服务,前端以任意前缀部署都零路由改动。
//
// 防伪造:直连业务 TCP 端口的请求同样能到达 Hertz,若仅凭"存在 X-Trim-* 头"
// 判定网关来源,攻击者可伪造头冒充任意 NAS 用户。故代理在转发时注入启动期
// 随机 nonce 头(X-PB-Trim-Gateway),SSO 等身份消费端必须比对 nonce——
// 代理同时剥离入站请求携带的同名头与 X-Trim-* 头,确保 nonce 只能由代理注入。
package gateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"

	"github.com/pigeonbox/core/pkg/logger"
	"go.uber.org/zap"
)

// NonceHeader 代理注入的网关来源凭证头(消费端见 sso 包)。
const NonceHeader = "X-PB-Trim-Gateway"

// TrimUserHeaders 飞牛网关注入的可信用户头(官方文档「会话校验和用户 Header」)。
var TrimUserHeaders = []string{"X-Trim-Userid", "X-Trim-Isadmin", "X-Trim-Username"}

// Server 统一网关 socket 服务。
type Server struct {
	socketPath string
	prefix     string
	upstream   string
	nonce      string
	ln         net.Listener
	srv        *http.Server
}

// Listen 创建 socket 并开始监听(不 accept,由 Serve 驱动)。
func Listen(socketPath, prefix, upstreamPort string) (*Server, error) {
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("清理旧网关 socket 失败: %w", err)
	}
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("监听网关 socket %s 失败: %w", socketPath, err)
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		_ = ln.Close()
		return nil, fmt.Errorf("生成网关 nonce 失败: %w", err)
	}
	return &Server{
		socketPath: socketPath,
		prefix:     prefix,
		upstream:   "http://127.0.0.1:" + upstreamPort,
		nonce:      hex.EncodeToString(nonce),
		ln:         ln,
	}, nil
}

// Nonce 返回本次运行网关来源凭证(SSO 等消费端比对用)。
func (s *Server) Nonce() string { return s.nonce }

// Serve 启动反代(阻塞;调用方自行 go Serve())。
func (s *Server) Serve() {
	target, err := url.Parse(s.upstream)
	if err != nil {
		logger.Error("网关反代上游解析失败", zap.String("upstream", s.upstream), zap.Error(err))
		return
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		stripGatewayPrefix(req, s.prefix)
		// 剥离入站伪造的来源/用户头,再注入本进程 nonce——保证消费端
		// 见到的 X-PB-Trim-Gateway / X-Trim-* 只可能来自本代理。
		req.Header.Del(NonceHeader)
		for _, h := range TrimUserHeaders {
			req.Header.Del(h)
		}
		req.Header.Set(NonceHeader, s.nonce)
	}
	// socket 场景默认 ErrorLogger 会写 stderr;挂到项目 logger 便于 app.log 排查。
	proxy.ErrorLog = log.New(&logWriter{fn: func(p []byte) (int, error) {
		logger.Warn("网关反代: " + string(p))
		return len(p), nil
	}}, "", 0)

	// 裸前缀(无尾斜杠)301 补斜杠:宿主入口 iframe src=/app/pigeonbox(无斜杠),
	// 前端以 ./ 相对引用资源,document 无尾斜杠会把 ./assets 解析成 /app/assets
	// 落到框架 404——重定向到带斜杠路径后相对解析才正确。
	s.srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == s.prefix {
			http.Redirect(w, r, s.prefix+"/", http.StatusMovedPermanently)
			return
		}
		proxy.ServeHTTP(w, r)
	})}
	logger.Info("统一网关 socket 已监听",
		zap.String("socket", s.socketPath),
		zap.String("prefix", s.prefix),
		zap.String("upstream", s.upstream))
	if err := s.srv.Serve(s.ln); err != nil && err != http.ErrServerClosed {
		logger.Error("网关 socket 服务退出", zap.Error(err))
	}
}

// Shutdown 优雅停机并清理 socket 文件。
// 注:Go 的 unix listener Close 时会自行 unlink,remove 撞 ENOENT 属正常路径。
func (s *Server) Shutdown(ctx context.Context) error {
	if s.srv != nil {
		_ = s.srv.Shutdown(ctx)
	}
	if err := os.Remove(s.socketPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// stripGatewayPrefix 剥离网关前缀:/app/pigeonbox/xyz → /xyz。
// 前缀必须完整命中段边界(/app/pigeonboxfoo 不得误剥)。
func stripGatewayPrefix(req *http.Request, prefix string) {
	switch {
	case req.URL.Path == prefix:
		req.URL.Path = "/"
		req.URL.RawPath = ""
	case strings.HasPrefix(req.URL.Path, prefix+"/"):
		req.URL.Path = req.URL.Path[len(prefix):]
		req.URL.RawPath = ""
	}
	// 前端以 ./ 相对引用资源,Referer 无关;Host 沿用代理目标即可。
}

// logWriter 把函数适配为 io.Writer(反代错误日志接入项目 logger)。
type logWriter struct {
	fn func([]byte) (int, error)
}

func (w *logWriter) Write(p []byte) (int, error) { return w.fn(p) }
