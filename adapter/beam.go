package adapter

// PigeonBeam 信鸽直传入口端点(A2 内嵌,2026-10-16):
// GET /beam —— Box 会话守门的跳转页:已登录 → 302 到本机 p2pcweb(带持久令牌);
// 未登录/过期 → 文字提示先登录。令牌只向已认证用户发放(直连端口裸请求拿不到;
// p2pcweb 自身另有令牌门禁,双门叠加)。p2pcweb 由包生命周期脚本托管(fnos/cmd/
// main),LAN 端口 PB_P2PCWEB_PORT(默认 12348),令牌文件落数据卷跨重启稳定。
// 与 /api/fnos/* 同为适配层路由,不在 core IDL 面(平台仓适配器惯例)。

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"go.uber.org/zap"

	"github.com/pigeonbox/core/pkg/auth"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/core/pkg/middleware"
)

const beamDefaultPort = "12348"

// MountBeam 挂载 /beam 入口(独立于 fnOS 网关配置,任何环境可用;
// 非 fnOS 环境 PB_DATA_PATH 未设时组件未就绪,如实回报)。
func MountBeam(h *server.Hertz) {
	h.GET("/beam", func(ctx context.Context, c *app.RequestContext) {
		// 会话门:Bearer 头或 Cookie 任一(PigeonBox 统一会话语义)
		token, _ := middleware.SessionToken(c)
		if token == "" {
			c.String(consts.StatusUnauthorized, "text/plain; charset=utf-8",
				[]byte("设备直传入口:请先登录 PigeonBox 后再访问本页。"))
			return
		}
		if _, err := auth.ParseToken(token); err != nil {
			c.String(consts.StatusUnauthorized, "text/plain; charset=utf-8",
				[]byte("登录已过期,请重新登录 PigeonBox 后再访问。"))
			return
		}

		dataDir := os.Getenv("PB_DATA_PATH")
		tokenPath := filepath.Join(dataDir, ".p2pcweb_token")
		raw, err := os.ReadFile(tokenPath)
		beamToken := strings.TrimSpace(string(raw))
		if err != nil || beamToken == "" {
			logger.Warn("beam 入口: 令牌文件不可读(p2pcweb 未安装或未启动)",
				zap.String("path", tokenPath), zap.Error(err))
			c.String(consts.StatusServiceUnavailable, "text/plain; charset=utf-8",
				[]byte("设备直传组件未就绪(p2pcweb 未安装或未启动,请稍后再试或联系管理员)。"))
			return
		}

		port := strings.TrimSpace(os.Getenv("PB_P2PCWEB_PORT"))
		if port == "" {
			port = beamDefaultPort
		}
		host := string(c.Host())
		hn, _, err := net.SplitHostPort(host)
		if err != nil || hn == "" {
			hn = host
		}
		target := fmt.Sprintf("http://%s/?t=%s", net.JoinHostPort(hn, port), beamToken)
		logger.Info("beam 入口跳转", zap.String("host", net.JoinHostPort(hn, port)))
		c.Redirect(consts.StatusFound, []byte(target))
	})
}
