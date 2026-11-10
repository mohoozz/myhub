import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

// 目录委托里要访问外层 id（picker），绑定组件上下文（qmllint 约定）
pragma ComponentBehavior: Bound

/*
  目标文件夹选择器（PC-104 移动 / 复制）。

  职责：
    - 选目标连接源（可与源不同）+ 逐级进入目录，可在目标处新建文件夹
    - 用户确认后直接发起移动/复制，随后切到进度态（进度可取消）
  纪律：
    - 视觉与 ConfirmDialog / InputDialog 一致（居中 + 完全圆角）
    - 目标同名不覆盖：顺延 `name (n).ext` 全部在 core 侧完成，这里不做任何改名
    - 同源移动且目标就是源所在目录时直接禁用确认（core 视为无操作，UI 先说清楚）
*/
C.Dialog {
    id: control

    /// 源连接源与待移动/复制的源路径（由调用方在 openFor 时给出）
    property string sourceConnectionId: ""
    property var sourcePaths: []

    /// 目标连接源与目录（用户在选择器里切换）
    property string connectionId: ""
    property string targetPath: "/"
    property bool copy: false

    // ---- 进度态（确认后进入）----
    property bool busy: false
    property int doneItems: 0
    property int totalItems: 0
    property string currentName: ""
    property real bytesDone: 0
    property real bytesTotal: 0

    /// 源条目所在目录（同一页面选中的条目同属一个目录）
    readonly property string sourceParent: {
        if (!sourcePaths || sourcePaths.length === 0)
            return ""
        const first = String(sourcePaths[0])
        const slash = first.lastIndexOf("/")
        return slash <= 0 ? "/" : first.substring(0, slash)
    }

    /// 同源「移动」到源目录本身：core 视为无操作，这里提前禁用确认
    readonly property bool targetIsSourceParent:
        !copy && connectionId === sourceConnectionId && targetPath === sourceParent

    readonly property bool canSubmit: !busy && !Files.busy
                                       && sourcePaths && sourcePaths.length > 0
                                       && connectionId !== ""

    modal: true
    anchors.centerIn: C.Overlay.overlay
    width: Math.min(560, (parent ? parent.width : 560) - 64)
    padding: AppTheme.spacingXl
    closePolicy: busy ? C.Popup.NoAutoClose : C.Popup.CloseOnEscape
    header: null

    background: Rectangle {
        radius: AppTheme.radiusCard
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    C.Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.42)
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.fast }
            NumberAnimation { property: "scale"; from: 0.96; to: 1
                              duration: Motion.normal; easing.type: Motion.easeOut }
        }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Motion.fast }
    }

    // ---- 数据源 ----
    ConnectionListModel {
        id: connections
        enabledOnly: true
    }

    ListModel { id: folderModel }

    BrowseDirectoryModel {
        id: picker
        // 只跟随 control.connectionId：反向赋值会打断绑定
        connectionId: control.connectionId
        onPathChanged: control.targetPath = path
        onRevisionChanged: control.rebuildFolders()
    }

    // ---- 入口 ----
    /// sourceConnectionId 作为默认目标源（可切换），paths 为待处理条目
    function openFor(sourceConnectionId, copyMode, paths) {
        control.sourceConnectionId = sourceConnectionId
        control.sourcePaths = paths || []
        control.copy = copyMode
        control.title = copyMode ? qsTr("复制到…") : qsTr("移动到…")
        control.busy = false
        control.doneItems = 0
        control.totalItems = 0
        control.currentName = ""
        control.bytesDone = 0
        control.bytesTotal = 0

        // 默认目标源 = 源连接源；该连接源不在可选列表里时退回第一项
        const row = connections.rowOf(sourceConnectionId)
        const fallback = row < 0 && connections.count > 0
        const nextConnection = fallback ? connections.idAt(0) : sourceConnectionId
        const sameConnection = control.connectionId === nextConnection
        control.connectionId = nextConnection
        control.targetPath = "/"
        folderModel.clear()
        if (sameConnection) {
            // 同一源再次打开：路径回根并校正一次，避免看到过期子目录
            if (picker.path !== "/")
                picker.navigateTo("/")
            else
                picker.refresh()
        }
        // 连接源变了则由 setConnectionId 自己重置到根目录并重新拉取
        const current = connections.rowOf(control.connectionId)
        if (current >= 0)
            sourceBox.currentIndex = current
        open()
    }

    /// 确认后进入进度态（由 submit() 在 core 受理后调用）
    function startProgress() {
        busy = true
        doneItems = 0
        totalItems = 0
        currentName = ""
        bytesDone = 0
        bytesTotal = 0
    }

    /// 只展示子文件夹（文件不进目标列表）
    function rebuildFolders() {
        folderModel.clear()
        for (let i = 0; i < picker.count; ++i) {
            const row = picker.get(i)
            if (row && !isEmptyRow(row) && row.isDir)
                folderModel.append({ "name": row.name, "filePath": row.filePath })
        }
    }

    function isEmptyRow(row) {
        return !row || Object.keys(row).length === 0
    }

    function submit() {
        if (!canSubmit)
            return
        if (Files.moveOrCopy(control.sourceConnectionId, control.sourcePaths,
                             control.connectionId, control.targetPath, control.copy)) {
            startProgress()
        } else {
            // 未受理：FileBridge 已发出 failed（页面弹出原因），这里收起选择器
            control.reject()
        }
    }

    // ---- 目标处新建文件夹（复用单行输入对话框）----
    InputDialog {
        id: newFolderDialog
        title: qsTr("新建文件夹")
        placeholderText: qsTr("文件夹名称")
        message: qsTr("在「%1」下创建").arg(control.targetPath)
        onSubmitted: function(text) {
            const reason = Files.validateName(text)
            if (reason !== "") {
                newFolderDialog.errorText = reason
                return
            }
            Files.createFolder(control.connectionId, control.targetPath, text)
            newFolderDialog.close()
        }
    }

    // 进度与收尾直接吃 Files 的信号（对话框是唯一持有进度态的地方）
    Connections {
        target: Files

        function onTransferProgress(done, total, currentName, bytesDone, bytesTotal) {
            if (!control.busy)
                return
            control.doneItems = done
            control.totalItems = total
            control.currentName = currentName
            control.bytesDone = bytesDone
            control.bytesTotal = bytesTotal
        }

        function onTransferFinished() {
            if (control.busy)
                control.close()
        }

        // 目标目录里新建了文件夹：刷新选择器列表
        function onCreated(parentPath, path, isDir) {
            if (isDir && control.connectionId !== "" && parentPath === control.targetPath)
                picker.refresh()
        }
    }

    contentItem: Column {
        spacing: AppTheme.spacingMd

        Text {
            width: parent.width
            text: control.title
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: AppTheme.colors.textPrimary
        }

        // ---- 目标源 + 路径操作 ----
        Row {
            width: parent.width
            spacing: AppTheme.spacingSm
            visible: !control.busy

            C.ComboBox {
                id: sourceBox
                width: 180
                model: connections
                textRole: "name"
                // 切换目标连接源：模型重置到根目录并重新拉取
                onActivated: function(index) {
                    control.connectionId = connections.idAt(index)
                }
            }

            PrimaryButton {
                text: qsTr("上一级")
                iconName: "chevron-up"
                variant: PrimaryButton.Secondary
                enabled: picker.canGoUp
                onClicked: picker.goUp()
            }

            PrimaryButton {
                text: qsTr("新建文件夹")
                iconName: "plus"
                variant: PrimaryButton.Secondary
                onClicked: {
                    newFolderDialog.errorText = ""
                    newFolderDialog.open()
                }
            }
        }

        Text {
            width: parent.width
            visible: !control.busy
            text: qsTr("目标：%1").arg(control.targetPath)
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.textSecondary
            elide: Text.ElideMiddle
        }

        Text {
            width: parent.width
            visible: !control.busy && control.targetIsSourceParent
            text: qsTr("这已经是它们所在的目录，无需移动。")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.danger
            wrapMode: Text.Wrap
        }

        // ---- 目录列表 ----
        Rectangle {
            width: parent.width
            height: 248
            visible: !control.busy
            radius: AppTheme.radiusSmall
            color: AppTheme.colors.hoverFill
            border.width: AppTheme.borderWidth
            border.color: AppTheme.colors.cardBorder
            clip: true

            ListView {
                anchors.fill: parent
                anchors.margins: AppTheme.spacingXs
                model: folderModel
                clip: true
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: folderRow
                    required property string name
                    required property string filePath

                    width: ListView.view.width
                    height: 34
                    radius: AppTheme.radiusSmall
                    color: hover.containsMouse ? AppTheme.colors.primaryWeak : "transparent"

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: AppTheme.spacingSm
                        spacing: AppTheme.spacingSm

                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "folder"
                            width: 16
                            height: 16
                            color: AppTheme.colors.primary
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: folderRow.name
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.navigateTo(folderRow.filePath)
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: folderModel.count === 0
                width: parent.width - AppTheme.spacingLg
                text: picker.state === BrowseDirectoryModel.Loading ? qsTr("正在读取…")
                      : (picker.state === BrowseDirectoryModel.Error ? picker.errorText
                                                                     : qsTr("没有子文件夹"))
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }

        // ---- 进度态 ----
        Column {
            width: parent.width
            spacing: AppTheme.spacingSm
            visible: control.busy

            Text {
                width: parent.width
                text: control.totalItems > 0
                      ? qsTr("正在%1 %2 / %3").arg(control.copy ? qsTr("复制") : qsTr("移动"))
                            .arg(control.doneItems).arg(control.totalItems)
                      : (control.copy ? qsTr("正在复制…") : qsTr("正在移动…"))
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: AppTheme.colors.textPrimary
            }
            Text {
                width: parent.width
                visible: control.currentName !== ""
                text: control.currentName
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
                elide: Text.ElideMiddle
            }
            Rectangle {
                width: parent.width
                height: 4
                radius: 2
                color: AppTheme.colors.hoverFill

                Rectangle {
                    width: parent.width * (control.bytesTotal > 0
                                           ? Math.min(1, control.bytesDone / control.bytesTotal) : 0)
                    height: parent.height
                    radius: 2
                    color: AppTheme.colors.primary

                    Behavior on width {
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut }
                    }
                }
            }
        }

        Item { width: 1; height: AppTheme.spacingXs }

        Row {
            anchors.right: parent.right
            spacing: AppTheme.spacingSm

            PrimaryButton {
                text: control.busy ? qsTr("取消") : qsTr("关闭")
                variant: PrimaryButton.Text
                onClicked: {
                    if (control.busy)
                        Files.cancelMoveCopy()
                    else
                        control.reject()
                }
            }
            PrimaryButton {
                text: control.copy ? qsTr("复制到这里") : qsTr("移动到这里")
                variant: PrimaryButton.Primary
                visible: !control.busy
                enabled: control.canSubmit && !control.targetIsSourceParent
                onClicked: control.submit()
            }
        }
    }
}
