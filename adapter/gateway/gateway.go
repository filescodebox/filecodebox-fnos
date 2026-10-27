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
// ## 两类头必须分开对待(2026-10-28 真机实证:此前混为一谈 ⇒ SSO 恒 401)
//
// ① 来源凭证(X-PB-Trim-Gateway):本代理自己的随机 nonce。直连业务 TCP 端口的
//
//	请求同样能到达 Hertz,若仅凭"存在 X-Trim-* 头"判定网关来源,攻击者可伪造
//	头冒充任意 NAS 用户。故代理**剥离**入站同名头并**注入**自己的 nonce,
//	消费端(如 sso)必须比对 nonce。
//
// ② 身份断言(X-Trim-*):这是**飞牛网关替我们断言**的当前登录用户——官方文档
//
//	「会话校验和用户 Header」的转发示例即为此三行,并明确要求"不要信任客户端
//	传入的用户 ID,请使用飞牛 fnOS 转发的网关鉴权 Header"。它们**必须转发给
//	上游**,否则消费端永远拿不到身份。
//	⇒ 此前把 X-Trim-* 与 nonce 一并剥离,是**误删**。
//
// 误删的后果不是"多一分安全",而是功能整体失效:真机(fnOS 4.0.7)上
// /api/fnos/login **恒 401**(「网关未携带用户身份」),前端退回登录页,
// 「统一网关免登录」自 2026-10-13 上线起从未成功过一次(nginx 访问日志可查)。
//
// ## 转发身份断言的信任边界
//
// 既然要转发 X-Trim-*,就得回答"谁能连这个 socket"。实测(fnOS 真机):socket 权限
// 755 pigeonbox:pigeonbox,非属主的本地用户(zhangyi, uid 1000, 无 DAC_OVERRIDE)
// **仍能 connect** ⇒ 文件权限不是可靠边界 ⇒ 不能只凭"能连 socket"就转发身份头。
//
// 故:代理按**对端凭据**(SO_PEERCRED)判定对端是否可信,只对可信对端(飞牛网关
// worker / root / 应用自身)带来的身份断言放行;其余对端一律剥离并告警。
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

	// trustedUIDs 允许其身份断言被转发的对端 uid(飞牛网关 worker / root / 自身)。
	trustedUIDs map[uint32]bool
	// peerUIDFn 取连接对端的 uid(测试可替换;默认用平台实现 SO_PEERCRED)。
	peerUIDFn func(net.Conn) (uint32, bool)
}

// Listen 创建 socket 并开始监听(不 accept,由 Serve 驱动)。
//
// trustedUIDs:可对端凭据信任的 uid 集合——只有这些对端带来的 X-Trim-* 身份
// 断言才会被转发给上游(见包注释「转发身份断言的信任边界」)。
func Listen(socketPath, prefix, upstreamPort string, trustedUIDs []uint32) (*Server, error) {
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
	trusted := make(map[uint32]bool, len(trustedUIDs))
	for _, uid := range trustedUIDs {
		trusted[uid] = true
	}
	s := &Server{
		socketPath:  socketPath,
		prefix:      prefix,
		upstream:    "http://127.0.0.1:" + upstreamPort,
		nonce:       hex.EncodeToString(nonce),
		trustedUIDs: trusted,
		peerUIDFn:   peerUID,
	}
	// 对端 uid 采集走 s.peerUIDFn(闭包引用,便于测试替换实现)。
	s.ln = &peerListener{Listener: ln, peerUIDFn: func(c net.Conn) (uint32, bool) {
		return s.peerUIDFn(c)
	}}
	return s, nil
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
		// ① 来源凭证:剥离入站伪造值,注入本进程 nonce——
		//    保证消费端见到的 X-PB-Trim-Gateway 只可能来自本代理。
		req.Header.Del(NonceHeader)
		req.Header.Set(NonceHeader, s.nonce)
		// ② 身份断言:X-Trim-* 是飞牛网关替我们断言的登录用户,必须转发给上游;
		//    但只对**可信对端**放行(对端凭据判定),其余对端一律剥离并告警。
		uid, known := peerUIDFromContext(req.Context())
		if !s.trustedPeer(uid, known) {
			forged := false
			for _, h := range TrimUserHeaders {
				if req.Header.Get(h) != "" {
					forged = true
				}
				req.Header.Del(h)
			}
			if forged {
				logger.Warn("网关:拒绝转发非可信对端的身份断言头",
					zap.Uint32("peer_uid", uid),
					zap.Bool("peer_uid_known", known))
			}
		}
	}
	// socket 场景默认 ErrorLogger 会写 stderr;挂到项目 logger 便于 app.log 排查。
	proxy.ErrorLog = log.New(&logWriter{fn: func(p []byte) (int, error) {
		logger.Warn("网关反代: " + string(p))
		return len(p), nil
	}}, "", 0)

	// 裸前缀(无尾斜杠)301 补斜杠:宿主入口 iframe src=/app/pigeonbox(无斜杠),
	// 前端以 ./ 相对引用资源,document 无尾斜杠会把 ./assets 解析成 /app/assets
	// 落到框架 404——重定向到带斜杠路径后相对解析才正确。
	s.srv = &http.Server{
		// 对端凭据随连接带入请求上下文(Director 据此判定是否放行身份断言)。
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			pc, ok := c.(*peerConn)
			if !ok {
				return ctx
			}
			return context.WithValue(ctx, peerUIDKey{}, peerInfo{uid: pc.uid, known: pc.known})
		},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == s.prefix {
				http.Redirect(w, r, s.prefix+"/", http.StatusMovedPermanently)
				return
			}
			proxy.ServeHTTP(w, r)
		}),
	}
	logger.Info("统一网关 socket 已监听",
		zap.String("socket", s.socketPath),
		zap.String("prefix", s.prefix),
		zap.String("upstream", s.upstream),
		zap.Any("trusted_peer_uids", s.trustedUIDList()))
	if err := s.srv.Serve(s.ln); err != nil && err != http.ErrServerClosed {
		logger.Error("网关 socket 服务退出", zap.Error(err))
	}
}

// trustedPeer 对端是否可信(可转发其身份断言)。
//
// 取不到对端凭据(known=false)时**不信任**:宁可让 SSO 显式失败,也不让身份
// 断言在无法验证来源时被采信。
func (s *Server) trustedPeer(uid uint32, known bool) bool {
	if !known {
		return false
	}
	return s.trustedUIDs[uid]
}

// trustedUIDList 可信对端 uid 列表(启动日志用)。
func (s *Server) trustedUIDList() []uint32 {
	out := make([]uint32, 0, len(s.trustedUIDs))
	for uid := range s.trustedUIDs {
		out = append(out, uid)
	}
	return out
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
