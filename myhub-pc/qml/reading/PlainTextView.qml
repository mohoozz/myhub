pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  纯文本阅读器（PC-210，第 4 条阅读路由）。

  与小说阅读器的分工：这里**不建索引、不记进度**，打开就按块往下读；
  需要章节 / 续读位置时，顶栏那颗「章节阅读」把它交给 `Novel`。

  为什么按块虚拟化而不是整篇塞一个 TextEdit：一个 20MB 的 txt 一旦整篇布局，
  光是文字排版就要几百毫秒、内存翻倍。C++ 侧（`PlainTextBridge`）把文件切成
  整行对齐的块，这里只画看得见的那几块；滚到底部由 ListView 自己调 fetchMore。
*/
Item {
    id: root

    // ---------------- 纸色 ----------------
    // 与小说阅读器同一套纸色：正文底色是「内容」，不该被外壳主题牵着走
    readonly property color paper: AppTheme.dark ? "#141517" : "#F6F1E4"
    readonly property color ink: AppTheme.dark ? "#BFC3CB" : "#2A2721"
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    readonly property color rule: Qt.rgba(ink.r, ink.g, ink.b, 0.12)
    readonly property color hoverFill: Qt.rgba(ink.r, ink.g, ink.b, 0.08)
    readonly property color sheetFill: AppTheme.dark ? "#1D1E21" : "#FFFDF8"

    /// 正文栏宽：一行超过约 34 个汉字就难以回扫
    readonly property real columnWidth: Math.min(760, Math.max(280, width - 2 * AppTheme.spacingXl))

    readonly property string sizeLabel: {
        const bytes = Plain.fileSize
        if (bytes <= 0)
            return "0 B"
        if (bytes < 1024)
            return bytes + " B"
        if (bytes < 1024 * 1024)
            return (bytes / 1024).toFixed(1) + " KB"
        return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    }

    property bool findOpen: false
    /// 查找结果提示（未找到 / 已扫描到上限）
    property string findStatus: ""

    visible: Plain.active || Plain.loading || Plain.errorText.length > 0
    focus: visible

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            findStatus = ""
        } else {
            findOpen = false
            Plain.clearFind()
        }
    }

    function close() {
        Plain.close()
    }

    /// 交给小说阅读器：章节、目录、续读位置那边才有
    function openAsNovel() {
        const connectionId = Plain.connectionId
        const path = Plain.path
        const title = Plain.title
        Plain.close()
        Novel.open(connectionId, path, title)
    }

    function openFind() {
        findOpen = true
        findField.forceActiveFocus()
        findField.selectAll()
    }

    function closeFind() {
        findOpen = false
        findStatus = ""
        list.forceActiveFocus()
    }

    function runFind() {
        const needle = findField.text
        if (needle.length === 0) {
            Plain.clearFind()
            findStatus = ""
            return
        }
        if (needle === Plain.findText && Plain.hitRow >= 0) {
            Plain.findNext()
        } else {
            Plain.find(needle)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.paper
    }

    // ---------------- 顶栏 ----------------
    Item {
        id: topBar
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
        }
        height: AppTheme.toolbarHeight

        Row {
            anchors {
                left: parent.left
                leftMargin: AppTheme.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: AppTheme.spacingSm

            ReaderButton {
                icon: "arrow-left"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: root.close()
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    width: Math.min(implicitWidth, root.width - 360)
                    text: Plain.title
                    color: root.ink
                    elide: Text.ElideMiddle
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeHeading
                    font.weight: Font.DemiBold
                }

                Text {
                    text: {
                        const parts = []
                        if (Plain.encodingName.length > 0)
                            parts.push(Plain.encodingName)
                        parts.push(root.sizeLabel)
                        parts.push("纯文本")
                        return parts.join(" · ")
                    }
                    color: root.inkSoft
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeSmall
                }
            }
        }

        Row {
            anchors {
                right: parent.right
                rightMargin: AppTheme.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: AppTheme.spacingXs

            ReaderButton {
                icon: "search"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: root.findOpen ? root.closeFind() : root.openFind()
            }

            ReaderButton {
                icon: "book-open"
                label: "章节阅读"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: root.openAsNovel()
            }
        }

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 1
            color: root.rule
        }
    }

    // ---------------- 查找栏 ----------------
    Rectangle {
        id: findBar
        visible: root.findOpen
        anchors {
            top: topBar.bottom
            right: parent.right
            rightMargin: AppTheme.spacingXl
            topMargin: AppTheme.spacingSm
        }
        width: 340
        height: 44
        radius: AppTheme.radiusCard
        color: root.sheetFill
        border.width: AppTheme.borderWidth
        border.color: root.rule

        Row {
            anchors {
                fill: parent
                leftMargin: AppTheme.spacingMd
                rightMargin: AppTheme.spacingSm
            }
            spacing: AppTheme.spacingXs

            C.TextField {
                id: findField
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 96
                height: 30
                placeholderText: "在全文里查找…"
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: root.ink
                placeholderTextColor: root.inkSoft
                background: null
                selectByMouse: true
                onAccepted: root.runFind()
                Keys.onEscapePressed: root.closeFind()
                Keys.onDownPressed: root.runFind()
            }

            ReaderButton {
                anchors.verticalCenter: parent.verticalCenter
                icon: "chevron-down"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: root.runFind()
            }

            ReaderButton {
                anchors.verticalCenter: parent.verticalCenter
                icon: "x"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: root.closeFind()
            }
        }
    }

    // 查找提示：查找中 / 未找到
    Text {
        anchors {
            top: findBar.bottom
            right: findBar.right
            rightMargin: AppTheme.spacingSm
            topMargin: AppTheme.spacingXs
        }
        visible: root.findOpen && (Plain.searching || root.findStatus.length > 0)
        text: Plain.searching
            ? "查找中…（已读 " + Math.round(Plain.percent * 100) + "%）"
            : root.findStatus
        color: root.inkSoft
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeSmall
    }

    // ---------------- 正文 ----------------
    ListView {
        id: list
        anchors {
            top: topBar.bottom
            left: parent.left
            right: parent.right
            bottom: statusBar.top
        }
        clip: true
        model: Plain
        topMargin: AppTheme.spacingLg
        bottomMargin: AppTheme.spacingXl
        // 一屏之外再多留两屏：上下轻扫时不必等读块回来
        cacheBuffer: Math.max(400, height * 2)
        boundsBehavior: Flickable.StopAtBounds
        visible: !Plain.loading && Plain.errorText.length === 0
        focus: root.visible

        C.ScrollBar.vertical: C.ScrollBar {
            policy: C.ScrollBar.AsNeeded
        }

        delegate: C.TextArea {
            id: block
            required property string text
            required property int index

            readonly property bool isHit: Plain.hitRow === index
            /// 命中块换成高亮富文本；其余块保持纯文本（省排版开销）
            readonly property string rich: block.isHit ? Plain.highlighted(index) : ""

            x: Math.max(AppTheme.spacingXl, (list.width - width) / 2)
            width: Math.min(root.columnWidth, list.width - 2 * AppTheme.spacingXl)
            text: block.rich.length > 0 ? block.rich : block.text
            textFormat: block.rich.length > 0 ? TextEdit.RichText : TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            selectByKeyboard: true
            wrapMode: TextEdit.Wrap
            color: root.ink
            selectionColor: AppTheme.colors.primary
            selectedTextColor: AppTheme.colors.textOnPrimary
            font.family: AppTheme.fontFamily
            font.pixelSize: 16
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            background: null
        }
    }

    // 打开中 / 出错 / 空文件
    Column {
        anchors.centerIn: parent
        width: Math.min(420, root.width - 2 * AppTheme.spacingXl)
        spacing: AppTheme.spacingMd
        visible: !list.visible || (Plain.active && list.count === 0 && !Plain.loading
                                   && Plain.errorText.length === 0)

        // 首次打开时按已读字节转一圈：网盘上几十 MB 的 txt 也需要一个「在动」的反馈
        ProgressRing {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 34
            height: 34
            visible: Plain.loading
            progress: Plain.percent
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Plain.errorText.length > 0
                ? Plain.errorText
                : Plain.loading
                    ? "正在打开…"
                    : (Plain.active ? "这个文件是空的" : "")
            color: root.ink
            wrapMode: Text.Wrap
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
        }

        C.Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: Plain.errorText.length > 0
            text: "返回"
            onClicked: root.close()
        }
    }

    // ---------------- 底栏 ----------------
    Item {
        id: statusBar
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 34

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: 1
            color: root.rule
        }

        Text {
            anchors {
                left: parent.left
                leftMargin: AppTheme.spacingXl
                verticalCenter: parent.verticalCenter
            }
            text: Plain.atEnd
                ? "已全部载入 · 共 " + root.sizeLabel
                : "已载入 " + Math.round(Plain.percent * 100) + "% · 继续下拉加载"
            color: root.inkSoft
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
        }

        Text {
            anchors {
                right: parent.right
                rightMargin: AppTheme.spacingXl
                verticalCenter: parent.verticalCenter
            }
            text: "不记进度 · 选中后可 Ctrl+C 复制"
            color: root.inkSoft
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
        }
    }

    // ---------------- 键盘 ----------------
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            if (root.findOpen) {
                root.closeFind()
            } else {
                root.close()
            }
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
            root.openFind()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_F3) {
            if (Plain.findText.length > 0)
                Plain.findNext()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_PageDown) {
            list.contentY = Math.min(list.contentY + list.height * 0.9,
                                     Math.max(0, list.contentHeight - list.height))
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_PageUp) {
            list.contentY = Math.max(0, list.contentY - list.height * 0.9)
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Home && (event.modifiers & Qt.ControlModifier)) {
            list.positionViewAtBeginning()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_End && (event.modifiers & Qt.ControlModifier)) {
            list.positionViewAtEnd()
            event.accepted = true
        }
    }

    Connections {
        target: Plain

        function onFound(row) {
            root.findStatus = ""
            list.positionViewAtIndex(row, ListView.Beginning)
        }

        function onFindFinished(found) {
            if (!found)
                root.findStatus = "未找到「" + Plain.findText + "」，可继续往下滚再试"
        }

        // 换了一本书：回到顶部，别把上一本的滚动位置带过来
        function onBookChanged() {
            root.findStatus = ""
            list.positionViewAtBeginning()
        }
    }
}
