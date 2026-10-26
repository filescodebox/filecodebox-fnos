.PHONY: build test vet run fpack clean

# PigeonBox 飞牛(fnOS)应用适配层
# 独立构建钉 go.mod 正式版本;在本仓目录直接跑会拾取上层 go.work 联编本地 core,
# 两者皆可——见 README「本地开发」。

build:            ## 编译 fnos-adapter 二进制
	go build -o bin/fnos-adapter ./cmd/fnos-adapter

test:             ## 单元测试
	go test ./...

vet:
	go vet ./...

run:              ## 降级模式运行(无飞牛凭证,业务全功能)
	go run ./cmd/fnos-adapter

fpack:            ## 飞牛应用包(需 fnpack 二进制, developer.fnnas.com/docs/cli/fnpack/)
	# ⚠️ 2026-10-26 审计 P2:此前 fpack **不重建任何产物**(只 cd fnos && fnpack build)
	# ⇒ 工作区里 fnos/app/bin/ 躺着的陈旧二进制(gitignored 但真实存在)会被打进
	# 一个「能装」的 fpk ⇒ 用户装到 NAS 上的是旧版本(版本幽灵)。
	# ⇒ fpack 必须先重建,再打包,最后验版本戳。
	VERSION="$$(cat VERSION)" ./scripts/build-native.sh
	cd fnos && fnpack build
	./scripts/check-fpack-version.sh
	@echo "✓ 产物 fnos/pigeonbox.fpk"

clean:
	rm -rf bin/ fnos/*.fpk
