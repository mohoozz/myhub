import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

pragma ComponentBehavior: Bound

/*
  正在阅读（PC-209 / PC-705）。

  顶部操作栏：标题 + 刷新 + 视图切换 + ⋯
  内容区：网格 / 列表 + 空态

  纪律：
    - 列表按「最近阅读」倒序，已读完的记录保留在列表里，直到用户手动删除（§3.2）
    - 首页不吃搜索/排序，保持一屏可见即可用
    - 播放中进度每 5s 落盘一次，只就地更新对应那行，不重整列表（避免列表跳动）
*/
Item {
    id: root

    ReadingHomeModel {
        id: readingModel
    }

    readonly property bool gridMode: AppSettings.viewMode === "grid"

    function onEntered() {
        // 重新进入模块时整体重排一次，恢复「最近优先」
        readingModel.refresh()
        selectionModel.clear()
    }

    // ---------------- 顶部操作栏 ----------------
    Item {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: AppTheme.toolbarHeight

        Text {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.right: actionRow.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("正在阅读")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: AppTheme.colors.textPrimary
            elide: Text.ElideRight
        }

        Row {
            id: actionRow
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ToolbarButton {
                iconName: "refresh"
                tooltip: qsTr("刷新 (F5)")
                onClicked: readingModel.refresh()
            }
            ToolbarButton {
                iconName: root.gridMode ? "list" : "grid"
                tooltip: root.gridMode ? qsTr("切换为列表视图") : qsTr("切换为网格视图")
                onClicked: AppSettings.viewMode = root.gridMode ? "list" : "grid"
            }
            ToolbarButton {
                iconName: "more-horizontal"
                tooltip: qsTr("更多")
                onClicked: {
                    const pos = mapToGlobal(width / 2, height)
                    moreMenu.popupAt(pos.x, pos.y)
                }
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: AppTheme.borderWidth
            color: AppTheme.colors.cardBorder
        }
    }

    // ---------------- 内容区 ----------------
    Item {
        id: contentArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: toolbar.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: AppTheme.spacingXs

        // 网格视图
        GridView {
            id: gridView
            anchors.fill: parent
            anchors.leftMargin: AppTheme.spacingLg
            anchors.rightMargin: AppTheme.spacingLg
            visible: root.gridMode && readingModel.state === ReadingHomeModel.Ready
            clip: true
            model: readingModel
            cacheBuffer: 400

            readonly property int nameLines: Math.min(AppSettings.fileNameLines, 3)
            readonly property real coverHeight: (cellWidth - AppTheme.spacingSm * 2) / 1.3

            cellWidth: Math.floor(width / Math.max(2, Math.floor(width / 150)))
            // 封面 + 固定区块（98）+ 标题 nameLines 行
            cellHeight: coverHeight + 98 + nameLines * 14

            delegate: ReadingGridCell {
                id: gridCell

                required property int index
                required property string title
                required property string mediaKind
                required property string kindText
                required property real percent
                required property string percentText
                required property bool finished
                required property string finishedText
                required property string relativeTime
                required property string connectionId
                required property string filePath

                width: gridView.cellWidth
                height: gridView.cellHeight
                entryTitle: gridCell.title
                entryMediaKind: gridCell.mediaKind
                entryKindText: gridCell.kindText
                entryPercent: gridCell.percent
                entryPercentText: gridCell.percentText
                entryFinished: gridCell.finished
                entryFinishedText: gridCell.finishedText
                entryRelativeTime: gridCell.relativeTime
                entryConnectionId: gridCell.connectionId
                entryPath: gridCell.filePath
                nameLines: gridView.nameLines
                selected: selectionModel.isSelected(gridCell.index)

                onClicked: function(mouse) { selectionModel.handleClick(gridCell.index, mouse) }
                onDoubleClicked: root.openItem(gridCell.index)
                onRightClicked: function(gx, gy) {
                    selectionModel.ensureSelected(gridCell.index)
                    contextMenu.targetIndex = gridCell.index
                    contextMenu.popupAt(gx, gy)
                }
            }
        }

        // 列表视图
        ListView {
            id: listView
            anchors.fill: parent
            anchors.leftMargin: AppTheme.spacingLg
            anchors.rightMargin: AppTheme.spacingLg
            visible: !root.gridMode && readingModel.state === ReadingHomeModel.Ready
            clip: true
            model: readingModel
            cacheBuffer: 400
            spacing: 0

            delegate: ReadingListRow {
                id: listRow

                required property int index
                required property string title
                required property string mediaKind
                required property string kindText
                required property real percent
                required property string percentText
                required property bool finished
                required property string finishedText
                required property string relativeTime
                required property string connectionId
                required property string filePath

                width: listView.width
                entryTitle: listRow.title
                entryMediaKind: listRow.mediaKind
                entryKindText: listRow.kindText
                entryPercent: listRow.percent
                entryPercentText: listRow.percentText
                entryFinished: listRow.finished
                entryFinishedText: listRow.finishedText
                entryRelativeTime: listRow.relativeTime
                entryConnectionId: listRow.connectionId
                entryPath: listRow.filePath
                selected: selectionModel.isSelected(listRow.index)

                onClicked: function(mouse) { selectionModel.handleClick(listRow.index, mouse) }
                onDoubleClicked: root.openItem(listRow.index)
                onRightClicked: function(gx, gy) {
                    selectionModel.ensureSelected(listRow.index)
                    contextMenu.targetIndex = listRow.index
                    contextMenu.popupAt(gx, gy)
                }
            }
        }

        EmptyState {
            anchors.fill: parent
            visible: readingModel.state === ReadingHomeModel.Empty
            iconName: "book"
            title: qsTr("还没有阅读记录")
            description: qsTr("打开视频、音频或书籍后，进度会自动记录在这里，下次直接接着看。")
            actionText: qsTr("去浏览")
            onActionTriggered: AppRouter.select(AppRouter.Browse)
        }
    }

    // ---------------- 选择模型 ----------------
    QtObject {
        id: selectionModel

        property var selected: ({})
        property int anchorIndex: -1
        property int revision: 0

        readonly property int count: {
            revision
            return Object.keys(selected).length
        }

        function isSelected(index) {
            revision
            return selected[index] === true
        }

        function clear() {
            selected = ({})
            revision++
        }

        function ensureSelected(index) {
            if (!isSelected(index)) {
                clear()
                selected[index] = true
                anchorIndex = index
                revision++
            }
        }

        function handleClick(index, mouse) {
            if (mouse.modifiers & Qt.ControlModifier) {
                if (selected[index])
                    delete selected[index]
                else
                    selected[index] = true
                anchorIndex = index
            } else if ((mouse.modifiers & Qt.ShiftModifier) && anchorIndex >= 0) {
                selected = ({})
                const from = Math.min(anchorIndex, index)
                const to = Math.max(anchorIndex, index)
                for (let i = from; i <= to; ++i)
                    selected[i] = true
            } else {
                selected = ({})
                selected[index] = true
                anchorIndex = index
                if (AppSettings.openOnSingleClick)
                    root.openItem(index)
            }
            revision++
        }

        function selectAll() {
            selected = ({})
            for (let i = 0; i < readingModel.count; ++i)
                selected[i] = true
            revision++
        }

        function indexes() {
            return Object.keys(selected).map(function(key) { return Number(key) })
        }
    }

    // 列表被重建 / 记录被删后，越界的选择项要清掉
    Connections {
        target: readingModel
        function onCountChanged() {
            if (selectionModel.count === 0)
                return
            const valid = {}
            const rows = selectionModel.indexes()
            for (let i = 0; i < rows.length; ++i) {
                if (rows[i] < readingModel.count)
                    valid[rows[i]] = true
            }
            selectionModel.selected = valid
            selectionModel.revision++
        }
    }

    // 进入模块 / 重复点击导航项时的行为
    Connections {
        target: AppRouter
        function onCurrentModuleChanged() {
            if (AppRouter.currentModule === AppRouter.Reading)
                root.onEntered()
        }
        function onReselected(m) {
            if (m === AppRouter.Reading) {
                root.onEntered()
                gridView.positionViewAtBeginning()
                listView.positionViewAtBeginning()
            }
        }
    }

    // ---------------- 菜单 ----------------
    PopupMenu {
        id: moreMenu

        C.Action {
            text: qsTr("全选")
            enabled: readingModel.count > 0
            onTriggered: selectionModel.selectAll()
        }
        C.Action {
            text: qsTr("刷新")
            onTriggered: readingModel.refresh()
        }
        C.MenuSeparator {}
        C.Action {
            text: selectionModel.count > 0
                ? qsTr("删除选中的 %1 项记录").arg(selectionModel.count)
                : qsTr("删除阅读记录")
            enabled: selectionModel.count > 0
            onTriggered: root.requestDelete(selectionModel.indexes())
        }
    }

    // 右键上下文菜单（「多选」置于首位，§14.4）
    PopupMenu {
        id: contextMenu
        property int targetIndex: -1

        C.Action {
            text: qsTr("多选")
            onTriggered: selectionModel.ensureSelected(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: root.openActionText(contextMenu.targetIndex)
            onTriggered: root.openItem(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("在浏览页中定位")
            onTriggered: root.revealItem(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("属性")
            onTriggered: propertiesDialog.showFor(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("删除记录")
            onTriggered: root.requestDelete([contextMenu.targetIndex])
        }
    }

    // ---------------- 属性面板（PC-110，与浏览页同一份实现）----------------
    FilePropertiesDialog {
        id: propertiesDialog
        onRevealRequested: function(connId, path, isDir) {
            BrowseController.reveal(connId, path, isDir)
        }

        function showFor(index) {
            const info = readingModel.get(index)
            if (!info || Object.keys(info).length === 0)
                return
            openFor(info.connectionId, info.filePath)
        }
    }

    // ---------------- 删除确认 ----------------
    ConfirmDialog {
        id: deleteDialog
        title: qsTr("删除阅读记录？")
        message: qsTr("将从「正在阅读」移除所选记录，不会删除源文件，也不影响其在浏览页中的显示。")
        confirmText: qsTr("删除")
        cancelText: qsTr("取消")
        destructive: true

        property var pendingRows: []

        onAccepted: {
            readingModel.removeRows(pendingRows)
            pendingRows = []
            selectionModel.clear()
        }
        onRejected: pendingRows = []
    }

    function requestDelete(rows) {
        const valid = (rows || []).filter(function(row) {
            return row >= 0 && row < readingModel.count
        })
        if (valid.length === 0)
            return
        deleteDialog.pendingRows = valid
        deleteDialog.open()
    }

    // ---------------- 定位到原路径（PC-109）----------------
    function revealItem(index) {
        const info = readingModel.get(index)
        if (!info || Object.keys(info).length === 0)
            return
        if (!info.connectionAvailable) {
            unsupportedDialog.title = qsTr("连接源已删除")
            unsupportedDialog.message = qsTr("「%1」所属的连接源已被删除，无法定位。").arg(info.title)
            unsupportedDialog.open()
            return
        }
        BrowseController.reveal(info.connectionId, info.filePath, false)
    }

    // ---------------- 打开条目 ----------------
    function openActionText(index) {
        const info = readingModel.get(index)
        if (!info || Object.keys(info).length === 0)
            return qsTr("继续")
        return (info.mediaKind === "video" || info.mediaKind === "audio")
            ? qsTr("继续播放")
            : qsTr("继续阅读")
    }

    function openItem(index) {
        const info = readingModel.get(index)
        if (!info || Object.keys(info).length === 0)
            return

        if (!info.connectionAvailable) {
            unsupportedDialog.title = qsTr("连接源已删除")
            unsupportedDialog.message = qsTr("「%1」所属的连接源已被删除，无法再打开。\n可删除这条阅读记录后重新添加连接源。").arg(info.title)
            unsupportedDialog.open()
            return
        }

        if (info.mediaKind === "video" || info.mediaKind === "audio") {
            if (info.connectionLocal) {
                // startMs 传 -1：由 C++ 侧查进度表决定续播点（PC-209）
                Player.openLocalFile(info.filePath, info.title, -1, info.connectionId)
                return
            }
            // 远程源：走回环代流（§4.2 边下边播），尺寸/指纹由 C++ 侧补 stat
            Player.openRemote(info.connectionId, info.filePath, info.title, 0, "", -1)
            return
        }

        // 阅读器（M3）尚未接入
        unsupportedDialog.title = qsTr("暂未实现")
        unsupportedDialog.message = qsTr("「%1」的阅读器将在后续里程碑实现。\n\n类型：%2").arg(info.title).arg(info.kindText)
        unsupportedDialog.open()
    }

    // 远程起播失败：文案由 C++ 给具体原因
    Connections {
        target: Player
        function onRemoteOpenFailed(reason) {
            unsupportedDialog.title = qsTr("无法播放")
            unsupportedDialog.message = reason
            unsupportedDialog.open()
        }
    }

    ConfirmDialog {
        id: unsupportedDialog
        title: qsTr("暂未实现")
        confirmText: qsTr("知道了")
        cancelText: ""
    }

    // ---------------- 快捷键 ----------------
    focus: visible
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_F5
            || (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier))) {
            readingModel.refresh()
            event.accepted = true
        } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
            selectionModel.selectAll()
            event.accepted = true
        } else if (event.key === Qt.Key_Delete && selectionModel.count > 0) {
            requestDelete(selectionModel.indexes())
            event.accepted = true
        } else if (event.key === Qt.Key_Escape && selectionModel.count > 0) {
            selectionModel.clear()
            event.accepted = true
        }
    }
}
