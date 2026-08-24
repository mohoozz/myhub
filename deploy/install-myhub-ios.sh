#!/usr/bin/env bash
# =============================================================
# 编译并安装 myhub-ios（原生 iOS 客户端）到真机（Debug 模式）
# 注意：与 deploy/install-ios.sh（针对 Flutter 的 myhub_flutter）区分
#
# 用法:
#   ./install-myhub-ios.sh            # 自动检测唯一连接的真机
#   ./install-myhub-ios.sh <UDID>     # 指定真机 UDID（xctrace 格式）
#
# 环境变量:
#   TEAM_ID   签名团队 ID（默认 ZA6Y3Y97C2，即「火木」个人团队）
# =============================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
IOS_DIR="$ROOT_DIR/myhub-ios"

SCHEME="MyHub"
PROJECT="$IOS_DIR/MyHub.xcodeproj"
DERIVED_DATA="$IOS_DIR/build-device"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/MyHub.app"

TEAM_ID="${TEAM_ID:-ZA6Y3Y97C2}"

log() { echo "[install-myhub-ios] $*"; }

command -v xcodegen > /dev/null || { log "缺少 xcodegen，请先执行: brew install xcodegen" >&2; exit 1; }

# ---------- 1. 解析目标真机 ----------
if [[ $# -ge 1 ]]; then
    DEVICE_UDID="$1"
    log "使用指定 UDID: ${DEVICE_UDID}"
else
    DEVICE_UDID="$(xcrun xctrace list devices 2>/dev/null \
        | sed -n '/^== Devices ==$/,/^== /p' \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' \
        | head -n1 || true)"
fi

if [[ -z "${DEVICE_UDID:-}" ]]; then
    log "错误: 未检测到已连接的真机，请用 USB 连接并在手机上信任此电脑" >&2
    exit 1
fi

# devicectl 使用 coredevice identifier（UUID 格式）
DEVICE_IDENTIFIER="$(xcrun devicectl list devices 2>/dev/null \
    | grep -E '\bconnected\b' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    | head -n1 || true)"

if [[ -z "${DEVICE_IDENTIFIER:-}" ]]; then
    log "错误: 未获取到 devicectl 设备标识" >&2
    exit 1
fi

log "目标真机 UDID=${DEVICE_UDID} / identifier=${DEVICE_IDENTIFIER}"

# ---------- 2. 生成工程 ----------
cd "$IOS_DIR"
log "生成工程 (xcodegen)..."
xcodegen generate > /dev/null

# ---------- 3. 编译（Debug + 自动签名） ----------
log "编译到真机（Team ${TEAM_ID}），首次需下载依赖，请稍候..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS,id=${DEVICE_UDID}" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    -quiet \
    build

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")"

# ---------- 4. 安装并启动 ----------
log "安装 ${APP_PATH} ..."
xcrun devicectl device install app --device "$DEVICE_IDENTIFIER" "$APP_PATH"

log "启动应用 (${BUNDLE_ID})..."
xcrun devicectl device process launch --device "$DEVICE_IDENTIFIER" "$BUNDLE_ID" > /dev/null

log "完成"
