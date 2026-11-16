pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  小说阅读器（§5.1 / PC-205·206·210）。

  分层：正文分章、解编码、锚点换算全在 C++（`NovelBridge` + `myhub_core/novel`），
  这里只做三件事：把段落画出来、把滚动位置报回去、把排版偏好改掉。

  排版选型：**按段落虚拟化**，一段一个 Text，model 直接是 `Novel.paragraphs`。
    · 相比「整章塞进一个 TextEdit」，长章节不会一次性排完全部文字；
    · 段落下标天然就是锚点单位，滚动上报与恢复定位都不需要字符坐标换算；
    · 段距、行距、字号改了只需重建可见的十几个 item，调字号不会卡住 UI。
*/
Item {
    id: root

    // ---------------- 纸色主题（§5.1 主题：跟随系统 / 日间 / 夜间 / 护眼）----------------
    // 纸色与 AppTheme 的中性色刻意不同源：正文底色是「内容」，不该被外壳主题牵着走，
    // 否则夜间模式下叠加两种深色会出现半透明的脏灰
    readonly property int palette: Novel.theme === 0 ? (AppTheme.dark ? 2 : 1) : Novel.theme
    readonly property color paper: palette === 2 ? "#141517" : palette === 3 ? "#CFE3D0" : "#F6F1E4"
    readonly property color ink: palette === 2 ? "#BFC3CB" : palette === 3 ? "#2C3A2E" : "#2A2721"
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    readonly property color rule: Qt.rgba(ink.r, ink.g, ink.b, 0.12)
    readonly property color hoverFill: Qt.rgba(ink.r, ink.g, ink.b, 0.08)
    readonly property color sheetFill: palette === 2 ? "#1D1E21" : palette === 3 ? "#DCEBDB" : "#FFFDF8"

    /// 正文栏宽：超过约 34 个汉字一行就难以回扫，宽屏下拉满反而难读
    readonly property real columnWidth: Math.min(720, Math.max(280, width - 2 * AppTheme.spacingXl))

    /// 滚动上报节流（C++ 侧还有 1s 落库节流，这里只负责别把每个像素都发过去）
    property bool restoring: false
    property int pendingAnchor: -1

    /**
     * 是否已翻到全书最后（末章 + 列表见底）。
     *
     * 只有滚动视图知道「当前这屏是不是最后一屏」：按字节或段落下标在 C++ 侧猜，
     * 短章、插图、字号变化都会误判。恢复定位期间 contentY 会瞬时跳到末尾，必须排除。
     */
    readonly property bool atBookEnd: Novel.opened && !restoring && Novel.chapterCount > 0
        && Novel.chapterIndex >= Novel.chapterCount - 1 && list.contentHeight > 0
        && (list.contentHeight <= list.height + 2
            || list.contentY + list.height >= list.contentHeight - 2)

    onAtBookEndChanged: Novel.setAtBookEnd(atBookEnd)

    visible: Novel.opened || Novel.loading || Novel.errorText.length > 0
    focus: visible

    onVisibleChanged: if (visible) forceActiveFocus()

    Connections {
        target: Novel
        function onChapterChanged() {
            if (Novel.opened)
                root.scheduleAnchor()
        }
    }

    // ---------------- 定位与上报 ----------------

    /// 恢复锚点。段落 model 是异步换上的，所以「立刻 + 稍后」各定位一次：
    /// 只做一步的话，delegate 还没量出高度，positionViewAtIndex 会按估算高度落偏
    function scheduleAnchor() {
        pendingAnchor = Novel.anchorParagraph
        restoring = true
        restoreTimer.restart()
        Qt.callLater(root.applyAnchor)
        anchorRetry.restart()
    }

    function applyAnchor() {
        if (!Novel.opened)
            return
        if (pendingAnchor > 0 && pendingAnchor < list.count)
            list.positionViewAtIndex(pendingAnchor, ListView.Beginning)
        else
            list.positionViewAtBeginning()
    }

    function pushProgress() {
        if (!Novel.opened || restoring)
            return
        const first = list.indexAt(1, Math.max(0, list.contentY + 2))
        if (first >= 0)
            Novel.reportParagraph(first)
    }

    /// 翻页：滚动模式下一屏一屏走（翻页模式待 QTextLayout 分页落地后接入）
    function pageBy(direction) {
        const maxY = Math.max(0, list.contentHeight - list.height)
        list.contentY = Math.max(0, Math.min(maxY, list.contentY + direction * list.height * 0.9))
        pushProgress()
    }

    Timer {
        id: reportTimer
        interval: 350
        onTriggered: root.pushProgress()
    }

    Timer {
        id: restoreTimer
        interval: 400
        onTriggered: root.restoring = false
    }

    Timer {
        id: anchorRetry
        interval: 120
        onTriggered: root.applyAnchor()
    }

    // ---------------- 快捷键（§5.1）----------------
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            if (settingsPanel.opened)
                settingsPanel.opened = false
            else if (drawer.opened)
                drawer.opened = false
            else
                Novel.close()
            event.accepted = true
            return
        }
        if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_Left) {
                Novel.prevChapter()
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                Novel.nextChapter()
                event.accepted = true
            } else if (event.key === Qt.Key_D) {
                drawer.opened = !drawer.opened
                event.accepted = true
            } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
                Novel.fontSize = Novel.fontSize + 1
                event.accepted = true
            } else if (event.key === Qt.Key_Minus) {
                Novel.fontSize = Novel.fontSize - 1
                event.accepted = true
            }
            return
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp) {
            root.pageBy(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown
                   || event.key === Qt.Key_Space) {
            root.pageBy(1)
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            list.contentY = Math.max(0, list.contentY - 80)
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            list.contentY = list.contentY + 80
            event.accepted = true
        }
    }

    // ---------------- 纸面 ----------------
    Rectangle {
        anchors.fill: parent
        color: root.paper
    }

    // ---------------- 章内提示（截断 / 未识别到章节）----------------
    // 只在这种「有正文但信息不完整」的场合出现；首次打开的进度文案由全屏覆盖层负责
    Text {
        id: statusBanner

        anchors.top: topBar.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        height: visible ? implicitHeight + AppTheme.spacingSm : 0
        visible: Novel.opened && Novel.statusText.length > 0
        text: Novel.statusText
        color: root.inkSoft
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.Wrap
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeSmall
    }

    // ---------------- 正文 ----------------
    ListView {
        id: list

        anchors.top: topBar.bottom
        anchors.bottom: bottomBar.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        clip: true

        model: Novel.paragraphs
        // 段距用「字号的固定倍数」而不是行高的倍数：行距调大时段与段之间不该跟着膨胀
        spacing: Math.round(Novel.fontSize * 0.5)
        // 提示条占住的那几像素由正文让出来，避免第一段被压住
        topMargin: AppTheme.spacingXl + statusBanner.height
        bottomMargin: AppTheme.spacingXl
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 1600
        // 正文区域不抢焦点：空格/方向键要交给根节点做翻页
        focus: false

        header: Item {
            width: list.width
            height: heading.implicitHeight + AppTheme.spacingXl

            Column {
                id: heading
                width: parent.width
                spacing: AppTheme.spacingMd

                Text {
                    width: parent.width
                    text: Novel.chapterTitle
                    color: root.ink
                    wrapMode: Text.Wrap
                    font.family: AppTheme.fontFamily
                    font.pixelSize: Math.round(Novel.fontSize * 1.32)
                    font.weight: Font.DemiBold
                }

                Rectangle {
                    width: 36
                    height: 2
                    color: root.inkSoft
                }
            }
        }

        footer: Item {
            width: list.width
            height: tail.implicitHeight + AppTheme.spacingXl * 2

            Row {
                id: tail
                anchors.centerIn: parent
                spacing: AppTheme.spacingMd

                ReaderButton {
                    label: qsTr("上一章")
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    enabled: Novel.chapterIndex > 0
                    onClicked: Novel.prevChapter()
                }

                ReaderButton {
                    label: qsTr("下一章")
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    enabled: Novel.chapterIndex < Novel.chapterCount - 1
                    onClicked: Novel.nextChapter()
                }
            }
        }

        delegate: Text {
            id: paragraph

            required property string modelData

            width: list.width
            text: paragraph.modelData
            color: root.ink
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            font.family: AppTheme.fontFamily
            font.pixelSize: Novel.fontSize
            // 行距按字号倍数缩放：字号与行距是两个独立偏好，互不牵连
            lineHeight: Novel.lineSpacing
            lineHeightMode: Text.ProportionalHeight
        }

        onContentYChanged: {
            if (!root.restoring)
                reportTimer.restart()
        }
        onMovementEnded: root.pushProgress()
        onCountChanged: if (root.restoring) Qt.callLater(root.applyAnchor)
    }

    // ---------------- 顶栏 ----------------
    Rectangle {
        id: topBar

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: AppTheme.toolbarHeight
        color: root.paper

        ReaderButton {
            id: backButton
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-left"
            fg: root.ink
            hoverFill: root.hoverFill
            onClicked: Novel.close()
        }

        Column {
            anchors.centerIn: parent
            // 窄窗口（竖屏 / 分屏）下让位给左右两组按钮，别让标题压到图标上
            width: Math.max(0, Math.min(parent.width - 260, 560))
            spacing: 0

            Text {
                width: parent.width
                text: Novel.title
                color: root.ink
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.weight: Font.DemiBold
            }

            Text {
                width: parent.width
                text: Novel.chapterTitle
                color: root.inkSoft
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ReaderButton {
                icon: "list"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: drawer.opened = !drawer.opened
            }

            ReaderButton {
                icon: "settings"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: settingsPanel.opened = !settingsPanel.opened
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.rule
        }
    }

    // ---------------- 底栏 ----------------
    Rectangle {
        id: bottomBar

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: AppTheme.toolbarHeight + 4
        color: root.paper

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 2
            color: root.rule

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, Novel.percent))
                height: parent.height
                color: AppTheme.colors.primary
            }
        }

        ReaderButton {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-left"
            label: qsTr("上一章")
            fg: root.ink
            hoverFill: root.hoverFill
            enabled: Novel.chapterIndex > 0
            onClicked: Novel.prevChapter()
        }

        Text {
            anchors.centerIn: parent
            width: Math.max(0, parent.width - 300)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: Novel.chapterCount > 0
                ? qsTr("%1 / %2 章 · %3%").arg(Novel.chapterIndex + 1).arg(Novel.chapterCount).arg(Math.round(Novel.percent * 100))
                : ""
            color: root.inkSoft
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
        }

        ReaderButton {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-right"
            label: qsTr("下一章")
            fg: root.ink
            hoverFill: root.hoverFill
            enabled: Novel.chapterIndex < Novel.chapterCount - 1
            onClicked: Novel.nextChapter()
        }
    }

    // ---------------- 读完推荐「下一本」（§4.6 阅读侧）----------------
    // 与播放器同一条纪律：**无倒计时、不自动切换**，点才走，点叉就不再打扰
    Rectangle {
        id: nextBanner

        readonly property var suggestion: Novel.nextSuggestion || ({})
        readonly property bool hasSuggestion: suggestion.path !== undefined && suggestion.path !== ""

        visible: hasSuggestion
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: bottomBar.top
        anchors.bottomMargin: AppTheme.spacingLg
        width: Math.min(root.columnWidth, 480)
        height: 68
        radius: AppTheme.radiusCard
        // 用纸面色而不是固定深色：阅读器有自己的日间/夜间/护眼三套底色
        color: root.sheetFill
        border.width: AppTheme.borderWidth
        border.color: root.rule

        Column {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.right: actions.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: qsTr("读完了 · 下一本")
                color: root.inkSoft
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
            }

            Text {
                width: parent.width
                text: nextBanner.suggestion.title || ""
                color: root.ink
                elide: Text.ElideRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.weight: Font.DemiBold
            }
        }

        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ReaderButton {
                label: qsTr("开始读")
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: Novel.openNextSuggestion()
            }

            ReaderButton {
                icon: "x"
                fg: root.inkSoft
                hoverFill: root.hoverFill
                onClicked: Novel.dismissNextSuggestion()
            }
        }
    }

    // ---------------- 目录抽屉（PC-205）----------------
    Item {
        id: drawer

        property bool opened: false
        property int panelWidth: Math.min(340, Math.round(root.width * 0.72))

        anchors.fill: parent
        z: 40
        // 收起后不该拦住正文的鼠标事件
        visible: opened || panel.x < root.width

        // 抽屉里的 ListView 会抢焦点，收起时把键盘交还给根节点，否则 Esc/翻页失灵
        onOpenedChanged: if (!opened) root.forceActiveFocus()

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: drawer.opened ? 0.24 : 0
            enabled: drawer.opened

            Behavior on opacity {
                NumberAnimation { duration: Motion.normal }
            }

            TapHandler {
                onTapped: drawer.opened = false
            }
        }

        Rectangle {
            id: panel

            width: drawer.panelWidth
            height: parent.height
            x: drawer.opened ? parent.width - width : parent.width
            color: root.sheetFill

            Behavior on x {
                NumberAnimation {
                    duration: Motion.normal
                    easing.type: Motion.easeOut
                }
            }

            Item {
                id: panelHeader

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: AppTheme.toolbarHeight

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: AppTheme.spacingLg
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("目录 · %1 章").arg(Novel.chapterCount)
                    color: root.ink
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeHeading
                    font.weight: Font.DemiBold
                }

                ReaderButton {
                    anchors.right: parent.right
                    anchors.rightMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "x"
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    onClicked: drawer.opened = false
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.rule
                }
            }

            ListView {
                id: tocList

                anchors.top: panelHeader.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                clip: true
                model: Novel.chapters
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: tocRow

                    required property var modelData
                    required property int index

                    width: tocList.width
                    height: 44
                    color: index === Novel.chapterIndex ? root.hoverFill
                           : tocHover.hovered ? root.hoverFill : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: AppTheme.spacingLg
                        anchors.right: parent.right
                        anchors.rightMargin: AppTheme.spacingLg
                        anchors.verticalCenter: parent.verticalCenter
                        text: tocRow.modelData.title
                        elide: Text.ElideRight
                        color: tocRow.index === Novel.chapterIndex ? AppTheme.colors.primary : root.ink
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        font.weight: tocRow.index === Novel.chapterIndex ? Font.DemiBold : Font.Normal
                    }

                    HoverHandler {
                        id: tocHover
                    }

                    TapHandler {
                        onTapped: {
                            Novel.goToChapter(tocRow.index)
                            drawer.opened = false
                        }
                    }
                }
            }

            onXChanged: if (drawer.opened && Novel.chapterIndex >= 0) tocList.positionViewAtIndex(
                            Novel.chapterIndex, ListView.Contain)
        }
    }

    // ---------------- 设置面板（字号/行距/主题/亮度）----------------
    Item {
        id: settingsPanel

        property bool opened: false
        readonly property int sheetHeight: 232

        anchors.fill: parent
        z: 50
        visible: opened || sheetBody.y < root.height

        // 亮度滑杆是 Controls 控件，点过之后会持有 activeFocus
        onOpenedChanged: if (!opened) root.forceActiveFocus()

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: settingsPanel.opened ? 0.24 : 0
            enabled: settingsPanel.opened

            Behavior on opacity {
                NumberAnimation { duration: Motion.normal }
            }

            TapHandler {
                onTapped: settingsPanel.opened = false
            }
        }

        Rectangle {
            id: sheetBody

            anchors.left: parent.left
            anchors.right: parent.right
            height: settingsPanel.sheetHeight
            y: settingsPanel.opened ? root.height - height : root.height
            color: root.sheetFill
            radius: AppTheme.radiusCard

            Behavior on y {
                NumberAnimation {
                    duration: Motion.normal
                    easing.type: Motion.easeOut
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: AppTheme.spacingXl
                spacing: AppTheme.spacingMd

                // ---- 字号 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("字号")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        ReaderButton {
                            icon: "chevron-left"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.fontSize > 12
                            onClicked: Novel.fontSize = Novel.fontSize - 1
                        }

                        Text {
                            width: 40
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: Novel.fontSize
                            color: root.ink
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                        }

                        ReaderButton {
                            icon: "chevron-right"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.fontSize < 32
                            onClicked: Novel.fontSize = Novel.fontSize + 1
                        }
                    }
                }

                // ---- 行距 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("行距")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        ReaderButton {
                            icon: "chevron-left"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.lineSpacing > 1.25
                            onClicked: Novel.lineSpacing = Math.max(1.2, Math.round((Novel.lineSpacing - 0.2) * 10) / 10)
                        }

                        Text {
                            width: 40
                            horizontalAlignment: Text.AlignHCenter
                            text: Novel.lineSpacing.toFixed(1)
                            color: root.ink
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                        }

                        ReaderButton {
                            icon: "chevron-right"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.lineSpacing < 2.35
                            onClicked: Novel.lineSpacing = Math.min(2.4, Math.round((Novel.lineSpacing + 0.2) * 10) / 10)
                        }
                    }
                }

                // ---- 主题 ----
                Item {
                    width: parent.width
                    height: 40

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("主题")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        Repeater {
                            // 0=跟随系统 1=日间 2=夜间 3=护眼：色块即预览，避免文字标签再来一层抽象
                            model: ["auto", "day", "night", "eye"]

                            delegate: Rectangle {
                                id: swatch

                                required property int index

                                width: 34
                                height: 30
                                radius: AppTheme.radiusSmall
                                color: index === 0 ? root.sheetFill
                                       : index === 1 ? "#F6F1E4"
                                       : index === 2 ? "#141517" : "#CFE3D0"
                                border.width: Novel.theme === index ? 2 : 1
                                border.color: Novel.theme === index ? AppTheme.colors.primary : root.rule

                                Text {
                                    anchors.centerIn: parent
                                    visible: swatch.index === 0
                                    text: qsTr("自动")
                                    color: root.ink
                                    font.family: AppTheme.fontFamily
                                    font.pixelSize: AppTheme.fontSizeTiny
                                }

                                TapHandler {
                                    onTapped: Novel.theme = swatch.index
                                }
                            }
                        }
                    }
                }

                // ---- 亮度（窗口蒙层，与播放器共用偏好）----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("亮度")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    C.Slider {
                        id: brightnessSlider

                        anchors.left: parent.left
                        anchors.leftMargin: 64
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0.35
                        to: 1.0
                        // -1 是「不叠加蒙层」的哨兵值，视觉上等同最亮
                        value: Novel.brightness < 0 ? 1.0 : Novel.brightness

                        onMoved: Novel.brightness = Math.round(value * 100) / 100
                    }
                }
            }
        }
    }

    // ---------------- 加载 / 错误 ----------------
    Rectangle {
        id: stateOverlay

        anchors.fill: parent
        z: 60
        color: root.paper
        // 只有「首次打开」和「出错」才全屏遮挡；换章时正文还在，不该闪一层白
        visible: Novel.errorText.length > 0 || (Novel.loading && Novel.paragraphs.length === 0)

        Column {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 64)
            spacing: AppTheme.spacingLg

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: root.ink
                text: Novel.errorText.length > 0 ? Novel.errorText : Novel.statusText
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
            }

            ReaderButton {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: Novel.errorText.length > 0
                label: qsTr("返回")
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: Novel.close()
            }
        }
    }

    // ---------------- 亮度蒙层（§5.1「窗口蒙层」，只压这一层）----------------
    Rectangle {
        anchors.fill: parent
        z: 70
        color: "#000000"
        opacity: Novel.brightness < 0 ? 0 : (1 - Novel.brightness) * 0.6
        visible: opacity > 0.001
    }
}
