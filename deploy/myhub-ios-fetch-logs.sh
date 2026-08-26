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
    local udid="${1:-}" identifier tmp

    # devicectl 使用 coredevice identifier（UUID 格式）；也可接受设备名/UDID/hostname。
    if [[ -n "$udid" ]]; then
        identifier="$udid"
        log "使用指定设备标识: $identifier"
    else
        identifier="$(xcrun devicectl list devices 2>/dev/null \
            | grep -E '\bconnected\b' \
            | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
            | head -n1 || true)"
        [[ -n "$identifier" ]] || { log "错误: 未检测到已连接的真机" >&2; return 1; }
    fi

    tmp="$(mktemp -d)"
    log "从真机复制 Documents/Logs ..."
    # 新版 devicectl（Xcode 15+）已移除 `app download-container`，改用 `device copy from`。
    # appDataContainer domain 的根即应用容器根，source 用相对路径 Documents/Logs。
    if ! xcrun devicectl device copy from \
        --device "$identifier" \
        --source "Documents/Logs" \
        --destination "$tmp" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID"; then
        log "拉取失败：设备容器中可能无 Documents/Logs（应用尚未产生日志）" >&2
        rm -rf "$tmp"
        return 1
    fi

    [[ -n "$(ls -A "$tmp" 2>/dev/null)" ]] || {
        log "设备容器中无日志文件" >&2
        rm -rf "$tmp"
        return 1
    }

    rm -rf "$OUT_DIR"/*
    cp -R "$tmp"/. "$OUT_DIR"/
    rm -rf "$tmp"
    log "已从真机拉取 -> $OUT_DIR"
}

case "${1:-device}" in
    simulator) fetch_simulator ;;
    device)    fetch_device "${2:-}" ;;
    *)         fetch_device ;;
esac

log "完成：$(ls -1 "$OUT_DIR" 2>/dev/null | wc -l | tr -d ' ') 个文件"
