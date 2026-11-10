import QtQuick
import QtQuick.Controls.Basic as C
import QtQuick.Dialogs
import MyHub

// 委托里要访问外层 id（gridView / selectionModel / contextMenu / root）。
// Qt 6.5 起推荐用 Bound 绑定组件上下文，否则 qmllint 会报 unqualified access，
// 而且外部组件被误用时会产生隐式上下文依赖。
pragma ComponentBehavior: Bound

/*
  目录页（§3.1 PC-102）。

  顶部操作栏：当前目录名（根目录显示连接名）+ 返回 + 刷新 + 视图切换 + 排序 + ⋯
  内容区：网格 / 列表视图 + 搜索框（仅顶部显示）+ 四态

  纪律：
    - **移除面包屑**，改由顶部操作栏显示当前目录名（§14.5）
    - 刷新失败保留旧内容并给轻提示（§14.10）
    - 文件名行数设置即时生效（§14.3）
*/
Item {
    id: root

    property string connectionId: ""

    function navigateTo(connId, path) {
        if (connId && dirModel.connectionId !== connId)
            dirModel.connectionId = connId
        dirModel.navigateTo(path && path !== "" ? path : "/")
    }

    // ---------------- 定位到原路径（PC-109）----------------
    /// 待定位的目标路径（非空表示这一轮定位还没收尾）
    property string revealPath: ""
    /// 呼吸灯是否亮着
    property bool revealActive: false
    /// 待办请求（目录分阶段加载完成后再试）
    property var pendingReveal: null
    property int revealRetries: 0

    /// 页面内直接定位（属性面板的「定位」按钮）
    function requestReveal(connId, path, isDir) {
        BrowseController.reveal(connId, path, isDir)
    }

    function applyReveal(request) {
        if (!request || !request.filePath)
            return
        // 搜索会把目标行过滤掉：定位前先清空，否则「定位成功但看不见」
        if (dirModel.searchText !== "")
            dirModel.searchText = ""
        pendingReveal = request
        revealRetries = 0
        if (dirModel.connectionId !== request.connectionId || dirModel.path !== request.dirPath)
            navigateTo(request.connectionId, request.dirPath)
        tryReveal()
    }

    /**
     * 尝试完成定位：目录未就绪则等状态信号，行还没到齐则短延迟重试。
     * 最多重试 6 次（约 1.2s）后放弃并给出轻提示，不无限空转。
     */
    function tryReveal() {
        const request = pendingReveal
        if (!request || request.filePath === "")
            return
        if (dirModel.connectionId !== request.connectionId || dirModel.path !== request.dirPath)
            return
        if (dirModel.state === BrowseDirectoryModel.Loading)
            return // 等 stateChanged / revisionChanged
        if (dirModel.state === BrowseDirectoryModel.Error) {
            finishReveal(false)
            return
        }

        const index = dirModel.indexOfPath(request.filePath)
        if (index < 0) {
            if (revealRetries < 6) {
                ++revealRetries
                revealRetryTimer.restart()
            } else {
                finishReveal(false)
            }
            return
        }

        revealRetries = 0
        revealPath = request.filePath
        revealActive = true
        if (root.gridMode)
            gridView.positionViewAtIndex(index, GridView.Center)
        else
            listView.positionViewAtIndex(index, ListView.Center)
        pendingReveal = null
        BrowseController.clearReveal()
        revealIdleTimer.restart()
    }

    function finishReveal(found) {
        pendingReveal = null
        BrowseController.clearReveal()
        if (!found) {
            revealPath = ""
            revealActive = false
            dirModel.notify(qsTr("目标不在当前目录，可能已被移动或删除"))
        }
    }

    /// 用户自己走开：静默放弃这一轮定位（不弹「目标不在」的提示）
    function cancelReveal() {
        pendingReveal = null
        BrowseController.clearReveal()
        revealPath = ""
        revealActive = false
    }

    Timer {
        id: revealRetryTimer
        interval: 200
        onTriggered: root.tryReveal()
    }

    // 呼吸灯亮 10s 后熄灭（§PC-109）
    Timer {
        id: revealIdleTimer
        interval: 10000
        onTriggered: {
            root.revealActive = false
            root.revealPath = ""
        }
    }

    Connections {
        target: BrowseController
        function onRevealChanged() {
            const request = BrowseController.revealRequest
            if (!request || !request.filePath) {
                root.pendingReveal = null
                return
            }
            AppRouter.select(AppRouter.Browse)
            root.applyReveal(request)
        }
    }

    Connections {
        target: dirModel
        function onStateChanged() {
            root.tryReveal()
        }
        function onRevisionChanged() {
            root.tryReveal()
        }
        function onPathChanged() {
            // 用户自己走开了：静默放弃这一轮定位并熄灭呼吸灯
            if (root.pendingReveal && root.pendingReveal.dirPath !== dirModel.path)
                root.cancelReveal()
            root.revealActive = false
            root.revealPath = ""
        }
    }

    // 连接源用命令式同步（不用绑定）：navigateTo/定位会显式写 dirModel.connectionId，
    // 绑定一旦被 JS 赋值打断就不会再跟随，切连接源时页面会卡在上一个源
    onConnectionIdChanged: {
        if (dirModel.connectionId !== connectionId)
            dirModel.connectionId = connectionId
    }

    Component.onCompleted: {
        if (dirModel.connectionId !== connectionId)
            dirModel.connectionId = connectionId
    }

    BrowseDirectoryModel {
        id: dirModel

        // 记住当前路径，下次进入该连接源时恢复（§3.1）
        onPathChanged: BrowseController.rememberPath(root.connectionId, path)
    }

    readonly property bool gridMode: AppSettings.viewMode === "grid"

    // ---- 文件操作状态（§3.2）----
    /// 待删除的路径：ConfirmDialog 没有自定义属性，暂存在页面上
    property var pendingPaths: []
    /// 输入框当前用途：create / rename
    property string inputMode: ""
    /// 重命名目标（单条）
    property var renameTarget: null
    /// 待「以纯文本查看」的条目快照：菜单打开期间列表可能刷新，按下标重取会错位
    property var previewItem: null

    /// 当前多选中的条目（含 filePath / name / isDir 等，供批量操作使用）
    /// 必须同时依赖 dirModel.revision：行数据被就地改写（改名等）时
    /// get() 不是可追踪的属性读取，只靠 selectionModel.revision 会一直拿到旧快照。
    readonly property var selectedItems: {
        selectionModel.revision
        dirModel.revision
        const items = []
        const keys = Object.keys(selectionModel.selected)
        for (let i = 0; i < keys.length; ++i) {
            const info = dirModel.get(parseInt(keys[i], 10))
            if (info && Object.keys(info).length > 0)
                items.push(info)
        }
        return items
    }

    /// 选中项是否全部为文件（下载不支持文件夹，见 TransferManager）
    readonly property bool selectionDownloadable: {
        const items = root.selectedItems
        if (items.length === 0)
            return false
        for (let i = 0; i < items.length; ++i) {
            if (items[i].isDir)
                return false
        }
        return true
    }

    /// 选中项是否**全部**已收藏：决定按钮写「收藏」还是「取消收藏」。
    /// 混合态按「收藏」处理（补齐未收藏的那些），不做成逐条 toggle
    readonly property bool selectionAllFavorited: {
        Favorites.revision
        const items = root.selectedItems
        if (items.length === 0)
            return false
        for (let i = 0; i < items.length; ++i) {
            if (!Favorites.isFavorite(dirModel.connectionId, items[i].filePath))
                return false
        }
        return true
    }

    /// 多选栏放不下时收成图标（窗口窄到 640 也要保证「按钮不超出窗口」）
    readonly property bool compactBar: root.width < 820

    /// 批量收藏 / 取消收藏
    function toggleSelectionFavorite() {
        const items = root.selectedItems
        if (items.length === 0)
            return
        const remove = root.selectionAllFavorited
        for (let i = 0; i < items.length; ++i) {
            const info = items[i]
            const favored = Favorites.isFavorite(dirModel.connectionId, info.filePath)
            // 只在「方向与现状不一致」时切换，避免混合态下把已收藏的也翻掉
            if (remove === favored)
                Favorites.toggle(dirModel.connectionId, info.filePath, info.mediaKind, info.size)
        }
        dirModel.notify(remove ? qsTr("已取消收藏 %1 项").arg(items.length)
                               : qsTr("已收藏 %1 项").arg(items.length))
    }

    /// 操作时刻按选中下标重新取行，避免任何陈旧快照导致删错/改名错对象
    function selectedRows() {
        const rows = []
        const keys = Object.keys(selectionModel.selected)
        for (let i = 0; i < keys.length; ++i) {
            const info = dirModel.get(parseInt(keys[i], 10))
            if (info && Object.keys(info).length > 0)
                rows.push(info)
        }
        return rows
    }

    // ---- 页面内拖拽移动（PC-104）----
    /// 正在拖拽的源路径（非空即拖拽中）
    property var dragPaths: []
    /// 落点文件夹行（-1 = 当前落点不可落）
    property int dragHoverIndex: -1
    /// 按住 Ctrl/Option → 复制（默认移动）
    property bool dragCopy: false
    /// 拖拽提示胶囊的位置（页面坐标，跟随光标）
    property real dragX: 0
    property real dragY: 0
    readonly property bool draggingItems: dragPaths.length > 0

    // 拖拽手势的占位目标：MouseArea 有了 drag.target 才会保住鼠标抓取，
    // 视图（Flickable）就不会在拖动过程中把它当成滚动手势抢走。不参与任何视觉。
    Item {
        id: dragProxy
        width: 0
        height: 0
        visible: false
    }

    // ---------------- 顶部操作栏 ----------------
    Item {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: AppTheme.toolbarHeight

        // 返回：目录层级 > 一级时返回上级，否则回连接源列表
        ToolbarButton {
            id: backButton
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            iconName: "arrow-left"
            tooltip: qsTr("返回上一级 (Alt+←)")
            onClicked: {
                if (dirModel.canGoUp)
                    dirModel.goUp()
                else
                    BrowseController.backToConnections()
            }
        }

        // 当前目录名（根目录显示连接名）
        Text {
            anchors.left: backButton.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.right: actionRow.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            text: dirModel.directoryName
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: AppTheme.colors.textPrimary
            elide: Text.ElideMiddle
        }

        Row {
            id: actionRow
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ToolbarButton {
                iconName: "upload"
                tooltip: qsTr("上传文件 (Ctrl+U)")
                onClicked: root.uploadFiles()
            }
            ToolbarButton {
                iconName: "refresh"
                tooltip: qsTr("刷新 (F5)")
                busy: dirModel.refreshing
                onClicked: dirModel.refresh()
            }
            ToolbarButton {
                iconName: root.gridMode ? "list" : "grid"
                tooltip: root.gridMode ? qsTr("切换为列表视图") : qsTr("切换为网格视图")
                onClicked: AppSettings.viewMode = root.gridMode ? "list" : "grid"
            }
            ToolbarButton {
                iconName: "sort"
                tooltip: qsTr("排序")
                onClicked: {
                    const pos = mapToGlobal(width / 2, height)
                    sortMenu.popupAt(pos.x, pos.y)
                }
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

        // 工具栏下方统一描边
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: AppTheme.borderWidth
            color: AppTheme.colors.cardBorder
        }
    }

    // ---------------- 轻提示（刷新失败但保留旧内容）----------------
    Rectangle {
        id: notice
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: toolbar.bottom
        height: visible ? 32 : 0
        visible: dirModel.transientNotice !== ""
        color: Qt.rgba(AppTheme.colors.danger.r, AppTheme.colors.danger.g,
                       AppTheme.colors.danger.b, 0.08)

        Row {
            anchors.centerIn: parent
            spacing: AppTheme.spacingSm

            AppIcon {
                name: "alert-circle"
                width: 14; height: 14
                anchors.verticalCenter: parent.verticalCenter
                color: AppTheme.colors.danger
            }
            Text {
                text: dirModel.transientNotice
                anchors.verticalCenter: parent.verticalCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.danger
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: dirModel.clearNotice()
        }

        Behavior on height { NumberAnimation { duration: Motion.fast } }
    }

    // ---------------- 搜索框 ----------------
    SearchField {
        id: searchField
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: notice.bottom
        anchors.leftMargin: AppTheme.spacingLg
        anchors.rightMargin: AppTheme.spacingLg
        contentY: root.gridMode ? gridView.contentY : listView.contentY
        onTextChanged: dirModel.searchText = text
    }

    // ---------------- 内容区 ----------------
    Item {
        id: contentArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: searchField.bottom
        // 多选时底部操作栏占位，内容区相应让出高度（不遮挡最后一行）
        anchors.bottom: selectionBar.top
        anchors.topMargin: AppTheme.spacingXs

        // 网格视图
        GridView {
            id: gridView
            anchors.fill: parent
            anchors.leftMargin: AppTheme.spacingLg
            anchors.rightMargin: AppTheme.spacingLg
            visible: root.gridMode && dirModel.state === BrowseDirectoryModel.Ready
            clip: true
            model: dirModel

            // 大目录虚拟化：仅渲染可见区域 + 缓冲
            cacheBuffer: 400

            cellWidth: Math.floor(width / Math.max(2, Math.floor(width / 150)))
            cellHeight: cellWidth * 0.72 + 30 + AppSettings.fileNameLines * 16

            // 单元自有属性与模型角色同名，委托根用中间 Item 接收角色，再显式转发（避免自绑定成环）
            delegate: Item {
                id: gridCell
                required property int index
                required property string name
                required property string filePath
                required property bool isDir
                required property string mediaKind
                required property string sizeText
                required property string durationText
                required property string badge
                required property real size
                required property var modTime
                required property real progressPercent
                required property bool progressFinished

                width: gridView.cellWidth
                height: gridView.cellHeight

                FileGridCell {
                    anchors.fill: parent
                    name: gridCell.name
                    isDir: gridCell.isDir
                    mediaKind: gridCell.mediaKind
                    sizeText: gridCell.sizeText
                    durationText: gridCell.durationText
                    badge: gridCell.badge
                    connectionId: dirModel.connectionId
                    filePath: gridCell.filePath
                    fileSize: gridCell.size
                    fileModSecs: gridCell.modTime ? Math.floor(gridCell.modTime.getTime() / 1000) : -1
                    selected: selectionModel.isSelected(gridCell.index)
                    // 收藏星标（PC-107）：读 revision 建立依赖，收藏页取消后这里立即消失
                    favorite: Favorites.revision >= 0
                        && Favorites.isFavorite(dirModel.connectionId, gridCell.filePath)
                    // 文件名行数即时生效（§14.3）
                    nameLines: AppSettings.fileNameLines
                    // 页内拖拽落点高亮（PC-104）
                    dropTarget: root.dragHoverIndex === gridCell.index
                    // 定位呼吸灯（PC-109）
                    revealHighlight: root.revealActive && root.revealPath === gridCell.filePath
                    dragProxy: dragProxy
                    // 状态指示（§3.1）：进度环 / 正在播放均衡器 / 多选勾选并列显示
                    progress: gridCell.progressPercent
                    progressFinished: gridCell.progressFinished
                    playing: root.isPlayingMedia(gridCell.filePath)
                    selectionMode: selectionModel.count > 0

                    onClicked: function(mouse) { selectionModel.handleClick(gridCell.index, mouse) }
                    onDoubleClicked: function(wx, wy) { root.openItem(gridCell.index, wx, wy) }
                    onRightClicked: function(gx, gy) {
                        selectionModel.ensureSelected(gridCell.index)
                        contextMenu.targetIndex = gridCell.index
                        contextMenu.popupAt(gx, gy)
                    }
                    onDragStarted: root.startItemDrag(gridCell.index)
                    onDragMoved: function(gx, gy, modifiers) { root.updateItemDrag(gx, gy, modifiers) }
                    onDragDropped: function(gx, gy, modifiers) { root.finishItemDrag(gx, gy, modifiers) }
                    onDragCanceled: root.cancelItemDrag()
                }
            }
        }

        // 列表视图
        ListView {
            id: listView
            anchors.fill: parent
            anchors.leftMargin: AppTheme.spacingLg
            anchors.rightMargin: AppTheme.spacingLg
            visible: !root.gridMode && dirModel.state === BrowseDirectoryModel.Ready
            clip: true
            model: dirModel
            cacheBuffer: 400
            // 行间无分割线：不设置 separator / delegate 分隔元素
            spacing: 0

            delegate: Item {
                id: listCell
                required property int index
                required property string name
                required property string filePath
                required property bool isDir
                required property string mediaKind
                required property string sizeText
                required property string durationText
                required property real size
                required property var modTime
                required property real progressPercent
                required property bool progressFinished

                width: listView.width
                height: listRow.implicitHeight

                FileListRow {
                    id: listRow
                    anchors.fill: parent
                    name: listCell.name
                    isDir: listCell.isDir
                    mediaKind: listCell.mediaKind
                    sizeText: listCell.sizeText
                    durationText: listCell.durationText
                    connectionId: dirModel.connectionId
                    filePath: listCell.filePath
                    fileSize: listCell.size
                    fileModSecs: listCell.modTime ? Math.floor(listCell.modTime.getTime() / 1000) : -1
                    selected: selectionModel.isSelected(listCell.index)
                    // 收藏星标（PC-107）
                    favorite: Favorites.revision >= 0
                        && Favorites.isFavorite(dirModel.connectionId, listCell.filePath)
                    nameLines: AppSettings.fileNameLines
                    // 页内拖拽落点高亮（PC-104）
                    dropTarget: root.dragHoverIndex === listCell.index
                    // 定位呼吸灯（PC-109）
                    revealHighlight: root.revealActive && root.revealPath === listCell.filePath
                    dragProxy: dragProxy
                    // 状态指示（§3.1）
                    progress: listCell.progressPercent
                    progressFinished: listCell.progressFinished
                    playing: root.isPlayingMedia(listCell.filePath)
                    selectionMode: selectionModel.count > 0

                    onClicked: function(mouse) { selectionModel.handleClick(listCell.index, mouse) }
                    onDoubleClicked: function(wx, wy) { root.openItem(listCell.index, wx, wy) }
                    onRightClicked: function(gx, gy) {
                        selectionModel.ensureSelected(listCell.index)
                        contextMenu.targetIndex = listCell.index
                        contextMenu.popupAt(gx, gy)
                    }
                    onDragStarted: root.startItemDrag(listCell.index)
                    onDragMoved: function(gx, gy, modifiers) { root.updateItemDrag(gx, gy, modifiers) }
                    onDragDropped: function(gx, gy, modifiers) { root.finishItemDrag(gx, gy, modifiers) }
                    onDragCanceled: root.cancelItemDrag()
                }
            }
        }

        // ---- 四态 ----
        EmptyState {
            anchors.fill: parent
            visible: dirModel.state === BrowseDirectoryModel.Loading
            busy: true
            title: qsTr("正在加载…")
        }

        EmptyState {
            anchors.fill: parent
            visible: dirModel.state === BrowseDirectoryModel.EmptyDirectory
            iconName: "folder-open"
            title: qsTr("空目录")
            description: qsTr("这个目录下还没有文件。")
        }

        EmptyState {
            anchors.fill: parent
            visible: dirModel.state === BrowseDirectoryModel.NoSearchResult
            iconName: "search"
            title: qsTr("没有匹配的结果")
            description: qsTr("试试其它关键词。")
        }

        EmptyState {
            anchors.fill: parent
            visible: dirModel.state === BrowseDirectoryModel.Error
            iconName: "alert-circle"
            title: qsTr("无法加载目录")
            description: dirModel.errorText
            actionText: qsTr("重试")
            onActionTriggered: dirModel.refresh()
        }
    }

    // ---------------- 拖拽上传（§3.2）----------------
    // DropArea 只接收拖拽事件，不拦截鼠标点击，可整页铺满
    DropArea {
        anchors.fill: parent
        z: 40

        onEntered: function(drag) {
            if (!drag.hasUrls) {
                drag.accepted = false
                return
            }
            drag.acceptProposedAction()
            dropHint.visible = true
        }
        onExited: dropHint.visible = false
        onDropped: function(drop) {
            dropHint.visible = false
            if (!drop.hasUrls)
                return
            const paths = []
            for (let i = 0; i < drop.urls.length; ++i)
                paths.push(drop.urls[i].toString())
            root.uploadLocalFiles(paths)
            drop.acceptProposedAction()
        }
    }

    Rectangle {
        id: dropHint
        anchors.fill: parent
        anchors.margins: AppTheme.spacingSm
        z: 41
        visible: false
        radius: AppTheme.radiusCard
        color: Qt.rgba(AppTheme.colors.primary.r, AppTheme.colors.primary.g,
                       AppTheme.colors.primary.b, 0.06)
        border.width: 2
        border.color: AppTheme.colors.primary

        Column {
            anchors.centerIn: parent
            spacing: AppTheme.spacingSm

            AppIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "upload"
                width: 28
                height: 28
                color: AppTheme.colors.primary
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("松开即可上传到「%1」").arg(dirModel.directoryName)
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: AppTheme.colors.primary
            }
        }
    }

    // ---------------- 页内拖拽提示（PC-104）----------------
    // 跟随光标的胶囊：明确当前是「移动」还是「复制」，以及将落到哪个文件夹
    Rectangle {
        id: dragChip
        /// 落点文件夹行（无落点时为 null）
        readonly property var targetInfo: root.dragHoverIndex >= 0
                                           ? dirModel.get(root.dragHoverIndex) : null
        readonly property bool hasTarget: targetInfo !== null
                                          && targetInfo.name !== undefined
                                          && targetInfo.name !== ""

        visible: root.draggingItems
        z: 900
        width: chipRow.implicitWidth + AppTheme.spacingLg * 2
        height: 30
        radius: height / 2
        color: hasTarget ? AppTheme.colors.primary : AppTheme.colors.textSecondary
        x: Math.max(AppTheme.spacingSm,
                    Math.min(root.dragX + 14, root.width - width - AppTheme.spacingSm))
        y: Math.max(AppTheme.spacingSm,
                    Math.min(root.dragY + 18, root.height - height - AppTheme.spacingSm))

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: AppTheme.spacingXs

            AppIcon {
                name: root.dragCopy ? "copy" : "move"
                width: 14
                height: 14
                anchors.verticalCenter: parent.verticalCenter
                color: AppTheme.colors.textOnPrimary
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const verb = root.dragCopy ? qsTr("复制") : qsTr("移动")
                    if (dragChip.hasTarget)
                        return qsTr("%1 %2 项到「%3」").arg(verb)
                                   .arg(root.dragPaths.length).arg(dragChip.targetInfo.name)
                    return qsTr("%1 %2 项").arg(verb).arg(root.dragPaths.length)
                }
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textOnPrimary
            }
        }
    }

    // ---------------- 多选操作栏（§3.2）----------------
    Rectangle {
        id: selectionBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? 52 : 0
        visible: selectionModel.count > 0
        color: AppTheme.colors.cardBg

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: AppTheme.borderWidth
            color: AppTheme.colors.cardBorder
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("已选 %1 项").arg(selectionModel.count)
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            color: AppTheme.colors.textSecondary
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingLg
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingSm

            PrimaryButton {
                text: root.compactBar ? "" : qsTr("移动")
                iconName: "move"
                variant: PrimaryButton.Secondary
                enabled: !Files.busy
                onClicked: root.requestTransfer(-1, false)
                C.ToolTip.text: qsTr("移动")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                text: root.compactBar ? "" : qsTr("复制")
                iconName: "copy"
                variant: PrimaryButton.Secondary
                enabled: !Files.busy
                onClicked: root.requestTransfer(-1, true)
                C.ToolTip.text: qsTr("复制")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                text: root.compactBar ? "" : qsTr("下载")
                iconName: "download"
                variant: PrimaryButton.Secondary
                enabled: root.selectionDownloadable
                onClicked: root.requestDownload(-1)
                C.ToolTip.text: qsTr("下载")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                text: root.compactBar ? ""
                                      : (root.selectionAllFavorited ? qsTr("取消收藏") : qsTr("收藏"))
                iconName: "star"
                variant: PrimaryButton.Secondary
                enabled: root.selectedItems.length > 0 && !Files.busy
                onClicked: root.toggleSelectionFavorite()
                C.ToolTip.text: root.selectionAllFavorited ? qsTr("取消收藏") : qsTr("收藏")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                text: root.compactBar ? "" : qsTr("重命名")
                iconName: "edit"
                variant: PrimaryButton.Secondary
                enabled: root.selectedItems.length === 1 && !Files.busy
                onClicked: root.requestRename()
                C.ToolTip.text: qsTr("重命名")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                text: root.compactBar ? "" : qsTr("删除")
                iconName: "trash"
                variant: PrimaryButton.Secondary
                destructive: true
                enabled: !Files.busy
                onClicked: root.requestDelete()
                C.ToolTip.text: qsTr("删除")
                C.ToolTip.visible: root.compactBar && hovered
            }
            PrimaryButton {
                // 这个按钮没有图标，收成图标会直接消失，故始终保留文字
                text: qsTr("取消")
                variant: PrimaryButton.Text
                onClicked: selectionModel.clear()
                C.ToolTip.text: qsTr("取消多选")
                C.ToolTip.visible: root.compactBar && hovered
            }
        }
    }

    // ---------------- 选择模型 ----------------
    QtObject {
        id: selectionModel

        property var selected: ({})
        property int anchorIndex: -1
        property int revision: 0

        /// 选中数量（多数操作是原地增删键，靠 revision 建立依赖）
        readonly property int count: {
            revision
            return Object.keys(selected).length
        }

        function isSelected(index) {
            revision   // 建立依赖以便变更时刷新
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

        // Ctrl+单击增选、Shift+单击区间选（§3.1 多选）
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
                // 设置为单击打开时直接进入
                if (AppSettings.openOnSingleClick)
                    root.openItem(index)
            }
            revision++
        }

        function selectAll() {
            selected = ({})
            for (let i = 0; i < dirModel.count; ++i)
                selected[i] = true
            revision++
        }
    }

    // 切换目录时清空选择，并丢弃进行中的拖拽状态（避免胶囊卡住）
    Connections {
        target: dirModel
        function onPathChanged() {
            selectionModel.clear()
            root.cancelItemDrag()
        }
    }

    // 多选态：底部 mini 播放条与底部操作栏一起让位（§4.4）
    Binding {
        target: PlayerStage
        property: "selectionActive"
        value: AppRouter.currentModule === AppRouter.Browse && selectionModel.count > 0
    }

    // ---------------- 菜单 ----------------
    PopupMenu {
        id: sortMenu

        C.Action {
            text: qsTr("按名称") + (dirModel.sortKey === "name" ? "  ✓" : "")
            onTriggered: dirModel.sortKey = "name"
        }
        C.Action {
            text: qsTr("按大小") + (dirModel.sortKey === "size" ? "  ✓" : "")
            onTriggered: dirModel.sortKey = "size"
        }
        C.Action {
            text: qsTr("按修改时间") + (dirModel.sortKey === "time" ? "  ✓" : "")
            onTriggered: dirModel.sortKey = "time"
        }
        C.MenuSeparator {}
        C.Action {
            text: dirModel.sortAscending ? qsTr("改为降序") : qsTr("改为升序")
            onTriggered: dirModel.sortAscending = !dirModel.sortAscending
        }
    }

    PopupMenu {
        id: moreMenu

        C.Action {
            text: qsTr("上传文件…")
            onTriggered: root.uploadFiles()
        }
        C.Action {
            text: qsTr("上传文件夹…")
            onTriggered: root.uploadFolder()
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("新建文件夹")
            enabled: !Files.busy
            onTriggered: root.requestCreateFolder()
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("全选")
            onTriggered: selectionModel.selectAll()
        }
        C.Action {
            text: qsTr("刷新")
            onTriggered: dirModel.refresh()
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("回到连接源列表")
            onTriggered: BrowseController.backToConnections()
        }
    }

    // 右键上下文菜单（「多选」置于首位，§14.4）
    PopupMenu {
        id: contextMenu
        property int targetIndex: -1
        /// 右键目标是文件（可下载）而非文件夹
        readonly property bool targetIsFile: {
            dirModel.revision
            const info = dirModel.get(targetIndex)
            return !!info && Object.keys(info).length > 0 && !info.isDir
        }
        /// 右键目标是纯文本（可在线编辑并保存回源）
        readonly property bool targetIsTextEditable: {
            dirModel.revision
            const info = dirModel.get(targetIndex)
            return !!info && Object.keys(info).length > 0 && info.textEditable === true
        }
        /// 右键目标是否已收藏（PC-107）
        readonly property bool targetIsFavorite: {
            Favorites.revision
            const info = dirModel.get(targetIndex)
            return !!info && Object.keys(info).length > 0
                && Favorites.isFavorite(dirModel.connectionId, info.filePath)
        }
        /// 右键目标是否可切换收藏（有真实条目即可，文件/文件夹都支持）
        readonly property bool targetCanFavorite: targetIndex >= 0

        C.Action {
            text: qsTr("多选")
            onTriggered: selectionModel.ensureSelected(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("打开")
            onTriggered: root.openItem(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("编辑文本")
            enabled: contextMenu.targetIsTextEditable
            onTriggered: root.requestEditText(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("以纯文本查看")
            enabled: contextMenu.targetIsFile
            onTriggered: {
                const info = dirModel.get(contextMenu.targetIndex)
                if (!info || Object.keys(info).length === 0)
                    return
                textEditor.openFor(dirModel.connectionId, info.filePath, info.name, true)
            }
        }
        C.Action {
            text: contextMenu.targetIsFavorite ? qsTr("取消收藏") : qsTr("收藏")
            enabled: contextMenu.targetCanFavorite
            onTriggered: root.toggleFavorite(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("下载")
            enabled: contextMenu.targetIsFile
            onTriggered: root.requestDownload(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("另存为…")
            enabled: contextMenu.targetIsFile
            onTriggered: root.requestSaveAs(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("重命名")
            enabled: !Files.busy
            onTriggered: root.requestRename(contextMenu.targetIndex)
        }
        C.Action {
            text: qsTr("移动到…")
            enabled: !Files.busy
            onTriggered: root.requestTransfer(contextMenu.targetIndex, false)
        }
        C.Action {
            text: qsTr("复制到…")
            enabled: !Files.busy
            onTriggered: root.requestTransfer(contextMenu.targetIndex, true)
        }
        C.Action {
            text: qsTr("删除")
            enabled: !Files.busy
            onTriggered: root.requestDelete(contextMenu.targetIndex)
        }
        C.MenuSeparator {}
        C.Action {
            text: qsTr("属性")
            onTriggered: propertiesDialog.showFor(contextMenu.targetIndex)
        }
    }

    // 不支持预览的格式：双击在鼠标位置给出可用动作（§3.4，不偏移）
    PopupMenu {
        id: previewMenu

        C.Action {
            text: qsTr("以纯文本查看")
            onTriggered: root.viewAsText()
        }
        C.Action {
            text: qsTr("属性")
            onTriggered: {
                if (root.previewItem)
                    propertiesDialog.openFor(root.previewItem.connectionId,
                                             root.previewItem.filePath)
            }
        }
    }

    // ---------------- 文本在线编辑（PC-103）----------------
    TextEditorDialog {
        id: textEditor
        // 保存成功：大小/修改时间已变，落进当前目录时校正一次
        // （core 已在保存后失效该目录缓存，这里刷新即能拿到新元信息）
        onSaved: function(connectionId, path) {
            if (connectionId === dirModel.connectionId)
                dirModel.refresh()
        }
    }

    // ---------------- 属性面板（PC-110）----------------
    FilePropertiesDialog {
        id: propertiesDialog
        // 面板里的「定位」在本页就地完成（本来就停在这个目录，不必绕回控制器）
        onRevealRequested: function(connId, path, isDir) {
            root.requestReveal(connId, path, isDir)
        }

        function showFor(index) {
            const info = dirModel.get(index)
            if (!info || Object.keys(info).length === 0)
                return
            openFor(dirModel.connectionId, info.filePath)
        }
    }

    // ---------------- 文件操作（§3.2）----------------
    // ---------------- 收藏（PC-107）----------------
    function toggleFavorite(index) {
        const info = dirModel.get(index)
        if (!info || Object.keys(info).length === 0)
            return
        Favorites.toggle(dirModel.connectionId, info.filePath, info.mediaKind, info.size)
    }

    // ---------------- 文本在线编辑（PC-103）----------------
    function requestEditText(index) {
        const info = dirModel.get(index)
        if (!info || Object.keys(info).length === 0 || !info.textEditable)
            return
        textEditor.openFor(dirModel.connectionId, info.filePath, info.name)
    }

    function requestCreateFolder() {
        root.inputMode = "create"
        root.renameTarget = null
        inputDialog.openFor(qsTr("新建文件夹"), qsTr("在当前目录「%1」下创建").arg(dirModel.path),
                            qsTr("新建文件夹"))
    }

    function requestRename(index) {
        let info = null
        if (typeof index === "number" && index >= 0) {
            const row = dirModel.get(index)
            if (row && Object.keys(row).length > 0)
                info = row
        }
        if (!info) {
            const items = root.selectedRows()
            if (items.length === 1)
                info = items[0]
        }
        if (!info)
            return
        root.renameTarget = info
        root.inputMode = "rename"
        inputDialog.openFor(qsTr("重命名"), qsTr("为「%1」输入新名称").arg(info.name), info.name)
    }

    function requestDelete(index) {
        let items = root.selectedRows()

        // 右键点在一个「未被选中」的条目上时，只删它自己（与桌面端习惯一致）
        if (typeof index === "number" && index >= 0) {
            const row = dirModel.get(index)
            if (row && Object.keys(row).length > 0) {
                const selected = items.some(function(item) {
                    return item.filePath === row.filePath
                })
                if (!selected)
                    items = [row]
            }
        }
        if (items.length === 0)
            return

        const names = items.map(function(item) {
            return item.name
        })
        root.pendingPaths = items.map(function(item) {
            return item.filePath
        })
        const shown = names.slice(0, 5).join(qsTr("、")) + (names.length > 5 ? "…" : "")
        deleteDialog.message = items.length === 1
            ? qsTr("「%1」将移动到回收站，可从回收站还原。").arg(shown)
            : qsTr("共 %1 项将移动到回收站：%2").arg(items.length).arg(shown)
        deleteDialog.open()
    }

    // ---------------- 上传 / 下载（§3.2 PC-103）----------------
    /// 操作目标行：右键点在一个「未被选中」的条目上时只作用于它自己
    function targetItems(index) {
        let items = root.selectedRows()
        if (typeof index === "number" && index >= 0) {
            const row = dirModel.get(index)
            if (row && Object.keys(row).length > 0) {
                const included = items.some(function(item) {
                    return item.filePath === row.filePath
                })
                if (!included)
                    items = [row]
            }
        }
        return items
    }

    function uploadFiles() {
        uploadFilesDialog.open()
    }

    function uploadFolder() {
        uploadFolderDialog.open()
    }

    /// 拖拽与文件对话框共用：落点恒为当前目录（文件夹递归展开在 core 侧）
    function uploadLocalFiles(localPaths) {
        if (!localPaths || localPaths.length === 0)
            return
        Files.uploadLocalFiles(dirModel.connectionId, dirModel.path, localPaths)
    }

    /// 下载到默认目录「下载/MyHub/<连接名>/<远端路径>」
    function requestDownload(index) {
        const items = root.targetItems(index).filter(function(item) {
            return !item.isDir
        })
        if (items.length === 0) {
            root.notifyUnsupportedDownload()
            return
        }
        Files.download(dirModel.connectionId,
                       items.map(function(item) { return item.filePath }))
    }

    /// 另存为：目标路径由系统保存对话框决定（单个文件）
    function requestSaveAs(index) {
        const items = root.targetItems(index)
        if (items.length === 0)
            return
        const info = items[0]
        if (info.isDir) {
            root.notifyUnsupportedDownload()
            return
        }
        saveAsDialog.remotePath = info.filePath
        // 预填建议路径：下载/MyHub/<连接名>/<远端路径>
        const suggested = Files.suggestedDownloadPath(dirModel.connectionId, info.filePath)
        saveAsDialog.currentFolder = "file:///" + suggested.substring(0, suggested.lastIndexOf("/"))
        saveAsDialog.selectedFile = "file:///" + suggested.replace(/\\/g, "/")
        saveAsDialog.open()
    }

    function notifyUnsupportedDownload() {
        fileErrorDialog.title = qsTr("下载")
        fileErrorDialog.message = qsTr("暂不支持下载文件夹，请先进入文件夹后选择其中的文件。")
        fileErrorDialog.open()
    }

    // ---------------- 移动 / 复制（PC-104）----------------
    /// 目标目录由选择器决定（可切目标连接源）；跨源流式中转在 core 侧完成
    function requestTransfer(index, copyMode) {
        const items = root.targetItems(index)
        if (items.length === 0)
            return
        folderPicker.openFor(dirModel.connectionId, copyMode,
                             items.map(function(item) { return item.filePath }))
    }

    // ---------------- 页面内拖拽移动（PC-104）----------------
    /// 拖未选中的条目 → 先让它成为唯一选中项；拖已选中的条目 → 整组一起走
    function startItemDrag(index) {
        if (Files.busy)
            return
        selectionModel.ensureSelected(index)
        const items = root.targetItems(index)
        const paths = []
        for (let i = 0; i < items.length; ++i)
            paths.push(items[i].filePath)
        root.dragPaths = paths
        root.dragHoverIndex = -1
        root.dragCopy = false
    }

    function updateItemDrag(globalX, globalY, modifiers) {
        if (!root.draggingItems)
            return
        const p = root.mapFromGlobal(globalX, globalY)
        root.dragX = p.x
        root.dragY = p.y
        // Ctrl（macOS 上映射为 Cmd）与 Option/Alt 都按「复制」处理
        root.dragCopy = (modifiers & (Qt.ControlModifier | Qt.AltModifier)) !== 0
        root.dragHoverIndex = root.dropFolderIndexAt(p.x, p.y)
    }

    function finishItemDrag(globalX, globalY, modifiers) {
        if (!root.draggingItems)
            return
        root.updateItemDrag(globalX, globalY, modifiers)
        const index = root.dragHoverIndex
        const copy = root.dragCopy
        const paths = root.dragPaths
        root.resetItemDrag()
        if (index < 0)
            return
        const info = dirModel.get(index)
        if (!info || Object.keys(info).length === 0 || !info.isDir)
            return
        // 页内拖拽恒为同一连接源：不走选择器，直接交给 core（进度/失败提示与移动一致）
        Files.moveOrCopy(dirModel.connectionId, paths, dirModel.connectionId, info.filePath, copy)
    }

    function cancelItemDrag() {
        root.resetItemDrag()
    }

    function resetItemDrag() {
        root.dragPaths = []
        root.dragHoverIndex = -1
        root.dragCopy = false
    }

    /// 命中判定：只有「可落」的文件夹算目标（文件、自身及自身子目录、当前目录都不算）
    /// 用委托矩形逐个比对（`mapFromItem` 结果确定），不依赖 indexAt 的坐标系约定
    function dropFolderIndexAt(x, y) {
        const view = root.gridMode ? gridView : listView
        const children = view.contentItem.children
        for (let i = 0; i < children.length; ++i) {
            const cell = children[i]
            if (cell.index === undefined || cell.index < 0)
                continue
            const local = cell.mapFromItem(root, x, y)
            if (local.x < 0 || local.y < 0 || local.x > cell.width || local.y > cell.height)
                continue
            return root.dropIndexForRow(cell.index)
        }
        return -1
    }

    function dropIndexForRow(index) {
        const info = dirModel.get(index)
        if (!info || Object.keys(info).length === 0 || !info.isDir)
            return -1
        return root.canDropInto(info.filePath) ? index : -1
    }

    function canDropInto(targetPath) {
        if (targetPath === dirModel.path)
            return false
        for (let i = 0; i < root.dragPaths.length; ++i) {
            const source = root.dragPaths[i]
            if (targetPath === source || targetPath.indexOf(source + "/") === 0)
                return false
        }
        return true
    }

    function submitName(text) {
        const reason = Files.validateName(text)
        if (reason !== "") {
            inputDialog.errorText = reason
            return
        }
        // 就地拦同名（引擎侧也会拒绝，但本地拦一下是零延迟的）
        const unchanged = root.inputMode === "rename" && root.renameTarget
            && root.renameTarget.name.toLowerCase() === text.toLowerCase()
        if (!unchanged && dirModel.hasEntry(text)) {
            inputDialog.errorText = qsTr("同名条目已存在：%1").arg(text)
            return
        }
        if (root.inputMode === "create") {
            Files.createFolder(dirModel.connectionId, dirModel.path, text)
        } else if (root.renameTarget) {
            Files.rename(dirModel.connectionId, root.renameTarget.filePath, text)
        }
        inputDialog.close()
    }

    InputDialog {
        id: inputDialog
        onSubmitted: function(text) { root.submitName(text) }
    }

    ConfirmDialog {
        id: deleteDialog
        title: qsTr("删除")
        confirmText: qsTr("删除")
        destructive: true
        onAccepted: Files.removeToTrash(dirModel.connectionId, root.pendingPaths)
    }

    ConfirmDialog {
        id: fileErrorDialog
        title: qsTr("操作失败")
        confirmText: qsTr("知道了")
        showCancel: false
    }

    /// 移动 / 复制：目标目录选择 + 进度（取消不回滚已完成项）
    FolderPickerDialog {
        id: folderPicker
    }

    // ---------------- 上传 / 下载入口（§3.2）----------------
    FileDialog {
        id: uploadFilesDialog
        title: qsTr("选择要上传的文件")
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            const paths = []
            for (let i = 0; i < selectedFiles.length; ++i)
                paths.push(selectedFiles[i].toString())
            root.uploadLocalFiles(paths)
        }
    }

    FolderDialog {
        id: uploadFolderDialog
        title: qsTr("选择要上传的文件夹")
        onAccepted: root.uploadLocalFiles([selectedFolder.toString()])
    }

    FileDialog {
        id: saveAsDialog
        title: qsTr("另存为")
        fileMode: FileDialog.SaveFile
        /// 待下载的远端路径（由右键菜单 / 多选栏写入）
        property string remotePath: ""
        onAccepted: {
            if (remotePath !== "")
                Files.downloadAs(dirModel.connectionId, remotePath, selectedFile.toString())
        }
    }

    Connections {
        target: Files

        function onCreated(parentPath, path, isDir) {
            dirModel.applyCreated(parentPath, path, isDir)
        }
        function onRenamed(oldPath, newPath) {
            dirModel.applyRenamed(oldPath, newPath)
        }
        function onRemoved(paths) {
            dirModel.applyRemoved(paths)
            selectionModel.clear()
        }
        // 移动/复制有了成功项：源侧就地移除，目标侧落进当前目录时校正一次
        function onTransferred(sourceConnectionId, moved, targetConnectionId, targetDir, created,
                               copy) {
            if (moved.length > 0 && sourceConnectionId === dirModel.connectionId) {
                dirModel.applyRemoved(moved)
                selectionModel.clear()
            }
            // 新条目的大小/类型未知，交给一次后台刷新校正（两侧目录缓存已在 core 侧失效）
            if (targetConnectionId === dirModel.connectionId && targetDir === dirModel.path)
                dirModel.refresh()
        }
        function onFailed(title, reason) {
            fileErrorDialog.title = title
            fileErrorDialog.message = reason
            fileErrorDialog.open()
        }
    }

    // ---------------- 打开条目 ----------------
    /// windowX/windowY：双击时的窗口坐标；不支持预览时菜单要落在鼠标处（§3.4）
    function openItem(index, windowX, windowY) {
        const info = dirModel.get(index)
        if (!info || Object.keys(info).length === 0)
            return
        if (info.isDir) {
            dirModel.navigateTo(info.filePath)
            return
        }
        if (info.mediaKind === "video" || info.mediaKind === "audio") {
            playItem(info)
            return
        }
        // 纯文本类：直接进入在线编辑（PC-103），保存即回源
        if (info.textEditable) {
            textEditor.openFor(dirModel.connectionId, info.filePath, info.name)
            return
        }
        // 其它格式：不再只弹「暂未实现」，就地给出能做的事（§3.4）
        root.previewItem = {
            connectionId: dirModel.connectionId,
            filePath: info.filePath,
            name: info.name,
            mediaKindText: info.mediaKindText
        }
        previewMenu.popupAt(windowX === undefined ? root.width / 2 : windowX,
                            windowY === undefined ? root.height / 2 : windowY)
    }

    /// 以纯文本查看：复用文本编辑器的只读模式（编码检测 / 8MB 上限都在 C++ 侧）
    function viewAsText() {
        if (!root.previewItem)
            return
        textEditor.openFor(root.previewItem.connectionId, root.previewItem.filePath,
                           root.previewItem.name, true)
    }

    /// 该条目是否是当前载入的媒体（§3.1 正在播放角标）
    function isPlayingMedia(path) {
        const current = Player.currentPath
        const conn = Player.currentConnectionId
        return current !== "" && current === path && conn === dirModel.connectionId
    }

    // 本地条目按文件路径起播；远程源走 127.0.0.1 回环代流（§4.2 边下边播）
    // startMs 传 -1 即「按历史进度续播」，续播点由 C++ 侧查进度记录决定（PC-209）
    function playItem(info) {
        if (BrowseController.isCurrentConnectionLocal()) {
            Player.openLocalFile(info.filePath, info.name, -1, BrowseController.connectionId)
            return
        }
        // 目录模型已有 size / fingerprint，直接传进去省一次 stat 往返
        Player.openRemote(BrowseController.connectionId, info.filePath, info.name, info.size,
                          info.fingerprint, -1)
    }

    // 远程起播失败（连接断开 / 文件大小未知 / 代流端口起不来）才提示，
    // 失败文案由 C++ 给具体原因，这里不猜
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
        // F5 / Ctrl+R 刷新
        if (event.key === Qt.Key_F5
            || (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier))) {
            dirModel.refresh()
            event.accepted = true
        // Alt+← / Backspace 返回上一级
        } else if ((event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier))
                   || event.key === Qt.Key_Backspace) {
            if (dirModel.canGoUp)
                dirModel.goUp()
            else
                BrowseController.backToConnections()
            event.accepted = true
        // Ctrl+A 全选
        } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
            selectionModel.selectAll()
            event.accepted = true
        // Ctrl+F 目录内搜索
        } else if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
            searchField.focusInput()
            event.accepted = true
        // F2 重命名（单选）
        } else if (event.key === Qt.Key_F2) {
            root.requestRename(-1)
            event.accepted = true
        // Delete 删除到回收站（需确认）
        } else if (event.key === Qt.Key_Delete) {
            root.requestDelete(-1)
            event.accepted = true
        // Ctrl+Shift+N 新建文件夹
        } else if (event.key === Qt.Key_N
                   && (event.modifiers & Qt.ControlModifier)
                   && (event.modifiers & Qt.ShiftModifier)) {
            root.requestCreateFolder()
            event.accepted = true
        // Ctrl+U 上传文件
        } else if (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) {
            root.uploadFiles()
            event.accepted = true
        }
    }
}
