//go:build linux

// 对端凭据(SO_PEERCRED)采集:unix socket 的连接方身份。
//
// 为什么需要(2026-10-28 真机实证):fnOS 上 app.sock 权限为 755 pigeonbox:pigeonbox,
// 非属主的本地用户(zhangyi, uid 1000, 无 DAC_OVERRIDE)**仍能 connect**
// ⇒ socket 文件权限不是可靠边界 ⇒ 不能只凭"能连上 socket"就采信其携带的
// 身份断言头,必须核对对端 uid。

package gateway

import (
	"net"
	"syscall"
)

// peerUID 取连接对端的 uid;取不到时 known=false(调用方按"不可信"处理)。
func peerUID(c net.Conn) (uint32, bool) {
	sc, ok := c.(syscall.Conn)
	if !ok {
		return 0, false
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return 0, false
	}
	var (
		uid  uint32
		fail error
	)
	if err := raw.Control(func(fd uintptr) {
		cred, e := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		if e != nil {
			fail = e
			return
		}
		uid = cred.Uid
	}); err != nil {
		return 0, false
	}
	if fail != nil {
		return 0, false
	}
	return uid, true
}
