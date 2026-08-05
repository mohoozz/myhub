# myhub

个人数字资产统一入口：文件管理、流媒体播放、在线阅读、订阅动态聚合的自托管系统。

- **后端**：Go + Gin + GORM + SQLite（单二进制部署）
- **前端**：Flutter（一套代码覆盖 Android / iOS / Windows / macOS / Linux / Web，当前优先 PC 桌面端）
- 详细需求见 [doc/需求分析文档.md](doc/需求分析文档.md)，任务拆解见 [TODO.md](TODO.md)

## 目录结构

```
myhub/
├── myhub-server/      # Go 后端服务（Gin + GORM + SQLite）
├── myhub_flutter/     # Flutter 客户端（Riverpod + go_router + dio + media_kit）
├── doc/               # 需求与设计文档
├── docker-compose.yml # 一键部署（后端 + Caddy 反代，预留 OpenClaw/OpenList）
├── Caddyfile          # 反向代理 + 自动 HTTPS
├── Makefile           # 常用命令
└── TODO.md            # 里程碑任务清单
```

## 环境要求

| 工具 | 版本 |
| --- | --- |
| Go | 1.26+ |
| Flutter | 3.44+（启用 Windows 桌面支持） |
| FFmpeg | 6+（缩略图 / HLS 转码，可后续安装） |
| Docker | 可选，用于部署 |

## 快速开始

### 1. 启动后端

```powershell
cd myhub-server
go mod tidy
go run ./cmd/server
```

默认监听 `:8080`，健康检查：<http://localhost:8080/api/health>。
配置文件为 `myhub-server/config.yaml`，亦可用 `MYHUB_` 前缀环境变量覆盖。

### 2. 启动前端（Windows 桌面端）

```powershell
cd myhub_flutter
flutter pub get
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8080
```

### 3. Docker 部署

```powershell
docker compose up -d --build
```

编辑 `Caddyfile` 将 `myhub.example.com` 替换为你的域名即可自动签发 HTTPS。

## 常用命令

Windows 无 `make` 时可直接查看 `Makefile` 中的命令手动执行，或使用 Git Bash / WSL。

| 命令 | 说明 |
| --- | --- |
| `make dev` | 同时启动后端 + Flutter 桌面端 |
| `make build` | 构建后端二进制 + Windows Release |
| `make lint` / `make test` | 静态检查 / 测试 |
| `make docker-up` | Docker Compose 一键启动 |

## 里程碑

- [x] **M0**：全栈骨架（Go 脚手架 + Flutter 脚手架 + 基础设施）
- [ ] **M1**：文件管理
- [ ] **M2**：媒体播放
- [ ] **M3**：阅读器
- [ ] **M4**：多端打磨 v1.0
- [ ] **M5**：动态 + 离线 v1.1
