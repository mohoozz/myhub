pragma Singleton
import QtQuick

/*
  配色令牌 —— 严格对齐《需求分析文档》§2.10 与 prototype/_shared.css

  配色纪律（不得引入其它色相）：
    · 主色    #2563EB —— 选中 / 激活 / 进度 / 强调
    · 中性灰  文字与图标的唯一表意层级
    · 语义红  #DC2626 —— 仅用于破坏性操作与错误
    · 状态绿/红 仅用于连接状态圆点（PC-101 明确要求）
*/
QtObject {
    id: root

    // 由 AppTheme 注入（跟随系统时实时切换）
    property bool dark: false

    // ---- 主色 ----
    readonly property color primary:     dark ? "#3B82F6" : "#2563EB"
    readonly property color primaryInk:  "#1D4ED8"
    readonly property color primaryWeak: Qt.rgba(primary.r, primary.g, primary.b, 0.08)
    readonly property color primaryHover: Qt.rgba(primary.r, primary.g, primary.b, 0.04)

    // ---- 背景 ----
    readonly property color pageBg:    dark ? "#000000" : "#FFFFFF"
    readonly property color cardBg:    dark ? "#121212" : "#FFFFFF"
    readonly property color sidebarBg: dark ? "#0A0A0A" : "#FFFFFF"
    readonly property color fieldFill: dark ? "#2C2C2E" : "#F3F4F6"
    readonly property color hoverFill: dark ? "#1A1A1A" : "#F7F8FA"

    // ---- 描边（统一描边色与 1pt 宽度，§2.10）----
    readonly property color cardBorder: dark ? "#262626" : "#EDF0F3"
    readonly property color separator:  dark ? "#2A2A2A" : "#E5E7EB"

    // ---- 文字 ----
    readonly property color textPrimary:   dark ? "#E0E0E0" : "#1A1A2E"
    readonly property color textSecondary: dark ? "#888888" : "#6B7280"
    readonly property color textFaint:     dark ? "#5A5A5A" : "#9CA3AF"
    readonly property color textOnPrimary: "#FFFFFF"

    // ---- 语义色 ----
    readonly property color danger:  "#DC2626"
    /// 收藏星标（PC-107）：固定琥珀色，不随主题主色走（星标要一眼可辨）
    readonly property color star:    "#F59E0B"
    readonly property color stateOk:  "#16A34A"   // 连接正常绿点
    readonly property color stateBad: "#DC2626"   // 连接异常红点

    // ---- 沉浸场景（播放器 / 阅读器强制纯黑）----
    readonly property color immersiveBg: "#000000"

    // ---- 阴影 ----
    readonly property color shadowCard:  Qt.rgba(17/255, 24/255, 39/255, dark ? 0.5 : 0.07)
    readonly property color shadowFloat: Qt.rgba(17/255, 24/255, 39/255, dark ? 0.6 : 0.10)
    readonly property color shadowLift:  Qt.rgba(primary.r, primary.g, primary.b, 0.20)
}
