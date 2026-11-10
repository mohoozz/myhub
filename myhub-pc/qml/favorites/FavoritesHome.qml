import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

pragma ComponentBehavior: Bound

/*
  收藏（PC-107）。

  顶部操作栏：标题 + 计数 + 刷新 + 视图切换
  内容区：网格 / 列表 + 空态

  纪律：
    - 数据源只有 `favorite` 表：浏览页点星 / 这里取消收藏 / 源文件被删或改名，都会即时反映
      （`FavoriteListModel` 监听仓库信号就地增删，不靠全量刷新）
    - 封面与浏览页同一套：`CoverImage` 按 (connectionId, filePath) 取缓存，不另存副本
    - 目录双击跳浏览页定位；影音双击进播放器；阅读器（M3）接入前，其余类型统一「去浏览页」
    - 连接源被删除的收藏**保留但不静默丢**：打开时明确提示
*/
Item {
    id: root

    FavoriteListModel {
        id: favoriteModel
    }

    readonly property bool gridMode: AppSettings.viewMode === "grid"

    function onEntered() {
        favoriteModel.refresh()
        // 行可能被别处（浏览页取消收藏 / 源文件删除）摘掉，旧的目标索引不再有意义
        contextMenu.targetIndex = -1
    }

    // ---------------- 路径工具 ----------------
    /// 跳浏览页并定位到该条目（PC-109）：滚动居中 + 呼吸灯高亮
    function locate(info) {
        BrowseController.reveal(info.connectionId, info.filePath, info.isDir)
    }

    /// 取消收藏（行由模型信号摘除，无需手动重建）
    function removeFavorite(row) {
        favoriteModel.removeAt(row)
    }

    // ---------------- 打开条目 ----------------
    function openItem(row) {
        const info = favoriteModel.get(row)
        if (!info || Object.keys(info).length === 0)
            return

        if (!info.connectionAvailable) {
            unsupportedDialog.title = qsTr("连接源已删除")
            unsupportedDialog.message = qsTr("「%1」所属的连接源已被删除，无法再打开。\n可取消收藏后重新添加连接源。").arg(info.name)
            unsupportedDialog.open()
            return
        }

        if (info.isDir) {
            locate(info)
            return
        }

        if (info.mediaKind === "video" || info.mediaKind === "audio") {
            if (info.connectionLocal) {
                // startMs 传 -1：由 C++ 侧查进度表决定续播点（PC-209）
                Player.openLocalFile(info.filePath, info.name, -1, info.connectionId)
                return
            }
            // 远程源：走回环代流（§4.2 边下边播）。收藏表没有 size/fingerprint，
            // 由 C++ 侧补一次 stat 再起播
            Player.openRemote(info.connectionId, info.filePath, info.name, 0, "", -1)
            return
        }

        // 阅读器 / 查看器（M3）接入前：统一去浏览页定位，先把「找得到」做扎实
        locate(info)
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
            text: Favorites.count > 0
                ? qsTr("收藏 · %1").arg(Favorites.count)
                : qsTr("收藏")
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
                onClicked: favoriteModel.refresh()
            }
            ToolbarButton {
                iconName: root.gridMode ? "list" : "grid"
                tooltip: root.gridMode ? qsTr("切换为列表视图") : qsTr("切换为网格视图")
                onClicked: AppSettings.viewMode = root.gridMode ? "list" : "grid"
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
            visible: root.gridMode && favoriteModel.count > 0
            clip: true
            model: favoriteModel
            cacheBuffer: 400

            readonly property real coverHeight: (cellWidth - AppTheme.spacingSm * 2) * 0.72

            cellWidth: Math.floor(width / Math.max(2, Math.floor(width / 150)))
            cellHeight: coverHeight + 76

            delegate: Item {
                id: gridCell

                required property int index
                required property string name
                required property string mediaKind
                required property string mediaKindText
                required property string connectionName
                required property bool connectionAvailable
                required property string connectionId
                required property string filePath
                required property bool isDir
                required property string createdAtText

                width: gridView.cellWidth
                height: gridView.cellHeight

                CellPressHighlight {
                    anchors.fill: parent
                    hovered: gridMouse.containsMouse
                    selected: contextMenu.targetIndex === gridCell.index
                    pressed: gridMouse.pressed
                    inset: 2
                    radius: AppTheme.radiusCard
                }

                Column {
                    anchors.fill: parent
                    anchors.margins: AppTheme.spacingSm
                    spacing: AppTheme.spacingSm

                    Item {
                        width: parent.width
                        height: gridView.coverHeight - AppTheme.spacingSm * 2

                        CoverImage {
                            anchors.fill: parent
                            connectionId: gridCell.connectionId
                            filePath: gridCell.filePath
                            mediaKind: gridCell.mediaKind
                            isDir: gridCell.isDir
                            radius: AppTheme.radiusInput
                            iconRatio: 0.6
                        }

                        AppIcon {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.margins: 3
                            width: 15
                            height: 15
                            name: "star"
                            color: AppTheme.colors.star
                            filled: true
                        }
                    }

                    Text {
                        width: parent.width
                        text: gridCell.name
                        horizontalAlignment: Text.AlignHCenter
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeSmall
                        color: AppTheme.colors.textPrimary
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 1.2
                    }

                    // 来源 + 收藏时间：一行放不下就省略，不换行（§14.3 同类纪律）
                    Text {
                        width: parent.width
                        text: gridCell.connectionAvailable
                            ? qsTr("%1 · %2").arg(gridCell.connectionName).arg(gridCell.createdAtText)
                            : qsTr("（连接源已删除）")
                        horizontalAlignment: Text.AlignHCenter
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: gridCell.connectionAvailable
                            ? AppTheme.colors.textSecondary
                            : AppTheme.colors.danger
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: gridMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouseEvent) {
                        if (mouseEvent.button === Qt.RightButton) {
                            const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
                            contextMenu.targetIndex = gridCell.index
                            contextMenu.popupAt(global.x, global.y)
                        }
                    }
                    onDoubleClicked: root.openItem(gridCell.index)
                }
            }
        }

        // 列表视图
        ListView {
            id: listView
            anchors.fill: parent
            anchors.leftMargin: AppTheme.spacingLg
            anchors.rightMargin: AppTheme.spacingLg
            visible: !root.gridMode && favoriteModel.count > 0
            clip: true
            model: favoriteModel
            cacheBuffer: 400
            spacing: 0

            delegate: Item {
                id: listRow

                required property int index
                required property string name
                required property string mediaKind
                required property string mediaKindText
                required property string connectionName
                required property bool connectionAvailable
                required property string connectionId
                required property string filePath
                required property bool isDir
                required property string createdAtText

                width: listView.width
                height: 52

                CellPressHighlight {
                    anchors.fill: parent
                    hovered: listMouse.containsMouse
                    selected: contextMenu.targetIndex === listRow.index
                    pressed: listMouse.pressed
                    inset: 3
                    radius: AppTheme.radiusInput + 2
                }

                Item {
                    anchors.fill: parent
                    anchors.leftMargin: AppTheme.spacingMd
                    anchors.rightMargin: AppTheme.spacingMd

                    CoverImage {
                        id: rowCover
                        width: 30
                        height: 30
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        connectionId: listRow.connectionId
                        filePath: listRow.filePath
                        mediaKind: listRow.mediaKind
                        isDir: listRow.isDir
                        radius: AppTheme.radiusSmall
                        cropFill: false
                        iconRatio: 0.9
                    }

                    Text {
                        anchors.left: rowCover.right
                        anchors.leftMargin: AppTheme.spacingMd
                        anchors.right: rowMeta.left
                        anchors.rightMargin: AppTheme.spacingMd
                        anchors.verticalCenter: parent.verticalCenter
                        text: listRow.name
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    Row {
                        id: rowMeta
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingLg

                        AppIcon {
                            width: 14
                            height: 14
                            anchors.verticalCenter: parent.verticalCenter
                            name: "star"
                            color: AppTheme.colors.star
                            filled: true
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: listRow.mediaKindText
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeSmall
                            color: AppTheme.colors.textFaint
                            width: 56
                            horizontalAlignment: Text.AlignRight
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: listRow.connectionAvailable
                                ? qsTr("%1 · %2").arg(listRow.connectionName).arg(listRow.createdAtText)
                                : qsTr("（连接源已删除）")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeSmall
                            color: listRow.connectionAvailable
                                ? AppTheme.colors.textSecondary
                                : AppTheme.colors.danger
                            width: 220
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }
                }

                MouseArea {
                    id: listMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouseEvent) {
                        if (mouseEvent.button === Qt.RightButton) {
                            const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
                            contextMenu.targetIndex = listRow.index
                            contextMenu.popupAt(global.x, global.y)
                        }
                    }
                    onDoubleClicked: root.openItem(listRow.index)
                }
            }
        }

        EmptyState {
            anchors.fill: parent
            visible: favoriteModel.count === 0
            iconName: "star"
            title: qsTr("还没有收藏")
            description: qsTr("在浏览页右键文件或文件夹选择「收藏」，它们会集中出现在这里，随时接着用。")
            actionText: qsTr("去浏览")
            onActionTriggered: AppRouter.select(AppRouter.Browse)
        }
    }

    // ---------------- 右键菜单 ----------------
    PopupMenu {
        id: contextMenu
        property int targetIndex: -1

        /// 右键目标是否可打开（连接源已删的条目只能取消收藏）
        readonly property var targetInfo: {
            favoriteModel.count
            return targetIndex >= 0 ? favoriteModel.get(targetIndex) : ({})
        }
        readonly property bool targetAvailable: {
            const info = targetInfo
            return !!info && Object.keys(info).length > 0 && info.connectionAvailable
        }
        readonly property bool targetIsDir: {
            const info = targetInfo
            return !!info && info.isDir === true
        }
        readonly property bool targetPlayable: {
            const info = targetInfo
            return !!info && (info.mediaKind === "video" || info.mediaKind === "audio")
        }

        C.Action {
            text: contextMenu.targetIsDir ? qsTr("打开")
                : (contextMenu.targetPlayable ? qsTr("播放") : qsTr("打开"))
            enabled: contextMenu.targetAvailable
            onTriggered: root.openItem(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("在浏览页中定位")
            enabled: contextMenu.targetAvailable
            onTriggered: {
                const info = contextMenu.targetInfo
                if (info && Object.keys(info).length > 0)
                    root.locate(info)
            }
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("取消收藏")
            enabled: contextMenu.targetIndex >= 0
            onTriggered: root.removeFavorite(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("属性")
            enabled: contextMenu.targetIndex >= 0
            onTriggered: propertiesDialog.showFor(contextMenu.targetIndex)
        }
    }

    // ---------------- 属性面板（PC-110，与浏览页同一份实现）----------------
    FilePropertiesDialog {
        id: propertiesDialog
        onRevealRequested: function(connId, path, isDir) {
            BrowseController.reveal(connId, path, isDir)
        }

        function showFor(row) {
            const info = favoriteModel.get(row)
            if (!info || Object.keys(info).length === 0)
                return
            openFor(info.connectionId, info.filePath)
        }
    }

    ConfirmDialog {
        id: unsupportedDialog
        title: qsTr("暂未实现")
        confirmText: qsTr("知道了")
        cancelText: ""
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

    // 进入模块 / 重复点击导航项
    Connections {
        target: AppRouter
        function onCurrentModuleChanged() {
            if (AppRouter.currentModule === AppRouter.Favorites)
                root.onEntered()
        }
        function onReselected(module) {
            if (module === AppRouter.Favorites) {
                root.onEntered()
                gridView.positionViewAtBeginning()
                listView.positionViewAtBeginning()
            }
        }
    }

    // ---------------- 快捷键 ----------------
    focus: visible
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_F5
            || (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier))) {
            favoriteModel.refresh()
            event.accepted = true
        }
    }
}
