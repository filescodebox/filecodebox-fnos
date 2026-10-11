// Package sso 实现飞牛 SSO 免登录(2026-10-09 真实现,替代凭证桩)。
//
// 官方模型(developer.fnnas.com/docs/core-concepts/gateway-registration):
// 统一网关在转发请求前完成 NAS 登录态校验,并以可信头注入当前用户——
//   X-Trim-Userid / X-Trim-Isadmin / X-Trim-Username
// 故无需任何"ticket 换取"式 API 调用:请求到达即身份已立。
//
// 身份映射(镜像 core OIDC 域范式,见 app/oidc/service.go):
//   1. 按 fnos:<uid> 精确匹配(复用 users.oidc_sub 外部身份键,值域加前缀隔离)
//   2. 未命中 → 以 "fnos-<username>" 去重建号(role=user,随机不可登录——
//      登录唯一入口是网关,与 OIDC 随机密码同语义)
//   3. 签发本系统 JWT + HttpOnly 会话 Cookie,前端零改动进入登录态
//
// 安全:本端点仅接受经 gateway.Server 反代转发的请求(启动期随机 nonce 比对),
// 直连业务端口的伪造头一概 403;飞牛管理员(X-Trim-Isadmin)不映射为
// PigeonBox 管理员——两套权限语义不同,提权一律走密码登录。
package sso

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"strings"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/cloudwego/hertz/pkg/route"
	"go.uber.org/zap"
	"gorm.io/gorm"

	usermodel "github.com/pigeonbox/contracts/gen/user"
	"github.com/pigeonbox/core/pkg/auth"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/core/pkg/middleware"
	"github.com/pigeonbox/core/repo/db"
	"github.com/pigeonbox/core/repo/db/dao"
	"github.com/pigeonbox/core/repo/db/model"

	"github.com/pigeonbox/fnos/adapter/gateway"
)

// zapIdentity 日志字段:飞牛身份三元组。
func zapIdentity(id Identity) zap.Field {
	return zap.String("fnos_user", id.Username+"#"+id.UID)
}

// Mount 在飞牛路由组上挂载 SSO 子路由。gw=nil(网关未启用)时端点降级 503。
func Mount(g *route.RouterGroup, gw *gateway.Server) {
	g.POST("/login", func(ctx context.Context, c *app.RequestContext) {
		if gw == nil {
			c.JSON(consts.StatusServiceUnavailable, map[string]any{
				"code":    503,
				"message": "飞牛统一网关未启用(需 fnOS 原生应用环境),请使用账号密码登录",
			})
			return
		}
		// 网关来源凭证:nonce 只可能由 gateway.Server 注入(入站同名头已被剥离)。
		// 恒时比较(项目安全基线,对齐 p2p 侧通道硬化模式),抹长度/内容侧信道。
		got := c.GetHeader(gateway.NonceHeader)
		want := gw.Nonce()
		if subtle.ConstantTimeCompare(got, []byte(want)) != 1 {
			logger.Warn("SSO 拒绝非网关来源请求(疑似伪造头)")
			c.JSON(consts.StatusForbidden, map[string]any{
				"code":    403,
				"message": "SSO 仅允许经飞牛统一网关访问",
			})
			return
		}

		identity := identityFromHeaders(c)
		if identity.UID == "" {
			c.JSON(consts.StatusUnauthorized, map[string]any{
				"code":    401,
				"message": "网关未携带用户身份,请重新从飞牛桌面进入应用",
			})
			return
		}

		user, created, err := findOrCreate(ctx, identity)
		if err != nil {
			logger.Error("SSO 用户映射失败", zapIdentity(identity), zap.Error(err))
			c.JSON(consts.StatusInternalServerError, map[string]any{
				"code":    500,
				"message": "飞牛账号映射失败:" + err.Error(),
			})
			return
		}
		if user.Status != "active" {
			c.JSON(consts.StatusForbidden, map[string]any{
				"code":    403,
				"message": "账号已被禁用",
			})
			return
		}

		token, err := auth.GenerateToken(user.ID, user.Username, user.Role)
		if err != nil {
			logger.Error("SSO 签发会话失败", zapIdentity(identity), zap.Error(err))
			c.JSON(consts.StatusInternalServerError, map[string]any{
				"code":    500,
				"message": "签发会话失败",
			})
			return
		}
		// 与 /user/login 同形态:HttpOnly 会话 Cookie + 响应体 token(兼容 Bearer)。
		middleware.SetSessionCookie(c, token, int(auth.SessionExpiry().Seconds()))
		logger.Info("飞牛 SSO 登录成功",
			zapIdentity(identity),
			zap.Uint("local_uid", user.ID),
			zap.String("local_username", user.Username),
			zap.Bool("created", created))

		c.JSON(consts.StatusOK, &usermodel.LoginResp{
			Code:    200,
			Message: "登录成功",
			Data: &usermodel.LoginData{
				Token: token,
				User: &usermodel.UserData{
					ID:        int64(user.ID),
					Username:  user.Username,
					Email:     user.Email,
					Nickname:  user.Nickname,
					Avatar:    user.Avatar,
					Status:    1,
					CreatedAt: user.CreatedAt.Format("2006-01-02 15:04:05"),
				},
			},
		})
	})
}

// Identity 网关注入的飞牛用户身份。
type Identity struct {
	UID      string
	Username string
	IsAdmin  bool
}

// identityFromHeaders 提取并消毒网关用户头。
func identityFromHeaders(c *app.RequestContext) Identity {
	username := strings.TrimSpace(string(c.GetHeader("X-Trim-Username")))
	// 用户名只保留安全字符(建号落库用),其余折叠为下划线。
	username = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return '_'
		}
	}, username)
	return Identity{
		UID:      strings.TrimSpace(string(c.GetHeader("X-Trim-Userid"))),
		Username: username,
		IsAdmin:  strings.EqualFold(string(c.GetHeader("X-Trim-Isadmin")), "true"),
	}
}

// externalSub 外部身份键:复用 users.oidc_sub(外部身份 subject 语义),
// "fnos:" 前缀与真实 OIDC sub 值域隔离,互不冲突。
func externalSub(id Identity) string { return "fnos:" + id.UID }

// findOrCreate 按外部身份查/建本地用户(范式对齐 core OIDC 域)。
func findOrCreate(ctx context.Context, id Identity) (*model.User, bool, error) {
	repo := dao.NewUserRepository(db.GetDB()) // 库式消费方显式取装配层句柄

	if u, err := repo.GetByOIDCSub(ctx, externalSub(id)); err == nil && u != nil {
		return u, false, nil
	} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, false, fmt.Errorf("查询飞牛身份绑定失败: %w", err)
	}

	// 建号:用户名去重(本地同名时追加序号)。
	base := "fnos-" + id.Username
	if base == "fnos-" {
		base = "fnos-uid-" + id.UID
	}
	username := base
	for i := 1; ; i++ {
		_, err := repo.GetByUsername(ctx, username)
		if errors.Is(err, gorm.ErrRecordNotFound) {
			break
		}
		if err != nil {
			return nil, false, fmt.Errorf("查询用户名占用失败: %w", err)
		}
		username = fmt.Sprintf("%s-%d", base, i)
	}

	// 不落密码(users 表允许空):登录唯一入口是网关,随机密码无意义且徒增
	// 泄露面;与 OIDC 建号差异仅在于 OIDC 落随机密码以兼容其历史字段约束。
	email := fmt.Sprintf("fnos-%s@fnos.local", id.UID)
	user := &model.User{
		Username: username,
		Email:    email,
		Nickname: id.Username,
		Role:     "user",
		Status:   "active",
		OidcSub:  externalSub(id),
	}
	if err := repo.Create(ctx, user); err != nil {
		return nil, false, fmt.Errorf("创建飞牛映射用户失败: %w", err)
	}
	return user, true, nil
}
