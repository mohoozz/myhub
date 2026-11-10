import QtQuick
import MyHub

/*
  主窗口外壳（§2.2.1 / §2.2.2）。

  结构：左侧侧边栏 + 内容区（+ 底部播放条与全屏路由层，M2 接入）

  宽度断点自适应：
    ≥ 1100        展开侧边栏（200px）
    760 ~ 1100    折叠图标栏（64px，hover 浮出文字）
    < 760         抽屉式（汉堡按钮唤出覆盖层）

  **页面保活**：各模块用 StackLayout 常驻不销毁，
  切换导航保留滚动位置 / 搜索词 / 选择态（§2.2.2）。
*/
Item {
    id: root

    // 断点判定
    readonly property bool drawerMode: width < AppTheme.breakpointCollapsed
    readonly property bool autoCollapsed: width < AppTheme.breakpointExpanded
    // 手动固定的折叠状态优先于自动判定
    readonly property bool sidebarCollapsed:
        WindowController.sidebarCollapsed || autoCollapsed

    property bool drawerOpen: false

    /// 播放器等覆盖层退出后把键盘焦点交还主外壳
    function restoreFocus() {
        keyHandler.forceActiveFocus()
    }

    readonly property int sidebarWidth: drawerMode
        ? AppTheme.sidebarWidthExpanded
        : (sidebarCollapsed ? AppTheme.sidebarWidthCollapsed
                            : AppTheme.sidebarWidthExpanded)

    // 窄窗口切换到抽屉模式时自动收起，避免遮挡内容
    onDrawerModeChanged: if (drawerMode) drawerOpen = false

    // ---------------- 内容区 ----------------
    Item {
        id: contentArea
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.left: parent.left
        anchors.leftMargin: root.drawerMode ? 0 : root.sidebarWidth

        Behavior on anchors.leftMargin {
            NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut }
        }

        Rectangle {
            anchors.fill: parent
            color: AppTheme.colors.pageBg
        }

        // 抽屉模式下的汉堡按钮
        Item {
            id: hamburger
            visible: root.drawerMode
            width: 36
            height: 36
            x: AppTheme.spacingSm
            y: AppTheme.spacingSm
            z: 5

            Rectangle {
                anchors.fill: parent
                radius: AppTheme.radiusSmall
                color: hamburgerMouse.containsMouse
                    ? AppTheme.colors.hoverFill : "transparent"
            }
            AppIcon {
                anchors.centerIn: parent
                name: "menu"
                width: 18
                height: 18
                color: AppTheme.colors.textPrimary
            }
            MouseArea {
                id: hamburgerMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.drawerOpen = !root.drawerOpen
            }
        }

        // ---- 模块页面（全部常驻，切换不销毁）----
        Item {
            id: pages
            anchors.fill: parent
            anchors.topMargin: root.drawerMode ? hamburger.height + AppTheme.spacingSm * 2 : 0
            // mini 播放条与传输横幅各占独立一行，页面内容随之让位（不遮挡、不相贴）
            anchors.bottomMargin: (PlayerStage.miniVisible ? miniBar.height : 0)
                                  + transferBanner.height

            Behavior on anchors.bottomMargin {
                NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut }
            }

            // 正在阅读（PC-209 / PC-705）
            ReadingHome {
                id: readingHome
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Reading
            }

            // 收藏（PC-107）
            FavoritesHome {
                id: favoritesHome
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Favorites
            }

            // 动态（PC-301 预留）
            ModulePlaceholder {
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Feed
                iconName: "zap"
                title: qsTr("动态")
                description: qsTr("功能开发中 / 待接入外部 API")
            }

            // 浏览（M0 实现）
            BrowseHome {
                id: browseHome
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Browse
            }

            // 浏览器（M4 实现）
            ModulePlaceholder {
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Browser
                iconName: "globe"
                title: qsTr("内置浏览器")
                description: qsTr("多标签浏览器将在 M4 里程碑实现。")
            }

            // 设置（M0 实现连接源部分）
            SettingsHome {
                id: settingsHome
                anchors.fill: parent
                visible: AppRouter.currentModule === AppRouter.Settings
            }
        }

        // ---- 传输队列横幅（§3.2）：跨页面常驻，页面内容随之让位 ----
        TransferBanner {
            id: transferBanner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: PlayerStage.miniVisible ? miniBar.height : 0

            Behavior on anchors.bottomMargin {
                NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut }
            }
        }

        // ---- mini 播放条（§4.4）：跨页面常驻，点击展开回完整播放 ----
        MiniPlayerBar {
            id: miniBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: PlayerStage.miniVisible
            onExpandRequested: PlayerStage.showFull()
            onCloseRequested: Player.close()
        }
    }

    // ---------------- 侧边栏 ----------------
    Sidebar {
        id: sidebar
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.sidebarWidth
        collapsed: root.drawerMode ? false : root.sidebarCollapsed
        z: 10

        // 抽屉模式下滑入滑出
        x: root.drawerMode ? (root.drawerOpen ? 0 : -width) : 0
        Behavior on x {
            NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut }
        }

        onAvatarClicked: AppRouter.select(AppRouter.Settings)
    }

    // 抽屉模式的遮罩
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        visible: opacity > 0
        opacity: (root.drawerMode && root.drawerOpen) ? 1 : 0
        z: 9

        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

        MouseArea {
            anchors.fill: parent
            enabled: root.drawerMode && root.drawerOpen
            onClicked: root.drawerOpen = false
        }
    }

    // ---------------- 全局快捷键 ----------------
    // Ctrl+1..6 切换模块（§8.5）
    Item {
        id: keyHandler
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
            if (event.modifiers & Qt.ControlModifier) {
                // Ctrl+M：mini 条 ↔ 完整播放（全屏层有焦点时由 PlayerView 处理）
                if (event.key === Qt.Key_M) {
                    PlayerStage.toggle()
                    event.accepted = true
                    return
                }
                if (event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
                    AppRouter.selectByIndex(event.key - Qt.Key_1)
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Comma) {
                    AppRouter.select(AppRouter.Settings)
                    event.accepted = true
                    return
                }
            }
            if (event.key === Qt.Key_F11) {
                WindowController.toggleFullScreen()
                event.accepted = true
            }
        }
    }
}
