pragma Singleton
import QtQuick
import MyHub

/*
  设计令牌总入口 —— 对齐《需求分析文档》§2.10 / prototype/_shared.css

  圆角：卡片 12 / 按钮 20（胶囊）/ 输入框 8 / 悬浮装饰条 26
  描边：统一 1pt
  动效：≤ 200ms
*/
QtObject {
    id: theme

    // 主题随 ThemeController 实时切换（跟随系统时监听系统外观）
    readonly property bool dark: ThemeController.isDark
    onDarkChanged: Colors.dark = dark
    Component.onCompleted: Colors.dark = dark

    // 声明成 Colors 而不是 QtObject：qmllint 才能解析 AppTheme.colors.pageBg 这类访问
    readonly property Colors colors: Colors

    // ---- 圆角 ----
    readonly property int radiusCard:    12
    readonly property int radiusButton:  20
    readonly property int radiusInput:   8
    readonly property int radiusCapsule: 26
    readonly property int radiusSmall:   6

    // ---- 描边（统一 1pt，§2.10「不得各自为政」）----
    readonly property int borderWidth: 1

    // ---- 间距 ----
    readonly property int spacingXs: 4
    readonly property int spacingSm: 8
    readonly property int spacingMd: 12
    readonly property int spacingLg: 16
    readonly property int spacingXl: 24

    // ---- 字号 ----
    readonly property int fontSizeTitle:   20
    readonly property int fontSizeHeading: 16
    readonly property int fontSizeBody:    14
    readonly property int fontSizeSmall:   12
    readonly property int fontSizeTiny:    11

    // ---- 字体（§2.10）----
    readonly property string fontFamily: Qt.platform.os === "osx"
        ? "PingFang SC, SF Pro, Helvetica Neue"
        : "Microsoft YaHei UI, Segoe UI, sans-serif"

    // ---- 布局断点（§2.2.1 侧边栏三形态）----
    readonly property int breakpointExpanded:  1100   // ≥ 展开侧边栏
    readonly property int breakpointCollapsed: 760    // ~ 折叠图标栏；< 抽屉式
    readonly property int sidebarWidthExpanded:  200
    readonly property int sidebarWidthCollapsed: 64

    // ---- 控件尺寸 ----
    readonly property int rowHeight:      44
    readonly property int toolbarHeight:  52
    readonly property int searchHeight:   40
    readonly property int miniPlayerHeight: 64

    // ---- 按压反馈（§1.2 缩放 0.975 + 淡填充）----
    readonly property real pressScale: 0.975
}
