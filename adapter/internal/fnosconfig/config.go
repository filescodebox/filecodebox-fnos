// Package fnosconfig 定义飞牛适配层的配置类型与加载逻辑。
//
// 独立为子包以打破循环依赖:adapter 父包与 gateway/sso/storage 子模块
// 都引用本包的 Config,而本包不依赖任何 adapter 子包,从而无环。
//
// 2026-10-09 模型重写:官方开放平台( developer.fnnas.com )不存在
// "open.fnnas.com + appid/secret" 式 REST 凭证体系,真实接入模型为——
//
//	统一网关:入口声明 gatewayPrefix+gatewaySocket,框架校验 NAS 登录态后
//	         把请求转发到应用监听的 Unix Socket,并注入 X-Trim-* 可信用户头;
//	后端 API:应用经 /var/run/trim_open_gateway_apiscope.socket +
//	         TRIM_API_TOKEN(框架在拉起应用脚本时注入 env)调用 trim.* 能力;
//	前端 JS SDK:@trimjs/web-app(需 manifest micro_app=true)。
//
// 故启用探测全部来自 TRIM_* 运行环境,不再需要用户手工填凭证。
package fnosconfig

import (
	"os"
	"path/filepath"
)

// 官方约定路径与环境变量(developer.fnnas.com/docs:调用方式/环境变量)。
const (
	// DefaultTrimAPISocket 官方后端开放 API 的 Unix Socket。
	DefaultTrimAPISocket = "/var/run/trim_open_gateway_apiscope.socket"
	// DefaultGatewayPrefix 统一网关公开路径前缀(/app/{appname})。
	DefaultGatewayPrefix = "/app/pigeonbox"
	// DefaultGatewaySocketName 网关转发目标 socket 文件名(须位于应用 target 目录)。
	DefaultGatewaySocketName = "app.sock"
	// DefaultAppName manifest.appname。
	DefaultAppName = "pigeonbox"
)

// Config 是飞牛适配层的配置,全部来自运行环境探测。
type Config struct {
	// GatewayEnabled 统一网关模式:进程运行在 fnOS 原生应用环境
	// (TRIM_APPDEST 非空)。启用后监听 ${TRIM_APPDEST}/app.sock,
	// 经网关进来的请求带 NAS 登录态用户头(SSO 免登录的前提)。
	GatewayEnabled bool
	// SocketPath 网关监听的 Unix Socket 绝对路径。
	SocketPath string
	// GatewayPrefix 网关公开路径前缀(反代剥离后转交业务)。
	GatewayPrefix string

	// TrimAPIEnabled 官方后端开放 API 可用(api scope socket 存在)。
	TrimAPIEnabled bool
	// TrimAPISocket 官方 API Unix Socket 路径。
	TrimAPISocket string
	// AppName 应用名(trimapi 请求体 appName 字段,取 TRIM_APPNAME)。
	AppName string

	// ServerPort 业务监听端口(网关反代上游 + 直连兜底入口)。
	ServerPort string

	// DisabledReason 降级原因(Gateway/TrimAPI 皆不可用时,供日志与探测端点输出)。
	DisabledReason string
}

// LoadConfig 从运行环境加载飞牛适配配置。
//
// 环境变量(全部由 fnOS 框架注入,见官方文档「环境变量」):
//   - TRIM_APPDEST      应用安装 target 目录;非空=原生应用环境(网关模式前提)
//   - TRIM_APPNAME      应用名(trimapi appName;缺省 pigeonbox)
//   - PB_GATEWAY_SOCKET 网关 socket 路径覆盖(缺省 ${TRIM_APPDEST}/app.sock)
//   - PB_GATEWAY_PREFIX 网关前缀覆盖(缺省 /app/pigeonbox)
//   - PB_SERVER_PORT    业务端口(缺省 12345)
//
// 非 fnOS 环境(裸进程)无 TRIM_* 变量,配置自然全降级——业务不受影响。
func LoadConfig() Config {
	cfg := Config{
		AppName:       getenvOr("TRIM_APPNAME", DefaultAppName),
		ServerPort:    getenvOr("PB_SERVER_PORT", "12345"),
		GatewayPrefix: getenvOr("PB_GATEWAY_PREFIX", DefaultGatewayPrefix),
		TrimAPISocket: getenvOr("PB_TRIM_API_SOCKET", DefaultTrimAPISocket),
	}

	// 网关模式:仅原生应用环境启用(app.sock 必须落在应用 target 目录)。
	if appDest := os.Getenv("TRIM_APPDEST"); appDest != "" {
		cfg.GatewayEnabled = true
		cfg.SocketPath = getenvOr("PB_GATEWAY_SOCKET", filepath.Join(appDest, DefaultGatewaySocketName))
	}

	// 官方后端 API:socket 存在即视为可用(token 走 env 每次现读,不落盘不缓存)。
	if st, err := os.Stat(cfg.TrimAPISocket); err == nil && st.Mode()&os.ModeSocket != 0 {
		cfg.TrimAPIEnabled = true
	}

	switch {
	case cfg.GatewayEnabled && cfg.TrimAPIEnabled:
		// 全能力:SSO + 授权目录 + 页面路由联动。
	case cfg.GatewayEnabled:
		cfg.DisabledReason = "统一网关已就绪,官方后端 API socket 不可达(" + cfg.TrimAPISocket + "):SSO 可用,授权目录/平台配置不可用"
	case cfg.TrimAPIEnabled:
		cfg.DisabledReason = "官方后端 API 可用,统一网关未启用(无 TRIM_APPDEST):授权目录可查,SSO 不可用"
	default:
		cfg.DisabledReason = "未检测到 fnOS 运行环境(无 TRIM_APPDEST,官方 API socket 不存在):飞牛深度集成关闭,业务全功能"
	}
	return cfg
}

func getenvOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
