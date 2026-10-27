//go:build !linux

// 非 Linux 平台无 SO_PEERCRED ⇒ 取不到对端凭据。
//
// 调用方(gateway.trustedPeer)把 known=false 一律按"不可信"处理:宁可让身份断言
// 显式失败,也不在无法验证来源时采信。fnOS 部署恒为 Linux(本文件仅影响开发机
// 与跨平台构建)。

package gateway

import "net"

// peerUID 非 Linux 平台返回"未知对端"。
func peerUID(net.Conn) (uint32, bool) { return 0, false }
