// Package adapter 装配飞牛(fnOS)深度集成。
//
// 2026-10-09 按 fnOS 官方开放平台(developer.fnnas.com)真实现,接入模型:
//   统一网关 gateway   — ${TRIM_APPDEST}/app.sock 反代(stripPrefix → 业务端口),
//                        请求带 NAS 登录态用户头(官网「统一网关」);
//   SSO 免登录 sso     — 网关可信头 → 本地用户映射 + 会话签发(POST /api/fnos/login);
//   授权目录 storage   — 官方后端 API trim.file.* (GET /api/fnos/shares);
//   后端 API client    — internal/trimapi(Unix socket + TRIM_API_TOKEN)。
//
// 官方一期未开放的能力(诚实缺席,不造假):
//   通知中心 / 内网穿透 — 待官方开放后另行接入;此前旧桩(FNOS_APPID/SECRET
//   凭证模型)与真实平台不符,已整体移除。
//
// 降级语义:非 fnOS 环境(裸进程开发调试,无 TRIM_* 变量)一切自动关闭,
// /api/fnos/capabilities 如实回报;PigeonBox 业务不受任何影响。
package adapter

import (
	"context"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/protocol/consts"

	"github.com/pigeonbox/core/pkg/logger"
	"go.uber.org/zap"

	"github.com/pigeonbox/fnos/adapter/gateway"
	"github.com/pigeonbox/fnos/adapter/internal/fnosconfig"
	"github.com/pigeonbox/fnos/adapter/internal/trimapi"
	"github.com/pigeonbox/fnos/adapter/sso"
	"github.com/pigeonbox/fnos/adapter/storage"
)

// 为保持调用方(main.go)接口稳定,在此重导出配置类型与加载函数。
// 真正定义见 adapter/internal/fnosconfig。
type Config = fnosconfig.Config

// LoadConfig 从运行环境加载飞牛适配配置(转发至 fnosconfig 包)。
func LoadConfig() Config {
	return fnosconfig.LoadConfig()
}

// Mount 在已启动的 PigeonBox Hertz server 上挂载飞牛集成,
// 并按配置启动统一网关 socket。返回停机函数(清理 socket;可为 nil)。
func Mount(h *server.Hertz, cfg Config) func(ctx context.Context) error {
	group := h.Group("/api/fnos")

	// PigeonBeam 入口(A2):Box 会话守门的 /beam 跳转,独立于 fnOS 网关配置。
	MountBeam(h)

	// 探测端点:前端据此渲染飞牛联动 UI(任何环境都可用)。
	group.GET("/capabilities", func(ctx context.Context, c *app.RequestContext) {
		c.JSON(consts.StatusOK, map[string]any{
			"code": 200,
			"data": map[string]any{
				"gateway":  cfg.GatewayEnabled,
				"sso":      cfg.GatewayEnabled,
				"shares":   cfg.TrimAPIEnabled,
				"trimapi":  cfg.TrimAPIEnabled,
				"prefix":   cfg.GatewayPrefix,
				"appName":  cfg.AppName,
				"disabled": !(cfg.GatewayEnabled || cfg.TrimAPIEnabled),
				"reason":   cfg.DisabledReason,
			},
		})
	})

	// 官方后端 API:就绪即挂授权目录查询。
	var trimClient *trimapi.Client
	if cfg.TrimAPIEnabled {
		trimClient = trimapi.New(cfg.TrimAPISocket, cfg.AppName)
		storage.Mount(group, cfg, trimClient)
	}

	// 统一网关:仅原生应用环境启用(需要 TRIM_APPDEST 落 app.sock)。
	if !cfg.GatewayEnabled {
		logger.Warn("飞牛深度集成未启用(非 fnOS 原生环境):业务全功能,联动关闭",
			zap.String("reason", cfg.DisabledReason))
		return nil
	}

	gw, err := gateway.Listen(cfg.SocketPath, cfg.GatewayPrefix, cfg.ServerPort)
	if err != nil {
		// 网关起不来不阻断业务:桌面入口退化为端口直连(入口 url=/),记日志告警。
		logger.Error("统一网关 socket 启动失败,深度集成降级(业务不受影响)",
			zap.String("socket", cfg.SocketPath), zap.Error(err))
		return nil
	}
	go gw.Serve()

	// SSO:网关就绪才有可信用户头。
	sso.Mount(group, gw)
	logger.Info("飞牛深度集成已启用:统一网关(SSO) / 授权目录",
		zap.String("socket", cfg.SocketPath),
		zap.String("prefix", cfg.GatewayPrefix),
		zap.Bool("trimapi", cfg.TrimAPIEnabled))

	return func(ctx context.Context) error { return gw.Shutdown(ctx) }
}
