#!/usr/bin/env bash
# =============================================================
# 编译并安装 myhub 客户端到 iOS 真机（Release 模式）
# 用法: ./install-ios.sh [设备ID]
#       默认设备: 00008140-000C099E2E46801C
# =============================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 项目根目录 = deploy 的上一级
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
FLUTTER_DIR="$ROOT_DIR/myhub_flutter"
DEVICE_ID="${1:-00008140-000C099E2E46801C}"

cd "$FLUTTER_DIR"
echo "[install-ios] 目标设备: ${DEVICE_ID}"
echo "[install-ios] 构建并安装 Release 版..."

flutter run -d "$DEVICE_ID" --release
