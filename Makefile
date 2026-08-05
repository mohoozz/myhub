# myhub 常用命令（Windows 可使用 Git Bash / WSL 执行，或直接参考命令内容）

.PHONY: help dev dev-server dev-flutter build build-server build-flutter-windows run docker-up docker-down tidy test

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------- 开发 ----------

dev: ## 同时启动后端与 Flutter（Windows 桌面端）
	$(MAKE) -j2 dev-server dev-flutter

dev-server: ## 启动 Go 后端（热重载需自行安装 air，否则 go run）
	cd myhub-server && go run ./cmd/server

dev-flutter: ## 启动 Flutter Windows 桌面端（开发模式）
	cd myhub_flutter && flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8080

# ---------- 构建 ----------

build: build-server build-flutter-windows ## 构建全部

build-server: ## 编译 Go 后端二进制到 myhub-server/bin/
	cd myhub-server && go build -o bin/myhub-server.exe ./cmd/server

build-flutter-windows: ## 构建 Flutter Windows Release
	cd myhub_flutter && flutter build windows --release

run: build-server ## 运行编译后的后端
	./myhub-server/bin/myhub-server.exe

# ---------- 依赖与质量 ----------

tidy: ## 整理两端依赖
	cd myhub-server && go mod tidy
	cd myhub_flutter && flutter pub get

fmt: ## 格式化两端代码
	cd myhub-server && go fmt ./...
	cd myhub_flutter && dart format lib

lint: ## 静态检查
	cd myhub-server && go vet ./...
	cd myhub_flutter && flutter analyze

test: ## 运行测试
	cd myhub-server && go test ./...
	cd myhub_flutter && flutter test

# ---------- Docker ----------

docker-up: ## 启动 Docker Compose 全部服务
	docker compose up -d --build

docker-down: ## 停止 Docker Compose
	docker compose down

docker-logs: ## 查看服务日志
	docker compose logs -f
