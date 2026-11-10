import QtQuick
import MyHub

pragma ComponentBehavior: Bound

/*
  传输队列横幅（§3.2 PC-103）。

  队列逻辑全在 core（`TransferManager`，QTest 覆盖），本组件只做展示：
    - 有任务在跑 → 显示当前任务的字节级进度 + 取消
    - 全部结束   → 显示最近一条的结果（失败可重试 / 下载完成可在文件夹中显示）
    - 多于一条   → 可展开查看完整队列，逐条取消或重试

  样式纪律：与底部播放条同级（cardBg + 顶部统一 1pt 描边），
  不得贴边直角色块（§14.15）。
*/
Rectangle {
    id: root

    /// 队列详情是否展开
    property bool expanded: false

    readonly property var current: Transfers.currentTask
    readonly property var lastFinished: Transfers.lastFinished
    readonly property bool running: Transfers.activeCount > 0

    /// 有活动任务时看当前任务，否则看最近一条已结束的任务
    readonly property var shown: running ? current : lastFinished

    readonly property string shownId: shown && shown.transferId !== undefined
        ? shown.transferId : ""
    readonly property int shownStatus: shown && shown.status !== undefined ? shown.status : -1
    readonly property int shownKind: shown && shown.kind !== undefined ? shown.kind : -1
    readonly property real shownProgress: shown && shown.progress !== undefined
        ? shown.progress : 0
    readonly property bool shownRetryable: shown && shown.canRetry === true
    /// 下载完成（kind 1 = Download，status 2 = Completed）
    readonly property bool shownDownloadDone: shownKind === 1 && shownStatus === 2
    readonly property string shownLocalPath: shown && shown.localPath !== undefined
        ? shown.localPath : ""

    function detailText() {
        if (!shown || shown.statusText === undefined)
            return qsTr("准备中…")
        let text = shown.statusText
        if (shown.error !== undefined && shown.error !== "")
            text += qsTr(" · %1").arg(shown.error)
        else if (shown.bytesText !== undefined && shown.bytesText !== "")
            text += qsTr(" · %1").arg(shown.bytesText)
        if (running && shown.percentText !== undefined && shown.percentText !== "")
            text += qsTr(" · %1").arg(shown.percentText)
        return text
    }

    visible: Transfers.count > 0
    height: visible ? AppTheme.rowHeight + (expanded ? queueBox.height : 0) : 0
    color: AppTheme.colors.cardBg

    Behavior on height {
        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut }
    }

    // 顶部统一描边（与播放条 / 工具栏同一份令牌）
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: AppTheme.borderWidth
        color: AppTheme.colors.cardBorder
    }

    // 进度细条：压在顶边描边之上；不在跑时隐藏，避免「完成态还挂着一条满格线」
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        height: 2
        width: root.running ? parent.width * Math.max(0, Math.min(1, root.shownProgress)) : 0
        color: AppTheme.colors.primary
        visible: root.running
    }

    // ---------------- 头部一行 ----------------
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: AppTheme.rowHeight

        AppIcon {
            id: kindIcon
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.verticalCenter: parent.verticalCenter
            name: root.shownKind === 1 ? "download" : "upload"
            width: 17
            height: 17
            color: root.shownStatus === 3 ? AppTheme.colors.danger : AppTheme.colors.primary
        }

        Row {
            id: headerActions
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingLg
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingSm

            PrimaryButton {
                text: qsTr("取消")
                variant: PrimaryButton.Text
                implicitHeight: 28
                visible: root.running && root.shownId !== ""
                onClicked: Transfers.cancel(root.shownId)
            }
            PrimaryButton {
                text: qsTr("全部取消")
                variant: PrimaryButton.Text
                implicitHeight: 28
                visible: root.running && Transfers.count > 1
                onClicked: Transfers.cancelAll()
            }
            PrimaryButton {
                text: qsTr("重试")
                iconName: "replay"
                variant: PrimaryButton.Text
                implicitHeight: 28
                visible: !root.running && root.shownRetryable
                onClicked: Transfers.retry(root.shownId)
            }
            PrimaryButton {
                text: qsTr("在文件夹中显示")
                iconName: "folder-open"
                variant: PrimaryButton.Text
                implicitHeight: 28
                visible: !root.running && root.shownDownloadDone
                onClicked: Files.revealInFolder(root.shownLocalPath)
            }
            ToolbarButton {
                iconName: root.expanded ? "chevron-down" : "chevron-up"
                tooltip: root.expanded ? qsTr("收起队列") : qsTr("查看队列")
                tooltipAbove: true
                visible: Transfers.count > 1
                onClicked: root.expanded = !root.expanded
            }
            ToolbarButton {
                iconName: "x"
                tooltip: qsTr("清除已完成")
                tooltipAbove: true
                visible: !root.running
                onClicked: {
                    root.expanded = false
                    Transfers.clearFinished()
                }
            }
        }

        Column {
            anchors.left: kindIcon.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.right: headerActions.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: root.shown && root.shown.fileName !== undefined && root.shown.fileName !== ""
                    ? root.shown.fileName
                    : qsTr("传输队列")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.bold: true
                color: AppTheme.colors.textPrimary
                elide: Text.ElideMiddle
            }

            Text {
                width: parent.width
                text: root.detailText()
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
                color: root.shownStatus === 3 ? AppTheme.colors.danger
                                               : AppTheme.colors.textSecondary
                elide: Text.ElideRight
            }
        }
    }

    // ---------------- 展开的队列详情 ----------------
    Rectangle {
        id: queueBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        height: root.expanded ? Math.min(queueList.contentHeight + AppTheme.spacingXs * 2, 208) : 0
        visible: root.expanded
        clip: true
        color: AppTheme.colors.cardBg

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: AppTheme.borderWidth
            color: AppTheme.colors.separator
        }

        ListView {
            id: queueList
            anchors.fill: parent
            anchors.topMargin: AppTheme.spacingXs
            anchors.bottomMargin: AppTheme.spacingXs
            anchors.leftMargin: AppTheme.spacingSm
            anchors.rightMargin: AppTheme.spacingSm
            model: Transfers
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: 2

            delegate: Item {
                id: queueRow
                required property string transferId
                required property int kind
                required property int status
                required property string fileName
                required property string statusText
                required property string percentText
                required property string error
                required property bool canRetry
                required property string localPath

                height: 38

                AppIcon {
                    id: rowIcon
                    anchors.left: parent.left
                    anchors.leftMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    name: queueRow.kind === 1 ? "download" : "upload"
                    width: 14
                    height: 14
                    color: queueRow.status === 3 ? AppTheme.colors.danger
                                                 : AppTheme.colors.textSecondary
                }

                // 逐条操作放在右侧，先占位再给文字让空间
                PrimaryButton {
                    id: rowAction
                    anchors.right: parent.right
                    anchors.rightMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: 26
                    variant: PrimaryButton.Text
                    text: queueRow.status === 3 ? qsTr("重试")
                        : (queueRow.status === 2 ? qsTr("在文件夹中显示") : qsTr("取消"))
                    // 已取消 / 上传完成的行没有可执行动作
                    visible: queueRow.status === 3 ? queueRow.canRetry
                        : (queueRow.status === 2 ? queueRow.kind === 1 : queueRow.status <= 1)
                    onClicked: {
                        if (queueRow.status === 3)
                            Transfers.retry(queueRow.transferId)
                        else if (queueRow.status === 2)
                            Files.revealInFolder(queueRow.localPath)
                        else
                            Transfers.cancel(queueRow.transferId)
                    }
                }

                Column {
                    anchors.left: rowIcon.right
                    anchors.leftMargin: AppTheme.spacingSm
                    anchors.right: rowAction.visible ? rowAction.left : parent.right
                    anchors.rightMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: queueRow.fileName
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeSmall
                        color: AppTheme.colors.textPrimary
                        elide: Text.ElideMiddle
                    }

                    Text {
                        width: parent.width
                        text: queueRow.error !== ""
                            ? queueRow.error
                            : queueRow.statusText
                                + (queueRow.percentText !== "" ? " · " + queueRow.percentText : "")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: queueRow.status === 3 ? AppTheme.colors.danger
                                                     : AppTheme.colors.textSecondary
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
