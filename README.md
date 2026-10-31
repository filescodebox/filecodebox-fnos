# fnos

[![CI](https://github.com/pigeonbox/fnos/actions/workflows/ci.yml/badge.svg)](https://github.com/pigeonbox/fnos/actions/workflows/ci.yml)
[![Tag](https://img.shields.io/github/v/tag/pigeonbox/fnos)](https://github.com/pigeonbox/fnos/tags)
[![License](https://img.shields.io/github/license/pigeonbox/fnos)](LICENSE)

> [PigeonBox](https://github.com/pigeonbox/pigeonbox)（文件快递柜）的飞牛 fnOS 应用适配层——单进程库式集成 PigeonBox 全部业务，包装为可在飞牛 NAS 应用中心安装的第三方应用，并接入飞牛 Open API。

> 🗂️ [PigeonBox 生态](https://github.com/orgs/pigeonbox)成员仓 · 应用包统一发布在 [hub 仓 Releases](https://github.com/pigeonbox/pigeonbox/releases)（`fnos-v*` 资产）

## 特性

| 能力 | 说明 | 状态 |
|------|------|------|
| **一键安装** | `fnpack` 标准应用包，应用中心托管启停/升级 | ✅ fnpack 1.2.3 打包通过 |
| **业务全功能** | 单进程库式调用 [core](https://github.com/pigeonbox/core) `bootstrap.Bootstrap()`，文本/文件分享、取件码、多云存储全部可用 | ✅ |
| **数据落 NAS** | 上传文件 + SQLite 全部落在用户可见的共享目录，文件管理器可直接查看/备份 | ✅ |
| **开箱即用** | JWT 密钥自动生成并持久化；默认免 Redis（自 core v0.14.0 起单机内存模式，取件码映射存进程内、重启/升级失效）；安装向导设管理员密码与服务端口 | ✅ |
| **设备直传** | fpk 随包 p2pc 双架构二进制（DEPS.env `P2PC_REF` 钉版+sha256 校验），服务脚本自动注入 `PB_P2PC_PATH`；admin「系统配置→P2P」分区热启停联邦与设备直传；v1.22.0 起支持联邦实例间推送邀请（admin 控制台待收/认领/推送） | ✅ |
| **降级模式** | 非 fnOS 环境（裸进程开发调试）自动降级，飞牛集成关闭、业务完整运行 | ✅ |
| **SSO 免登录** | 统一网关 `app.sock` X-Trim-* 可信用户头免登录，飞牛账号映射为本系统用户 | ✅ v1.14.6 真机验证 |
| **授权目录联动** | 官方后端 API（trim.file.*）授权目录、文件管理器互通 | ✅ v1.14.6 |
| **主题/语言跟随** | 前端跟随 fnOS 主题与系统语言（@trimjs/web-app 微应用） | ✅ v1.14.6 |
| **通知中心/内网穿透** | 官方一期未开放——能力缺席非缺陷 | ⏸ 待官方 |

## 运行时架构（单进程单端口）

```
                ┌──────────────── fnos-adapter 二进制(进程入口)────────────────┐
                │                                                              │
  HTTP 12345 ──►│  bootstrap.Bootstrap() ──► *server.Hertz (PigeonBox 全业务)│
                │         │                              ▲                      │
                │         └── adapter.Mount(h, cfg) ─────┘ 挂载 /api/fnos/*     │
                │                          (SSO/目录/通知/穿透)                 │
                └──────────────────────────────────────────────────────────────┘
                     │                                            │
        /app/data ◄──┘ (上传文件+SQLite+JWT密钥)      取件码映射 ◄── 进程内内存
                     └────────────── ${TRIM_PKGVAR} ──────┘ (NAS 共享目录)
```

- **库式调用**：同进程 `import` + 函数调用 `bootstrap.Bootstrap()`，零跨进程开销
- **不侵入**：不修改 core 原有路由，飞牛能力以独立路由组 `/api/fnos/*` 注入（降级模式统一 503）

## 安装（飞牛 fnOS）

1. 从 hub 仓 [Releases](https://github.com/pigeonbox/pigeonbox/releases) 下载 `fnos-v*` 资产中的 `pigeonbox.fpk`（或自行 [打包](#打包fpk)）
2. 飞牛应用中心 → 手动安装 → 上传 fpk，按向导完成安装（飞牛凭证可留空，随时在应用设置补填）
3. 桌面入口打开即用；数据在应用数据目录（NAS 共享路径）下的 `data/`（上传文件/SQLite/JWT 密钥；取件码映射存进程内存，无独立文件）

> v1.2.7 起 fpk 为原生进程模式：包内自带双架构静态二进制+内嵌前端，安装运行免 Docker 免拉镜像。2026-10-09 起本仓**只发布原生 fpk**，Docker 镜像链路已整体移除。

## 应用内配置（安装后可改）

飞牛应用中心 → 应用设置 → 配置面板，可随时修改（提交后应用自动重启生效）：

| 配置项 | 说明 |
|---|---|
| **重置管理员密码** `PB_ADMIN_PASSWORD` | 留空=不改动；填写并提交=admin 账号密码立即重置为该值（可重复使用）。安装向导里同名字段用于设定初始密码 |
| **服务端口** `PB_SERVER_PORT` | Web UI/API 监听端口，默认 12345；修改后应用以新端口重启 |
| JWT 密钥 `PB_JWT_SECRET` | 留空沿用自动生成的；更换后所有已登录会话失效 |

> **改端口后的桌面入口**：桌面图标指向安装时的端口（框架安装时快照），改端口后请用 `http://NAS_IP:新端口` 访问；改回原端口则入口恢复。

**数据备份与恢复**：升级时自动快照业务库（`data/fileCodeBox.db.bak-<时间戳>`，轮转保留最近 3 份）。手动恢复：应用设置停止应用 → 用备份覆盖 `data/fileCodeBox.db` → 启动应用。进程内置看门狗（每 30s 健康探测，无响应自动重启/崩溃自动拉起），日志见应用数据目录 `app.log`。

## 命令行客户端（pb）

应用包内自带官方命令行客户端 **pb**（与 p2pc 同目录，双架构静态二进制），用于**自检**当前实例：

```bash
# x86_64 机器
/var/apps/pigeonbox/target/bin/pb-linux-amd64 doctor
# arm64 机器把文件名换成 pb-linux-arm64
```

`doctor` 会检查服务版本、部署模式、数据库、存储后端、Redis、站点公网地址、首启状态、
被降级的能力与时钟偏差。

> **深度检查需要 admin 的 API Key**：在管理台「用户中心 → API 令牌」创建后执行
> ```bash
> PB_API_KEY=pb_sk_xxx /var/apps/pigeonbox/target/bin/pb-linux-amd64 doctor
> ```
> 未设置 Key 时仍会做**公开面检查**（服务可达、robots.txt 等），
> 并在报告里**明确标注「深度检查未执行」**（不是「通过」）。

> pb 的版本与包内服务端**同号**（两者都由同一趟发布列车产出）⇒ 不会出现
> 「客户端比服务端新」的错配。

## 打包 .fpk

```bash
# 安装 fnpack: https://developer.fnnas.com/docs/cli/fnpack/
cd fnos && fnpack build     # 产物 pigeonbox.fpk
```

`fnos/` 目录即应用包定义，**已对齐飞牛官方规范**（manifest / app/ui 入口+图标 / cmd 生命周期脚本 / wizard 向导 / config 资源与权限）。CI 每次推送都会跑 `fnpack build` 校验并产出 fpk 构件。

注意：发版版本真相源=仓根 `VERSION` 文件（由 hub 发布列车 v2 统一维护：hub `make train-bump` 触发 `release/trainctl` 状态机写入），`fnos/manifest` 的 `version` 与之同步，勿单手改一处。

## 上架官方应用中心

官方应用中心目前为**邀请制**（粉丝群→社区主理人→「应用中心开发者先锋交流群」人工提交），完整流程、材料清单与提交前检查项见 [docs/store-submission.md](docs/store-submission.md)。上架材料一键成包（每列车发版后重跑即得新版材料）：

```bash
./scripts/assemble-store-package.sh   # fpk+图标+8 张截图+提交说明 → dist/store-submission/*.zip
```

## 本地开发

本仓已纳入 [pigeonbox](https://github.com/pigeonbox/pigeonbox) 装配仓的 `go.work`：

```bash
# 工作区内(hub 根 make setup 拉齐全部模块仓后):联编本地 core main
cd fnos && go build ./... && go test ./...

# 独立构建:钉 go.mod 正式版本(与 CI 一致)
GOWORK=off go test ./...

# 降级模式运行(业务全功能,飞牛能力关闭)
go run ./cmd/fnos-adapter

# 启用飞牛深度集成(无需凭证:由 fnOS 运行环境自动探测 TRIM_* 变量;
# 裸进程等 fnOS 外环境自动降级,业务全功能)
go run ./cmd/fnos-adapter
```

或使用 `make build / test / run / fpack`。

## 目录结构

```
fnos/
├─ cmd/fnos-adapter/            进程入口:JWT 密钥引导 + 库式拉起 + 挂载 adapter
├─ adapter/                     飞牛开放平台适配层(/api/fnos/*)
│  ├─ gateway/                  统一网关接入(stripPrefix 反代+nonce 防直连伪造头)
│  ├─ internal/trimapi/         官方后端 API client(trim.file.*/trim.system.*)
│  ├─ internal/fnosconfig/      配置加载(独立子包,无环)
│  └─ sso/ storage/             SSO 映射(oidc_sub=fnos:<uid>)与授权目录联动
├─ web/                         fnOS 宿主适配器(@trimjs/web-app)+frontend-core tgz 自包含前端(构建→fnos/app/www)
└─ fnos/                        飞牛 .fpk 应用包定义(官方规范,原生进程模式)
   ├─ manifest                  应用元数据(version/platform/入口/端口/micro_app)
   ├─ app/{bin,www,configs}/    双架构静态二进制+内嵌前端+只读配置(build-native.sh 产出)
   ├─ app/ui/                   桌面入口(config)与图标(images/)
   ├─ cmd/                      生命周期脚本(install/upgrade/uninstall/config)
   ├─ wizard/                   安装/配置向导(管理员密码/服务端口/JWT 密钥)
   └─ config/                   权限(privilege)与资源(resource: data-share)
```

> 前端内嵌（v1.2.7 起）：`web/` 自包含构建产物落入 `fnos/app/www`，
> adapter 经 `bootstrap.WithStaticDir` 同端口服务 SPA——桌面图标打开即用。

## 版本对应

| 本仓 | core | 说明 |
|------|------|------|
| v1.22.0 | core v0.20.0 / frontend-core v0.5.0 / p2pc v0.6.3 | 版本随产品主版本（hub 发布列车同号）；fpk 随包 p2pc 双架构二进制，服务脚本自动注入 `PB_P2PC_PATH`，设备直传开箱可用 |
| v1.14.x | v0.14.4 → v0.14.9 | 版本随产品主版本（hub 发布列车同号）；v1.14.3=配置面板（管理员密码/端口）+看门狗自愈+env 前缀 PB_ 更名；**v1.14.6=飞牛官方开放平台深度融合**（统一网关 SSO 免登录/授权目录联动/文件管理器互通/主题语言跟随，真机验证收官） |
| v1.2.7 | v0.14.2 | 修复 fpk 真机安装失败（目录准备改尽力而为 + entrypoint 兜底归属）；镜像内嵌前端（桌面图标打开即用）；core 补文件/分片上传分享链接 0.0.0.0 漏网路径 |
| v1.2.6 | v0.14.1 | 跟随 core v0.14.1（env-only 缺 notifies 表修复；分享链接 0.0.0.0 修复） |
| v1.2.3 | v0.11.0 | 跟随 core v0.11.0（Cookie 会话）；默认关闭开放注册（管理员建号） |
| v1.2.2 | v0.10.0 | 跟随 core v0.10.0 安全审计加固；测试 -race 门禁；版本注入上收 kit/version |
| v1.2.1 | v0.8.0 | core 对齐（P2P 联邦接入；fnos 依赖面仅 bootstrap+logger，行为无变化） |
| v1.2.0 | v0.7.6 | 版本号与 desktop/charts 统一起始版；compose 镜像 tag 对齐 major.minor `:1.2` |
| v0.3.x | v0.7.6 | 仓改名 fnos——镜像路径切换 `ghcr.io/pigeonbox/fnos`，go module path 同步 |
| v0.2.x | v0.5.0 → v0.7.6 | 上传治理/多云存储/P0 修复；fnpack 规范化 + 内置 Redis + 向导；0.2.6 升 core v0.7.6 |

Docker 镜像：2026-10-09 起**停止发布**（本仓只发原生 fpk）；`ghcr.io/pigeonbox/fnos` 冻结在 v1.14.6，更早 `pigeonbox-fnos` 冻结在 v0.2.6 / v0.2.1。

> 完整版本沿革见 hub [release/train.yaml](https://github.com/pigeonbox/pigeonbox/blob/main/release/train.yaml) 与各 [Release](https://github.com/pigeonbox/pigeonbox/releases)，上表仅记关键节点。

## 路线图

- [x] SSO 免登录：统一网关可信头 → 飞牛用户 → 本系统用户 → JWT（v1.14.6 真机验证收官）
- [x] 授权目录联动/文件管理器互通/主题语言跟随（同车）
- [x] fnOS 真机全流程验证（安装→向导→升级→卸载→看门狗自愈）
- [ ] 通知中心、内网穿透（官方一期未开放，待官方）
- [ ] 飞牛官方应用中心上架（邀请制群提交；材料链路就绪:docs/store-submission.md + scripts/assemble-store-package.sh）

## 相关仓库

[pigeonbox](https://github.com/pigeonbox/pigeonbox)（装配仓）· [core](https://github.com/pigeonbox/core)（业务核心）· [server](https://github.com/pigeonbox/server)（独立部署壳）· [frontend](https://github.com/pigeonbox/frontend) · [charts](https://github.com/pigeonbox/charts)（Helm）

## License

[Apache-2.0](LICENSE)
