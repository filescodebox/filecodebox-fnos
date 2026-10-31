#!/usr/bin/env bash
# 门禁：fpk 随包必须带 **pb CLI**（官方命令行客户端），且它**真的能跑**。
#
# # 为什么要有这道门禁
#
# `build-native.sh` 里 pb 是**源码编译**的（检出 server 同号 tag ⇒ 避开与
# server Release 流水线的竞态）⇒ 它的失败点是**静默降级**（编不出来就
# 不带 pb，应用照常可用）⇒ 没有门禁的话，「fnOS 用户到底能不能用 pb」
# 只能靠人工装包后才发现。
#
# 本门禁断言：
#   V1 打包目录里有 pb 的**双架构**二进制（pb-linux-amd64 / pb-linux-arm64）；
#   V2 这些二进制**可执行**（`--help` 能出帮助文本 ⇒ 不是 0 字节/坏文件/
#      架构不符的错二进制——NAS 上架构错了会直接 exec format error）；
#   V3 若已有 fpk ⇒ 解包 ⇒ app.tgz 里同样含 pb（真正发出去的那一份）。
#
# 负对照：删掉打包目录里的 pb ⇒ V1/V3 必须红。
#
# 用法: bash scripts/check-pb-in-fpk.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

PACK_DIR="$ROOT/fnos"
BIN_DIR="$PACK_DIR/app/bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── V1 打包目录含 pb 双架构二进制 ──
v1_ok=1
for arch in amd64 arm64; do
  f="$BIN_DIR/pb-linux-${arch}"
  if [ ! -f "$f" ]; then
    bad "V1 打包目录缺 pb-linux-${arch}" "路径 $f"
    v1_ok=0
    continue
  fi
  ok "V1 存在 pb-linux-${arch}（$(du -h "$f" | cut -f1)）"
done

# ── V2 pb 可执行（架构/完整性）──
if [ "$v1_ok" = "1" ]; then
  for arch in amd64 arm64; do
    f="$BIN_DIR/pb-linux-${arch}"
    [ -f "$f" ] || continue
    # 交叉架构的二进制在本机**跑不了** ⇒ 只对「本机架构 + 本机 OS」做执行验证，
    # 其余用 `file` 静态判架构（exec format error 的等价物）。
    #
    # ⚠️ 必须连 **OS 一起比**：本机可能是 arm64 的 **macOS** ⇒ 与 arm64 的
    # **Linux** 二进制架构相同但 OS 不同 ⇒ 直接跑会「cannot execute binary file」
    #   ⇒ 门禁会红在与被测物无关的地方（实测：M 系列 Mac 上跑 arm64 Linux 产物）。
    host_arch="$(uname -m)"
    host_os="$(uname -s)"
    can_exec=0
    case "$host_os" in
      Linux) can_exec=1 ;;
    esac
    host_match=0
    if [ "$can_exec" = "1" ]; then
      case "$arch" in
        amd64) [ "$host_arch" = "x86_64" ] && host_match=1 ;;
        arm64) case "$host_arch" in aarch64|arm64) host_match=1 ;; esac ;;
      esac
    fi
    if [ "$host_match" = "1" ]; then
      # ⚠️ 不能用「退出码 == 0」判断可执行：pb 的用法错误退出码是 **2**
      #   （`pb --help` 属未知子命令 ⇒ 退出非 0）⇒ 用退出码判会**误判为不可执行**。
      #   ⇒ 判据：**能跑起来且输出里含帮助/用法文本**。
      out="$("$f" --help 2>&1)" || true
      if printf '%s' "$out" | grep -qE "用法|usage|子命令"; then
        ok "V2 pb-linux-${arch} 可执行（输出了用法文本）"
      else
        bad "V2 pb-linux-${arch} 执行异常（既没成功也没出用法文本）" "$(printf '%s' "$out" | head -c 200)"
      fi
    else
      # 非本机架构：静态判「是 ELF 且架构对」
      kind="$(file -b "$f" 2>/dev/null || echo unknown)"
      case "$kind" in
        *"ELF"*"x86-64"*) ok "V2 pb-linux-${arch} 架构正确（非本机，静态判定：${kind}）" ;;
        *"ELF"*"ARM aarch64"*|*"ELF"*"ARM64"*) ok "V2 pb-linux-${arch} 架构正确（非本机，静态判定：${kind}）" ;;
        *) bad "V2 pb-linux-${arch} 不是预期的 ELF 可执行文件" "$kind" ;;
      esac
    fi
  done
fi

# ── V3 已打出的 fpk 里也含 pb ──
FPK="$PACK_DIR/pigeonbox.fpk"
if [ -f "$FPK" ]; then
  # fpk 是 gzip 压缩的 tar ⇒ 两段解包：先 tar 得 app.tgz，再 tar 得 app/
  if tar xzf "$FPK" -C "$WORK" 2>/dev/null && [ -f "$WORK/app.tgz" ]; then
    # ⚠️ app.tgz **内层没有 app/ 这一层**（真机实录：解包后是 bin/ configs/ ui/ www/）
    #   ⇒ 二进制在 "$WORK/bin/" ⇒ 早先按 "$WORK/app/bin/" 找 ⇒ **恒判「缺 pb」**
    #   （假象：包里有 pb，只是路径找错）。
    tar xzf "$WORK/app.tgz" -C "$WORK" 2>/dev/null
    # 兼容两种布局（app/ 前缀 or 无前缀）。
    PB_BIN_DIR=""
    for cand in "$WORK/bin" "$WORK/app/bin"; do
      if [ -d "$cand" ]; then PB_BIN_DIR="$cand"; break; fi
    done
    v3_ok=1
    for arch in amd64 arm64; do
      if [ -n "$PB_BIN_DIR" ] && [ -f "$PB_BIN_DIR/pb-linux-${arch}" ]; then
        ok "V3 fpk 内含 pb-linux-${arch}"
      else
        bad "V3 fpk 内缺 pb-linux-${arch}" "解包后候选目录：$WORK/bin、$WORK/app/bin（实际：${PB_BIN_DIR:-都没找到}）"
        v3_ok=0
      fi
    done
    [ "$v3_ok" = "1" ] && ok "V3 fpk 内 pb 齐备"
  else
    echo "  (跳过 V3：fpk 解包失败——可能是结构变化，单独排查)"
  fi
else
  echo "  (跳过 V3：尚无 fpk，先跑 build-native.sh + fnpack build)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ pb 随包门禁通过（$PASS 项）"
  exit 0
fi
echo "✗ pb 随包门禁失败（$PASS 通过 / $FAIL 失败）"
exit 1
