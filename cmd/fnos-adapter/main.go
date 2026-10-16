// Package main 是飞牛(fnOS)应用的容器入口。
//
// 运行时形态:单容器单进程。本二进制以库调用方式拉起 PigeonBox 全部业务
// (bootstrap.Bootstrap),并在同一进程内挂载飞牛 Open API 适配层(SSO/通知/目录/穿透)。
// 适配层以反向代理 + HTTP 中间件方式包裹 *server.Hertz,不修改其内部路由。
//
// 凭证缺失时进入降级模式:飞牛能力关闭,PigeonBox 业务正常运行。
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/pigeonbox/core/bootstrap"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/fnos/adapter"
	"github.com/oekit/core/version"

	"go.uber.org/zap"
)

// 版本信息:kit/version 包内变量,由构建脚本(build-native.sh)-ldflags -X 注入,缺省为 dev。

// ensureJWTSecret 保证 PB_JWT_SECRET 存在:未显式配置时自动生成强密钥,
// 持久化到数据目录(.jwt_secret,权限 0600),重启复用(已签发 token 不失效)。
// 依据:core 的 validateSecrets 在 secret 缺失/弱值时拒绝启动(安全基线);
// NAS 场景用户不应被迫手工生成密钥,故在库拉起前注入。
func ensureJWTSecret() {
	if os.Getenv("PB_JWT_SECRET") != "" {
		return
	}
	dataDir := os.Getenv("PB_DATA_PATH")
	if dataDir == "" {
		dataDir = "./data"
	}
	secretPath := filepath.Join(dataDir, ".jwt_secret")
	if b, err := os.ReadFile(secretPath); err == nil {
		if s := strings.TrimSpace(string(b)); len(s) >= 32 {
			_ = os.Setenv("PB_JWT_SECRET", s)
			return
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		// 加密源不可用属系统级故障,直接失败
		_, _ = os.Stderr.WriteString("无法生成 JWT 密钥(crypto/rand 不可用): " + err.Error() + "\n")
		os.Exit(1)
	}
	secret := hex.EncodeToString(raw)
	_ = os.MkdirAll(dataDir, 0o755)
	if err := os.WriteFile(secretPath, []byte(secret), 0o600); err != nil {
		_, _ = os.Stderr.WriteString("无法持久化 JWT 密钥(" + secretPath + "): " + err.Error() + "\n")
		os.Exit(1)
	}
	_ = os.Setenv("PB_JWT_SECRET", secret)
}

func main() {
	// --config 指定 PigeonBox 配置文件路径(透传给 bootstrap)。
	configPath := flag.String("config", "", "PigeonBox 配置文件路径(默认 configs/config.yaml)")
	// --static 前端静态资源目录:存在则以 WithStaticDir 注入 core(同端口服务
	// 内嵌前端 SPA);不存在保持 core 默认(./static,缺目录时优雅降级为纯 API)。
	staticDir := flag.String("static", "/app/www", "前端静态资源目录(不存在时回退 core 默认)")
	flag.Parse()

	// 注意:logger 必须先经 bootstrap.Init() 初始化后才能使用(logger 全局变量初始为 nil)。
	// 故飞牛适配配置的日志输出放到 bootstrap 之后。

	// 0. 保证 JWT 密钥存在(自动生成 + 数据卷持久化),必须在 bootstrap 读配置前注入。
	ensureJWTSecret()

	// 1. 以库调用方式拉起 PigeonBox 全部业务。
	//    返回的 *server.Hertz 已完成:读配置→初始化logger→建DB→建storage→装路由→装中间件。
	bootOpts := make([]bootstrap.Option, 0, 1)
	if st, err := os.Stat(*staticDir); err == nil && st.IsDir() {
		bootOpts = append(bootOpts, bootstrap.WithStaticDir(*staticDir))
	}
	h, err := bootstrap.BootstrapWithOptions(*configPath, bootOpts...)
	if err != nil {
		// 此时 logger 可能未初始化,fallback 到标准错误输出。
		_, _ = os.Stderr.WriteString("PigeonBox bootstrap 失败: " + err.Error() + "\n")
		os.Exit(1)
	}
	defer bootstrap.Cleanup()

	// 2. 初始化飞牛集成配置(运行环境探测,非 fnOS 环境自然全降级)。
	//    此时 logger 已就绪,可安全调用。
	fnosCfg := adapter.LoadConfig()
	if !fnosCfg.GatewayEnabled && !fnosCfg.TrimAPIEnabled {
		logger.Warn("飞牛深度集成未启用:业务正常运行,飞牛联动关闭",
			zap.String("reason", fnosCfg.DisabledReason))
	} else {
		logger.Info("飞牛深度集成配置就绪",
			zap.Bool("gateway", fnosCfg.GatewayEnabled),
			zap.String("socket", fnosCfg.SocketPath),
			zap.Bool("trimapi", fnosCfg.TrimAPIEnabled),
			zap.String("prefix", fnosCfg.GatewayPrefix))
	}

	// 3. 装配飞牛集成(网关 socket 反代 + /api/fnos/* 路由组)。
	//    不影响 PigeonBox 原有路由;返回网关停机函数(非 fnOS 环境为 nil)。
	stopGateway := adapter.Mount(h, fnosCfg)
	defer func() {
		if stopGateway != nil {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if err := stopGateway(shutdownCtx); err != nil {
				logger.Warn("网关 socket 清理失败", zap.Error(err))
			}
		}
	}()

	// 4. 启动 HTTP 服务。
	go func() {
		logger.Info("PigeonBox 飞牛应用启动中...",
			zap.String("version", version.Version),
			zap.String("commit", version.BuildCommit))
		h.Spin()
	}()

	// 5. 优雅退出:给在途请求 5s 排空窗口,超时强退(避免卡死应用停止流程,
	//    守护方超时后 SIGKILL,留足余量)。
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("正在关闭服务...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.Shutdown(shutdownCtx); err != nil {
		logger.Warn("优雅关闭超时,存在未完成的在途请求", zap.Error(err))
	}
	logger.Info("服务已停止")
}
