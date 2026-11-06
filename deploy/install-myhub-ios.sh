#!/usr/bin/env bash
# =============================================================
# 编译并安装 myhub-ios（原生 iOS 客户端）到真机（Debug 模式）
#
# 用法:
#   ./install-myhub-ios.sh                    # 自动检测唯一连接的真机
#   ./install-myhub-ios.sh <UDID>             # 指定真机 UDID（xctrace 格式）
#   ./install-myhub-ios.sh [<UDID>] --renew
#                                             # 立即刷新 7 天有效期（免费账号）：换新描述文件后
#                                             # 覆盖安装，数据保留、无需重新信任开发者
#   ./install-myhub-ios.sh [<UDID>] --reset-trust
#                                             # 令「信任此开发者」失效：备份数据 → 卸载 → 重装
#                                             # → 回写数据，手机需重新授权后才能启动（默认不生效）
#   ./install-myhub-ios.sh -h                 # 查看用法
#
# 环境变量:
#   TEAM_ID   签名团队 ID（默认 ZA6Y3Y97C2，即「火木」个人团队）
#
# 关于 --renew（刷新 7 天有效期，推荐）:
#   免费个人团队的 iOS Development 描述文件只有 7 天有效期，到期后 App 直接无法启动。
#   本参数先删除本机缓存的该 Bundle 描述文件，再用 xcodebuild -allowProvisioningUpdates
#   向 Apple 重新签发一份（新的 7 天窗口从签发时刻起算），然后覆盖安装：
#     · 同证书 + 同 Bundle 覆盖安装 = 升级，App 容器数据（数据库/文件/设置）原样保留
#     · 不触发「信任此开发者」，手机端无需任何操作
#   建议在到期前 1 天固定时间跑一次（例如每周二 21:00），有效期会一直往后顺延，永不到期。
#   需 macOS 联网、Xcode 已登录同一 Apple ID、手机解锁并连接。
#
# 关于 --reset-trust（不清空数据）:
#   iOS 在 App 被卸载后会取消对该开发者的信任，重装即需在手机端重新授权；该状态由设备
#   维护，主机侧没有可直接撤销的 CLI，所以脚本走「备份 → 卸载 → 安装 → 回写」：
#     · 备份 Documents、Library/Application Support（数据库）、Library/Preferences 等
#       到 myhub-ios/.device-backup/<时间戳>/，重装后自动回写
#     · Keychain 凭据不随卸载删除（系统保留），连接源账号密码仍在
#     · 备份失败或必需目录缺失时脚本直接中止，绝不卸载，避免数据丢失
#     · App 未安装（首次安装）时无数据可备份，跳过备份直接安装
#   回写期间请保持手机解锁并连接；启动被拒绝时按提示在手机端重新信任即可。
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

usage() {
    sed -n '5,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'
}

# 手机端重新信任开发者的操作指引（--reset-trust 时使用）
print_trust_hint() {
    cat >&2 <<'EOF'

== 需要重新授权（信任此开发者）==
  1. 打开「设置」>「通用」>「VPN 与设备管理」
  2. 在「开发者 App」下选择你的 Apple ID / Apple Development: xxx
  3. 点击「信任 "Apple Development: xxx"」并确认（若条目已消失，直接从桌面启动 App，
     系统会弹出「未受信任的开发者」提示，再按提示回到上述路径信任）
  4. 回到桌面启动 MyHub
EOF
}

command -v xcodegen > /dev/null || { log "缺少 xcodegen，请先执行: brew install xcodegen" >&2; exit 1; }

# 读取 .app 内嵌描述文件的到期时间（免费个人团队为签发时刻 + 7 天）
profile_expiry() {
    local app="$1" tmp exp
    [[ -f "$app/embedded.mobileprovision" ]] || return 1
    tmp="$(mktemp)"
    if ! security cms -D -i "$app/embedded.mobileprovision" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    exp="$(plutil -extract ExpirationDate raw -o - "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    [[ -n "$exp" ]] || return 1
    printf '%s\n' "$exp"
}

# ---------- 1. 解析参数与目标真机 ----------
DEVICE_UDID=""
RESET_TRUST=0
RENEW=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --renew) RENEW=1 ;;
        --reset-trust) RESET_TRUST=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) log "未知参数: $1（可用: -h / --renew / --reset-trust）" >&2; exit 1 ;;
        *)
            if [[ -n "$DEVICE_UDID" ]]; then
                log "错误: 多余的位置参数: $1" >&2
                exit 1
            fi
            DEVICE_UDID="$1"
            ;;
    esac
    shift
done

if [[ "$RENEW" -eq 1 && "$RESET_TRUST" -eq 1 ]]; then
    log "错误: --renew 与 --reset-trust 互斥（刷新 7 天有效期不需要重置信任）" >&2
    exit 1
fi

if [[ -n "$DEVICE_UDID" ]]; then
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

# ---------- 2.5 --renew：强制换取一份新的描述文件 ----------
BUNDLE_ID_HINT="$(grep -m1 -E '^[[:space:]]+PRODUCT_BUNDLE_IDENTIFIER:' project.yml 2>/dev/null | awk '{print $2}' || true)"
BUNDLE_ID_HINT="${BUNDLE_ID_HINT:-com.mohoo.myhubios}"
PROFILE_DIRS=(
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)

if [[ "$RENEW" -eq 1 ]]; then
    log "（--renew）清理本机缓存的 ${BUNDLE_ID_HINT} 描述文件，向 Apple 换取新的 7 天有效期..."
    REMOVED=0
    for dir in "${PROFILE_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.mobileprovision; do
            [[ -f "$f" ]] || continue
            if security cms -D -i "$f" 2>/dev/null | grep -qF "$BUNDLE_ID_HINT"; then
                rm -f "$f"
                log "  已移除: $(basename "$f")"
                REMOVED=$((REMOVED + 1))
            fi
        done
    done
    log "  共移除 ${REMOVED} 个缓存描述文件，重新签发中..."
fi

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

NEW_EXPIRY=""
if NEW_EXPIRY="$(profile_expiry "$APP_PATH")"; then
    log "本次安装的描述文件到期时间: ${NEW_EXPIRY}"
    if [[ "$RENEW" -eq 1 ]]; then
        log "若该时间没有顺延到 7 天后，说明 Apple 侧没有签发新描述文件：请检查 Xcode 是否已登录同一 Apple ID、网络是否可用"
    fi
else
    NEW_EXPIRY=""
    log "未能读取描述文件到期时间（--renew 时可关注该告警）"
fi

# ---------- 4. 安装并启动 ----------
DATA_BACKUP_DIR="$IOS_DIR/.device-backup/$(date +%Y%m%d-%H%M%S)"
# 需要跨卸载保留的容器内目录（Documents=用户文件，Application Support=数据库，Preferences=设置）
BACKUP_PATHS=("Documents" "Library/Application Support" "Library/Preferences" "Library/Cookies" "Library/WebKit")
# 缺一即中止备份，宁可不动数据
REQUIRED_BACKUP_PATHS=("Documents" "Library/Application Support")

app_installed() {
    xcrun devicectl device info apps --device "$DEVICE_IDENTIFIER" 2>/dev/null \
        | grep -qE "(^|[[:space:]])${BUNDLE_ID}([[:space:]]|$)"
}

# 从设备容器取一个相对路径到本地备份目录（保持原目录结构）
fetch_app_path() {
    local rel="$1" tmp dest
    tmp="$(mktemp -d)"
    if ! xcrun devicectl device copy from \
        --device "$DEVICE_IDENTIFIER" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "$rel" \
        --destination "$tmp" > /dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi
    dest="$DATA_BACKUP_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    # devicectl 可能拷成 <tmp>/<basename>，也可能直接把内容拷进 <tmp>，两种都兼容
    if [[ -e "$tmp/$(basename "$rel")" ]]; then
        mv "$tmp/$(basename "$rel")" "$dest"
        rm -rf "$tmp"
    else
        mv "$tmp" "$dest"
    fi
}

# 把本地备份回写到设备容器（copy to 会整体替换目标目录）
push_app_path() {
    local rel="$1" src="$DATA_BACKUP_DIR/$1"
    [[ -e "$src" ]] || return 0
    xcrun devicectl device copy to \
        --device "$DEVICE_IDENTIFIER" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "$src" \
        --destination "$rel"
}

if [[ "$RESET_TRUST" -eq 1 ]]; then
    if app_installed; then
        log "（--reset-trust）备份设备数据到 ${DATA_BACKUP_DIR} ..."
        for rel in "${BACKUP_PATHS[@]}"; do
            if fetch_app_path "$rel"; then
                log "  已备份 ${rel}"
            else
                log "  未备份 ${rel}（设备上不存在）"
            fi
        done
        for rel in "${REQUIRED_BACKUP_PATHS[@]}"; do
            if [[ ! -e "$DATA_BACKUP_DIR/$rel" ]]; then
                log "错误: 必需数据「${rel}」备份失败，已中止（未卸载，数据未受影响）" >&2
                log "请解锁手机并确认 USB 连接后重试" >&2
                exit 1
            fi
        done

        log "卸载 ${BUNDLE_ID}（数据已备份）..."
        xcrun devicectl device process terminate --device "$DEVICE_IDENTIFIER" "$BUNDLE_ID" > /dev/null 2>&1 || true
        if ! xcrun devicectl device uninstall app --device "$DEVICE_IDENTIFIER" "$BUNDLE_ID" > /dev/null 2>&1; then
            log "错误: 卸载失败，已中止（数据未受影响）" >&2
            exit 1
        fi
        log "已卸载，重装后需在手机上重新信任该开发者"
    else
        log "（--reset-trust）设备上未安装 ${BUNDLE_ID}，无需卸载（首次安装需在手机上信任开发者）"
    fi
fi

if [[ "$RENEW" -eq 1 ]]; then
    log "覆盖安装 ${APP_PATH}（升级安装：数据保留、无需重新信任）..."
else
    log "安装 ${APP_PATH} ..."
fi
xcrun devicectl device install app --device "$DEVICE_IDENTIFIER" "$APP_PATH"

# 备份回写：必须在 App 启动前完成
if [[ "$RESET_TRUST" -eq 1 && -d "$DATA_BACKUP_DIR" ]]; then
    log "回写备份数据（请保持手机解锁）..."
    RESTORE_FAILED=0
    for rel in "${BACKUP_PATHS[@]}"; do
        [[ -e "$DATA_BACKUP_DIR/$rel" ]] || continue
        if push_app_path "$rel" > /dev/null; then
            log "  已恢复 ${rel}"
        else
            RESTORE_FAILED=1
            log "  恢复失败 ${rel}" >&2
        fi
    done
    if [[ "$RESTORE_FAILED" -eq 1 ]]; then
        log "警告: 部分数据回写失败，备份仍保留在 ${DATA_BACKUP_DIR}" >&2
        log "手机解锁后可手动回写，例如:" >&2
        log "  xcrun devicectl device copy to --device ${DEVICE_IDENTIFIER} --domain-type appDataContainer --domain-identifier ${BUNDLE_ID} --source \"${DATA_BACKUP_DIR}/Documents\" --destination Documents" >&2
    else
        log "数据已恢复；备份保留在 ${DATA_BACKUP_DIR}（确认无误后可手动删除）"
    fi
fi

log "启动应用 (${BUNDLE_ID})..."
if [[ "$RESET_TRUST" -eq 1 ]]; then
    # 信任被清除时系统会拒绝启动，此时给出手机端授权步骤
    if LAUNCH_OUTPUT="$(xcrun devicectl device process launch --device "$DEVICE_IDENTIFIER" "$BUNDLE_ID" 2>&1)"; then
        log "启动成功：设备仍保留该开发者的信任（如需强制重新授权，请按下方指引手动移除）"
        print_trust_hint
    else
        log "启动被拒绝：设备要求重新信任该开发者" >&2
        echo "$LAUNCH_OUTPUT" | tail -n 5 >&2
        print_trust_hint
        exit 1
    fi
else
    xcrun devicectl device process launch --device "$DEVICE_IDENTIFIER" "$BUNDLE_ID" > /dev/null
fi

if [[ "$RENEW" -eq 1 && -n "$NEW_EXPIRY" ]]; then
    log "续期完成，新有效期至 ${NEW_EXPIRY}；建议到期前 1 天再执行一次: ./install-myhub-ios.sh --renew"
fi

log "完成"
