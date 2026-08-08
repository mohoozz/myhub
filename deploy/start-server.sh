#!/usr/bin/env bash
# =============================================================
# 启动 myhub 服务端
# 用法: ./start-server.sh
# =============================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 项目根目录 = deploy 的上一级
PROJECT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
SERVER_DIR="$PROJECT_ROOT/myhub-server"
BIN="$SERVER_DIR/bin/myhub-server"

# 本机 Go 工具链位置（项目需要 Go 1.26.5）
LOCAL_GO="$HOME/.local/go1.26.5"
LOCAL_GO_BIN="$LOCAL_GO/bin/go"

# 1) 若二进制不存在，尝试编译
if [ ! -f "${BIN}" ]; then
  echo "[start-server] 未找到 ${BIN}，开始编译..."
  if [ ! -f "${LOCAL_GO_BIN}" ]; then
    echo "[start-server] 错误: 找不到 Go 工具链 ${LOCAL_GO_BIN}" >&2
    echo "[start-server] 请先安装 Go 1.26.5 到 ${LOCAL_GO}" >&2
    exit 1
  fi
  cd "$SERVER_DIR"
  GOROOT="$LOCAL_GO" PATH="$LOCAL_GO/bin:$PATH" go build -o "$BIN" ./cmd/server
  echo "[start-server] 编译完成: ${BIN}"
fi

# 2) 检查 8080 是否已被占用
if lsof -iTCP:8080 -sTCP:LISTEN -P >/dev/null 2>&1; then
  echo "[start-server] 端口 8080 已被占用，请先停止现有服务：" >&2
  echo "    lsof -iTCP:8080 -sTCP:LISTEN" >&2
  exit 1
fi

# 3) 启动服务端
cd "$SERVER_DIR"
echo "[start-server] 启动 myhub-server @ http://0.0.0.0:8080"
exec "$BIN"
