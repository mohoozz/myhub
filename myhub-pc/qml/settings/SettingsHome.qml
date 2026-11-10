import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

// 右侧内容里的重复区块访问外层 id，绑定组件上下文（qmllint 约定）
pragma ComponentBehavior: Bound

/*
  设置页（§2.8）—— 双栏布局：左侧分类导航 + 右侧内容。

  M0 实现：连接源、显示设置、关于（版本 / 日志 / 数据目录）。
  其余分类随对应里程碑补齐。
*/
Item {
    id: root

    property int currentSection: 0
    property bool editingConnection: false

    // 播放器偏好：这些键没有独立的 NOTIFY 属性，读一次后本地镜像，写入即回写页面状态
    property real volumeStep: AppSettings.value("player.volumeStep", 0.05)
    property int seekStepSeconds: AppSettings.value("player.seekStepSeconds", 10)
    property int subtitleFontSize: AppSettings.value("player.subtitleFontSize", 16)
    property string decodePreference: AppSettings.value("player.decodePreference", "auto")
    property bool audioOnlyByDefault: AppSettings.value("player.audioOnlyByDefault", false)

    Rectangle {
        anchors.fill: parent
        color: AppTheme.colors.pageBg
    }

    // ---------------- 左栏：分类 ----------------
    Rectangle {
        id: nav
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 180
        color: "transparent"

        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: AppTheme.borderWidth
            color: AppTheme.colors.cardBorder
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: AppTheme.spacingLg
            spacing: 2

            Repeater {
                model: [
                    { icon: "database", label: qsTr("连接源"),   index: 0 },
                    { icon: "grid",     label: qsTr("显示"),     index: 1 },
                    { icon: "book",     label: qsTr("阅读器"),   index: 2 },
                    { icon: "play",     label: qsTr("播放器"),   index: 3 },
                    { icon: "hard-drive", label: qsTr("缓存与存储"), index: 4 },
                    { icon: "trash",    label: qsTr("回收站"),   index: 5 },
                    { icon: "info",     label: qsTr("关于"),     index: 6 }
                ]

                delegate: SidebarItem {
                    required property var modelData
                    width: parent.width
                    iconName: modelData.icon
                    label: modelData.label
                    selected: root.currentSection === modelData.index
                    onClicked: {
                        root.currentSection = modelData.index
                        root.editingConnection = false
                    }
                }
            }
        }
    }

    // ---------------- 右栏：内容 ----------------
    Item {
        id: content
        anchors.left: nav.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        // ---- 0. 连接源 ----
        Item {
            anchors.fill: parent
            anchors.margins: AppTheme.spacingXl
            visible: root.currentSection === 0 && !root.editingConnection

            ConnectionListView {
                anchors.fill: parent
                onAddRequested: {
                    connectionForm.resetForNew()
                    root.editingConnection = true
                }
                onEditRequested: function(data) {
                    connectionForm.loadFrom(data)
                    root.editingConnection = true
                }
            }
        }

        ConnectionFormView {
            id: connectionForm
            anchors.fill: parent
            visible: root.currentSection === 0 && root.editingConnection

            onSaved: root.editingConnection = false
            onCancelled: root.editingConnection = false
        }

        // ---- 1. 显示设置 ----
        C.ScrollView {
            anchors.fill: parent
            anchors.margins: AppTheme.spacingXl
            visible: root.currentSection === 1
            contentWidth: availableWidth

            Column {
                width: parent.width
                spacing: AppTheme.spacingXl

                SectionTitle { text: qsTr("显示") }

                // 文件名行数（1~5，六处生效且即时生效，§14.3）
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("文件名行数：%1").arg(AppSettings.fileNameLines)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("在浏览、收藏、阅读页的网格与列表视图中同时生效，修改后立即应用。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    C.Slider {
                        width: Math.min(parent.width, 280)
                        from: 1
                        to: 5
                        stepSize: 1
                        snapMode: C.Slider.SnapAlways
                        value: AppSettings.fileNameLines
                        onMoved: AppSettings.fileNameLines = value
                    }
                }

                // 默认视图
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("默认视图")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        PrimaryButton {
                            text: qsTr("网格")
                            iconName: "grid"
                            variant: AppSettings.viewMode === "grid"
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.viewMode = "grid"
                        }
                        PrimaryButton {
                            text: qsTr("列表")
                            iconName: "list"
                            variant: AppSettings.viewMode === "list"
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.viewMode = "list"
                        }
                    }
                }

                // 打开方式
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("打开方式")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        PrimaryButton {
                            text: qsTr("双击打开")
                            variant: !AppSettings.openOnSingleClick
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.openOnSingleClick = false
                        }
                        PrimaryButton {
                            text: qsTr("单击打开")
                            variant: AppSettings.openOnSingleClick
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.openOnSingleClick = true
                        }
                    }
                }

                // 主题模式
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("主题")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        Repeater {
                            model: [
                                { mode: ThemeController.FollowSystem, label: qsTr("跟随系统") },
                                { mode: ThemeController.Light,        label: qsTr("亮色") },
                                { mode: ThemeController.Dark,         label: qsTr("暗色") }
                            ]
                            delegate: PrimaryButton {
                                required property var modelData
                                text: modelData.label
                                variant: ThemeController.mode === modelData.mode
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: ThemeController.mode = modelData.mode
                            }
                        }
                    }
                }
            }
        }

        // ---- 2/3/4 占位 ----
        EmptyState {
            anchors.fill: parent
            visible: root.currentSection === 2
            iconName: "book"
            title: qsTr("阅读器设置")
            description: qsTr("字号、行距、主题、翻页模式等将在 M3 里程碑实现。")
        }
        // ---- 3. 播放器设置 ----
        C.ScrollView {
            anchors.fill: parent
            anchors.margins: AppTheme.spacingXl
            visible: root.currentSection === 3
            contentWidth: availableWidth

            Column {
                width: parent.width
                spacing: AppTheme.spacingXl

                SectionTitle { text: qsTr("播放器") }

                // 音量步进（键盘 / 滚轮每格增减多少）
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("音量步进：%1%").arg(Math.round(root.volumeStep * 100))
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("按音量键或滚动滚轮时每次调整的幅度，修改后立即生效。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    C.Slider {
                        width: Math.min(parent.width, 280)
                        from: 0.02
                        to: 0.20
                        stepSize: 0.01
                        snapMode: C.Slider.SnapAlways
                        value: root.volumeStep
                        onMoved: {
                            root.volumeStep = value
                            AppSettings.setValue("player.volumeStep", value)
                        }
                    }
                }

                // 快进 / 快退步长
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("快进快退步长：%1 秒").arg(root.seekStepSeconds)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("按左右方向键时每次跳转的时长，修改后立即生效。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    C.Slider {
                        width: Math.min(parent.width, 280)
                        from: 5
                        to: 60
                        stepSize: 5
                        snapMode: C.Slider.SnapAlways
                        value: root.seekStepSeconds
                        onMoved: {
                            root.seekStepSeconds = value
                            AppSettings.setValue("player.seekStepSeconds", value)
                        }
                    }
                }

                // 字幕字号
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("字幕字号：%1").arg(root.subtitleFontSize)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("作用于内嵌与外部字幕，正在播放时立即生效。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    C.Slider {
                        width: Math.min(parent.width, 280)
                        from: 10
                        to: 40
                        stepSize: 1
                        snapMode: C.Slider.SnapAlways
                        value: root.subtitleFontSize
                        onMoved: {
                            root.subtitleFontSize = value
                            // 经门面下发：正在播的那一路立刻换字号，不必重开
                            Player.setSubtitleFontSize(value)
                        }
                    }
                }

                // 解码方式
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("解码方式")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("自动：优先硬解，失败时自动回退软解；软件解码：始终用 CPU 解码（兼容性最好，功耗更高）。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        Repeater {
                            model: [
                                { mode: "auto",     label: qsTr("自动") },
                                { mode: "hardware", label: qsTr("强制硬解") },
                                { mode: "software", label: qsTr("软件解码") }
                            ]
                            delegate: PrimaryButton {
                                required property var modelData
                                text: modelData.label
                                variant: root.decodePreference === modelData.mode
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: {
                                    root.decodePreference = modelData.mode
                                    AppSettings.setValue("player.decodePreference", modelData.mode)
                                }
                            }
                        }
                    }
                }

                // 纯音频模式默认值
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("默认以纯音频模式打开")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("开启后，视频文件也按纯音频方式起播（省电，不看画面）；播放中可随时切换。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        PrimaryButton {
                            text: qsTr("关闭")
                            variant: !root.audioOnlyByDefault
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: {
                                root.audioOnlyByDefault = false
                                AppSettings.setValue("player.audioOnlyByDefault", false)
                            }
                        }
                        PrimaryButton {
                            text: qsTr("开启")
                            variant: root.audioOnlyByDefault
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: {
                                root.audioOnlyByDefault = true
                                AppSettings.setValue("player.audioOnlyByDefault", true)
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("最小化时进入悬浮小窗")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }
                    Text {
                        text: qsTr("主窗口最小化时缩成置顶小窗继续播（播放时不打断）。"
                                   + "默认关闭；播放器里的「悬浮小窗」按钮不受此开关影响。")
                        width: parent.width
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }
                    Row {
                        spacing: AppTheme.spacingSm
                        PrimaryButton {
                            text: qsTr("关闭")
                            variant: !WindowController.minimizeToFloating
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: WindowController.minimizeToFloating = false
                        }
                        PrimaryButton {
                            text: qsTr("开启")
                            variant: WindowController.minimizeToFloating
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: WindowController.minimizeToFloating = true
                        }
                    }
                }
            }
        }
        EmptyState {
            anchors.fill: parent
            visible: root.currentSection === 4
            iconName: "hard-drive"
            title: qsTr("缓存与存储")
            description: qsTr("分区占用统计与清理将在 M5 里程碑实现。")
        }

        // ---- 5. 回收站 ----
        TrashSection {
            anchors.fill: parent
            active: root.currentSection === 5
            visible: root.currentSection === 5
        }

        // ---- 6. 关于 ----
        C.ScrollView {
            anchors.fill: parent
            anchors.margins: AppTheme.spacingXl
            visible: root.currentSection === 6
            contentWidth: availableWidth

            Column {
                width: parent.width
                spacing: AppTheme.spacingLg

                SectionTitle { text: qsTr("关于") }

                Row {
                    spacing: AppTheme.spacingMd

                    Rectangle {
                        width: 52
                        height: 52
                        radius: AppTheme.radiusCard
                        color: AppTheme.colors.primary
                        AppIcon {
                            anchors.centerIn: parent
                            name: "folder"
                            width: 28
                            height: 28
                            color: AppTheme.colors.textOnPrimary
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Text {
                            text: "MyHub"
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTitle
                            font.bold: true
                            color: AppTheme.colors.textPrimary
                        }
                        Text {
                            text: qsTr("版本 %1").arg(AppState.version)
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeSmall
                            color: AppTheme.colors.textSecondary
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: qsTr("个人内容中心 · 纯本地运行，数据不上传。\n"
                             + "本软件使用 Qt (LGPLv3)、libmpv (LGPL)、FFmpeg (LGPL)、"
                             + "libsmb2 (LGPL)、libarchive (BSD)、SQLite (Public Domain)、mpvqt (LGPL)。")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeSmall
                    color: AppTheme.colors.textSecondary
                    wrapMode: Text.Wrap
                    lineHeight: 1.4
                }

                // 日志与诊断（PC-707）
                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm

                    SectionTitle { text: qsTr("诊断") }

                    Row {
                        spacing: AppTheme.spacingSm
                        PrimaryButton {
                            text: qsTr("查看日志")
                            variant: PrimaryButton.Secondary
                            onClicked: {
                                logDialog.logText = AppState.logTail(300).join("\n")
                                logDialog.open()
                            }
                        }
                        PrimaryButton {
                            text: qsTr("打开日志文件夹")
                            variant: PrimaryButton.Secondary
                            onClicked: WindowController.openLogFolder()
                        }
                        PrimaryButton {
                            text: qsTr("打开数据目录")
                            variant: PrimaryButton.Secondary
                            onClicked: WindowController.openDataFolder()
                        }
                    }

                    // 上次崩溃提示
                    Rectangle {
                        width: parent.width
                        height: visible ? 56 : 0
                        visible: AppState.hasCrashReport
                        radius: AppTheme.radiusInput
                        color: Qt.rgba(AppTheme.colors.danger.r, AppTheme.colors.danger.g,
                                       AppTheme.colors.danger.b, 0.08)

                        Row {
                            anchors.fill: parent
                            anchors.margins: AppTheme.spacingMd
                            spacing: AppTheme.spacingSm

                            AppIcon {
                                name: "alert-circle"
                                width: 18; height: 18
                                anchors.verticalCenter: parent.verticalCenter
                                color: AppTheme.colors.danger
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("上次运行异常退出，已生成崩溃报告。")
                                font.family: AppTheme.fontFamily
                                font.pixelSize: AppTheme.fontSizeSmall
                                color: AppTheme.colors.danger
                            }
                            PrimaryButton {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("清除")
                                variant: PrimaryButton.Text
                                destructive: true
                                onClicked: AppState.clearCrashReport()
                            }
                        }
                    }
                }
            }
        }
    }

    // 日志查看
    C.Dialog {
        id: logDialog
        property string logText: ""

        anchors.centerIn: C.Overlay.overlay
        width: Math.min(760, root.width - 80)
        height: Math.min(520, root.height - 80)
        modal: true
        title: qsTr("运行日志")
        padding: AppTheme.spacingLg

        background: Rectangle {
            radius: AppTheme.radiusCard
            color: AppTheme.colors.cardBg
            border.width: AppTheme.borderWidth
            border.color: AppTheme.colors.cardBorder
        }

        contentItem: C.ScrollView {
            clip: true
            C.TextArea {
                text: logDialog.logText
                readOnly: true
                wrapMode: TextEdit.NoWrap
                font.family: "Consolas, ui-monospace, monospace"
                font.pixelSize: AppTheme.fontSizeTiny
                color: AppTheme.colors.textSecondary
                background: null
            }
        }

        footer: Row {
            padding: AppTheme.spacingLg
            spacing: AppTheme.spacingSm
            layoutDirection: Qt.RightToLeft

            PrimaryButton {
                text: qsTr("关闭")
                onClicked: logDialog.close()
            }
            PrimaryButton {
                text: qsTr("清空日志")
                variant: PrimaryButton.Text
                destructive: true
                onClicked: {
                    AppState.clearLogs()
                    logDialog.logText = ""
                }
            }
        }
    }

    component SectionTitle: Text {
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeHeading
        font.bold: true
        color: AppTheme.colors.textPrimary
    }
}
