package sso

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/ut"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	coredb "github.com/pigeonbox/core/repo/db"
	"github.com/pigeonbox/core/repo/db/model"

	"github.com/pigeonbox/fnos/adapter/gateway"
)

// newTestDB 注入内存 sqlite(与 core 测试同语义)并迁移 users 表。
func newTestDB(t *testing.T) {
	t.Helper()
	gormDB, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	require.NoError(t, err)
	require.NoError(t, gormDB.AutoMigrate(&model.User{}))
	coredb.SetDatabaseInstance(gormDB)
	t.Cleanup(func() { coredb.SetDatabaseInstance(nil) })
}

// newTestGateway 起一个真实网关 socket(不 Serve,只取 nonce 供 handler 校验)。
func newTestGateway(t *testing.T) *gateway.Server {
	t.Helper()
	// macOS sun_path 104 字节上限:用 /tmp 短路径。
	sock := filepath.Join("/tmp", fmt.Sprintf("pb-sso-test-%d.sock", time.Now().UnixNano()))
	gw, err := gateway.Listen(sock, "/app/pigeonbox", "0", nil)
	require.NoError(t, err)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = gw.Shutdown(ctx)
	})
	return gw
}

// newEngine 挂载 SSO 子路由(与 adapter.Mount 同分组方式)。
func newEngine(t *testing.T, gw *gateway.Server) *server.Hertz {
	t.Helper()
	h := server.Default()
	Mount(h.Group("/api/fnos"), gw)
	return h
}

// postLogin 以指定网关头打 SSO 端点。
func postLogin(h *server.Hertz, gw *gateway.Server, uid, username, isAdmin string) *ut.ResponseRecorder {
	headers := []ut.Header{{Key: gateway.NonceHeader, Value: gw.Nonce()}}
	if uid != "" || username != "" || isAdmin != "" {
		headers = append(headers,
			ut.Header{Key: "X-Trim-Userid", Value: uid},
			ut.Header{Key: "X-Trim-Username", Value: username},
			ut.Header{Key: "X-Trim-Isadmin", Value: isAdmin})
	}
	return ut.PerformRequest(h.Engine, consts.MethodPost, "/api/fnos/login", nil, headers...)
}

type loginBody struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    *struct {
		Token string `json:"token"`
		User  *struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Nickname string `json:"nickname"`
		} `json:"user"`
	} `json:"data"`
}

// 首次 SSO:自动建号(role=user),签发 JWT + 会话 Cookie。
func TestSSO_FirstLogin_CreatesMappedUser(t *testing.T) {
	newTestDB(t)
	gw := newTestGateway(t)
	h := newEngine(t, gw)

	w := postLogin(h, gw, "1000", "alice", "false")
	require.Equal(t, consts.StatusOK, w.Result().StatusCode())

	var body loginBody
	require.NoError(t, json.Unmarshal(w.Result().Body(), &body))
	require.Equal(t, 200, body.Code)
	require.NotNil(t, body.Data)
	assert.Equal(t, "fnos-alice", body.Data.User.Username, "应按 fnos-<username> 建号")
	assert.NotEmpty(t, body.Data.Token)
	// 会话 Cookie:从原始响应头解析(hertz Header.Cookie 签名取 *protocol.Cookie,不便直用)
	assert.Contains(t, string(w.Result().Header.Peek("Set-Cookie")), "pb_token=")

	// 二次登录:同 uid 直接映射(不重复建号)。
	w2 := postLogin(h, gw, "1000", "alice", "false")
	var body2 loginBody
	require.NoError(t, json.Unmarshal(w2.Result().Body(), &body2))
	require.Equal(t, 200, body2.Code)
	assert.Equal(t, body.Data.User.ID, body2.Data.User.ID, "同 uid 应命中既有映射")
}

// 用户名冲突去重:本地已有 fnos-alice 时,第二个飞牛 alice 落 fnos-alice-1。
func TestSSO_UsernameDedup(t *testing.T) {
	newTestDB(t)
	gw := newTestGateway(t)
	h := newEngine(t, gw)

	// 预置占用者(无 oidc_sub 绑定)
	require.NoError(t, coredb.GetDB().Create(&model.User{
		Username: "fnos-alice", Email: "x@x.local", Role: "user", Status: "active",
	}).Error)

	w := postLogin(h, gw, "2000", "alice", "false")
	require.Equal(t, consts.StatusOK, w.Result().StatusCode())
	var body loginBody
	require.NoError(t, json.Unmarshal(w.Result().Body(), &body))
	require.Equal(t, 200, body.Code)
	assert.Equal(t, "fnos-alice-1", body.Data.User.Username)
}

// 同用户名不同 uid:各自独立账号(sub 精确匹配,互不串号)。
func TestSSO_SameNameDifferentUID(t *testing.T) {
	newTestDB(t)
	gw := newTestGateway(t)
	h := newEngine(t, gw)

	w1 := postLogin(h, gw, "1000", "bob", "false")
	w2 := postLogin(h, gw, "2000", "bob", "false")
	var b1, b2 loginBody
	require.NoError(t, json.Unmarshal(w1.Result().Body(), &b1))
	require.NoError(t, json.Unmarshal(w2.Result().Body(), &b2))
	assert.NotEqual(t, b1.Data.User.ID, b2.Data.User.ID, "不同 uid 不得共享账号")
}

// 非法 nonce(直连端口伪造)必须 403;缺用户头 401。
func TestSSO_RejectsForgedRequests(t *testing.T) {
	newTestDB(t)
	gw := newTestGateway(t)
	h := newEngine(t, gw)

	// 伪造 nonce
	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/fnos/login", nil,
		ut.Header{Key: gateway.NonceHeader, Value: "forged"},
		ut.Header{Key: "X-Trim-Userid", Value: "1000"})
	assert.Equal(t, consts.StatusForbidden, w.Result().StatusCode())

	// 网关就绪但无用户头
	w2 := postLogin(h, gw, "", "", "")
	assert.Equal(t, consts.StatusUnauthorized, w2.Result().StatusCode())
}

// 身份消毒:特殊字符用户名折叠为安全字符。
func TestSSO_IdentitySanitized(t *testing.T) {
	newTestDB(t)
	gw := newTestGateway(t)
	h := newEngine(t, gw)

	w := postLogin(h, gw, "3000", "wei de 'hui", "false")
	require.Equal(t, consts.StatusOK, w.Result().StatusCode())
	var body loginBody
	require.NoError(t, json.Unmarshal(w.Result().Body(), &body))
	assert.Equal(t, "fnos-wei_de__hui", body.Data.User.Username)
}

// 未注入 DB:findOrCreate 应回错误而非 panic。
func TestSSO_ErrorOnDBFailure(t *testing.T) {
	gw := newTestGateway(t)
	h := newEngine(t, gw)
	w := postLogin(h, gw, "1000", "alice", "false")
	assert.Equal(t, consts.StatusInternalServerError, w.Result().StatusCode())
}
