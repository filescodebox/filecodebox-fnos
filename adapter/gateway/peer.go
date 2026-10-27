package gateway

// 对端 uid 的采集与传递(与平台实现解耦:peerUID 由 peercred_linux.go /
// peercred_other.go 分别实现)。
//
// 数据流:peerListener.Accept → peerConn(携带 uid) → http.Server.ConnContext
// → 请求上下文 → 反代 Director 据此判定是否放行身份断言头。

import (
	"context"
	"net"
)

// peerInfo 连接对端的 uid 信息(known=false 表示未能取到对端凭据)。
type peerInfo struct {
	uid   uint32
	known bool
}

// peerUIDKey 请求上下文键。
type peerUIDKey struct{}

// peerUIDFromContext 取本次请求的对端 uid。
func peerUIDFromContext(ctx context.Context) (uint32, bool) {
	if ctx == nil {
		return 0, false
	}
	info, ok := ctx.Value(peerUIDKey{}).(peerInfo)
	if !ok {
		return 0, false
	}
	return info.uid, info.known
}

// peerConn 携带对端 uid 的连接。
type peerConn struct {
	net.Conn
	uid   uint32
	known bool
}

// peerListener 在 Accept 时采集对端凭据。
type peerListener struct {
	net.Listener
	// peerUIDFn 采集对端 uid 的实现(默认平台实现;测试可替换)。
	peerUIDFn func(net.Conn) (uint32, bool)
}

// Accept 接受连接并记录对端 uid。
func (l *peerListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	fn := l.peerUIDFn
	if fn == nil {
		fn = peerUID
	}
	uid, known := fn(c)
	return &peerConn{Conn: c, uid: uid, known: known}, nil
}
