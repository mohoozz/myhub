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
echo "[install-ios] 构建 Release 版..."
flutter build ios --release > /dev/null

# 定位构建产物 .app
APP_BUNDLE="$(ls -d "$FLUTTER_DIR/build/ios/iphoneos"/*.app 2>/dev/null | head -n1)"
if [[ -z "$APP_BUNDLE" ]]; then
    echo "[install-ios] 错误: 未找到构建产物 .app" >&2
    exit 1
fi

echo "[install-ios] 安装 ${APP_BUNDLE} 到 ${DEVICE_ID} ..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_BUNDLE"
echo "[install-ios] 安装完成，正在启动应用..."
xcrun devicectl device process launch --device "$DEVICE_ID" "$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Info.plist")" > /dev/null
echo "[install-ios] 完成"
