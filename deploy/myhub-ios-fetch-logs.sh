#!/usr/bin/env bash
# =============================================================
# 拉取 myhub-ios 运行日志（含崩溃日志）到工作区 myhub-ios/logs/ 供 AI 分析。
#
# 用法:
#   ./myhub-ios-fetch-logs.sh               # 默认拉真机日志（同 install-myhub-ios.sh 的真机）
#   ./myhub-ios-fetch-logs.sh device [UDID] # 真机（可选 UDID，默认同 install-myhub-ios.sh）
#   ./myhub-ios-fetch-logs.sh simulator     # 仅模拟器（booted）
# =============================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)/myhub-ios/logs"
BUNDLE_ID="com.mohoo.myhubios"
mkdir -p "$OUT_DIR"

log() { echo "[myhub-ios-fetch-logs] $*"; }

fetch_simulator() {
    local container src
    container="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null || true)"
    [[ -n "$container" ]] || { log "未找到模拟器沙盒（是否已安装并运行？）" >&2; return 1; }
    src="$container/Documents/Logs"
    [[ -d "$src" ]] || { log "沙盒中无 Documents/Logs（应用尚未产生日志）" >&2; return 1; }
    rm -rf "$OUT_DIR"/*
    cp -R "$src"/. "$OUT_DIR"/
    log "已从模拟器拉取 -> $OUT_DIR"
}

fetch_device() {
    local udid="${1:-}" identifier tmp src

    # ---------- 设备解析（与 install-myhub-ios.sh 保持一致） ----------
    if [[ -n "$udid" ]]; then
        log "使用指定 UDID: $udid"
    else
        udid="$(xcrun xctrace list devices 2>/dev/null \
            | sed -n '/^== Devices ==$/,/^== /p' \
            | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' \
            | head -n1 || true)"
        [[ -n "$udid" ]] || { log "错误: 未检测到已连接的真机" >&2; return 1; }
    fi

    # devicectl 使用 coredevice identifier（UUID 格式），同 install 脚本的 DEVICE_IDENTIFIER
    identifier="$(xcrun devicectl list devices 2>/dev/null \
        | grep -E '\bconnected\b' \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -n1 || true)"
    [[ -n "$identifier" ]] || { log "错误: 未获取到 devicectl 设备标识" >&2; return 1; }

    tmp="$(mktemp -d)"
    log "从真机下载应用容器（较慢，含缓存）..."
    # 参数名（--udid / --device）随 Xcode 版本可能不同，以 `xcrun devicectl app download-container --help` 为准
    xcrun devicectl app download-container \
        --udid "$identifier" \
        --bundle-id "$BUNDLE_ID" \
        --output "$tmp/c.zip"
    unzip -oq "$tmp/c.zip" -d "$tmp/c" || true
    src="$(find "$tmp/c" -type d -path '*/Documents/Logs' | head -n1 || true)"
    [[ -n "$src" ]] || { log "容器中无 Documents/Logs（应用尚未产生日志）" >&2; rm -rf "$tmp"; return 1; }
    rm -rf "$OUT_DIR"/*
    cp -R "$src"/. "$OUT_DIR"/
    rm -rf "$tmp"
    log "已从真机拉取 -> $OUT_DIR"
}

case "${1:-device}" in
    simulator) fetch_simulator ;;
    device)    fetch_device "${2:-}" ;;
    *)         fetch_device ;;
esac

log "完成：$(ls -1 "$OUT_DIR" 2>/dev/null | wc -l | tr -d ' ') 个文件"
