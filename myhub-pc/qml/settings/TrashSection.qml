pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  回收站（§3.3 / 原型 07-settings.html）。

  纪律：
    - 列表跨连接源聚合，每行标明所属连接源（不提供按源切换，避免多一次跳转）
    - **元数据丢失的条目不可还原**，只允许彻底删除（不猜测原路径）
    - 彻底删除 / 清空都要二次确认；还原不确认（可逆）
    - 保留期内的过期条目在打开本页时被静默清理，不弹窗打扰
*/
Item {
    id: root

    /// 由设置页驱动：切到本分区时才扫描（避免每次进设置都读一遍网络回收站）
    property bool active: false

    /// 待彻底删除的条目：行号 + 快照（确认框文案来自快照，行数据随后会被移除）
    property int pendingIndex: -1
    property var pendingRow: ({})

    function formatDeletedAt(ms) {
        if (!ms || ms <= 0)
            return qsTr("删除时间未知")
        return Qt.formatDateTime(new Date(ms), "yyyy-MM-dd HH:mm") + qsTr(" 删除")
    }

    function formatDaysLeft(days) {
        if (days < 0)
            return ""
        if (days === 0)
            return qsTr("即将自动清理")
        return qsTr("%1 天后自动清理").arg(days)
    }

    onActiveChanged: {
        if (active)
            trashModel.refresh()
    }

    TrashModel {
        id: trashModel
    }

    Connections {
        target: trashModel

        function onFailed(title, reason) {
            errorDialog.title = title
            errorDialog.message = reason
            errorDialog.open()
        }
    }

    // ---------------- 头部 ----------------
    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: AppTheme.spacingXl
        spacing: AppTheme.spacingLg

        Item {
            width: parent.width
            height: 40

            Text {
                id: title
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("回收站")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeHeading
                font.bold: true
                color: AppTheme.colors.textPrimary
            }

            Text {
                anchors.left: title.right
                anchors.leftMargin: AppTheme.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                text: trashModel.statusText
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textFaint
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: AppTheme.spacingSm

                PrimaryButton {
                    text: qsTr("刷新")
                    iconName: "refresh"
                    variant: PrimaryButton.Secondary
                    enabled: !trashModel.loading && !trashModel.busy
                    onClicked: trashModel.refresh()
                }

                PrimaryButton {
                    text: qsTr("清空回收站")
                    iconName: "trash"
                    variant: PrimaryButton.Secondary
                    destructive: true
                    enabled: trashModel.count > 0 && !trashModel.busy
                    onClicked: clearDialog.open()
                }
            }
        }

        // 保留设置
        Rectangle {
            width: parent.width
            height: retentionColumn.implicitHeight + AppTheme.spacingLg * 2
            radius: AppTheme.radiusCard
            color: AppTheme.colors.cardBg
            border.width: AppTheme.borderWidth
            border.color: AppTheme.colors.cardBorder

            Column {
                id: retentionColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: AppTheme.spacingLg
                spacing: AppTheme.spacingSm

                Text {
                    text: qsTr("保留期限：%1 天").arg(trashModel.retentionDays)
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeBody
                    color: AppTheme.colors.textPrimary
                }

                Text {
                    width: parent.width
                    text: qsTr("超过保留期限的条目会在打开回收站时自动彻底删除，此操作不可恢复。")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeTiny
                    color: AppTheme.colors.textFaint
                    wrapMode: Text.Wrap
                }

                C.Slider {
                    width: Math.min(parent.width, 280)
                    from: 1
                    to: 90
                    stepSize: 1
                    snapMode: C.Slider.SnapAlways
                    value: trashModel.retentionDays
                    onMoved: trashModel.retentionDays = value
                }
            }
        }
    }

    // ---------------- 列表 ----------------
    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.margins: AppTheme.spacingXl
        anchors.topMargin: AppTheme.spacingLg
        clip: true
        spacing: AppTheme.spacingSm
        model: trashModel

        delegate: Rectangle {
            id: row

            required property int index
            required property string name
            required property string originalDir
            required property string originalPath
            required property string connectionName
            required property bool isDir
            required property bool restorable
            required property string mediaKind
            required property real deletedAt
            required property int daysLeft

            width: list.width
            height: 68
            radius: AppTheme.radiusInput
            color: rowMouse.containsMouse ? AppTheme.colors.hoverFill : AppTheme.colors.cardBg
            border.width: AppTheme.borderWidth
            border.color: AppTheme.colors.cardBorder

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
            }

            FileTypeIcon {
                id: icon
                anchors.left: parent.left
                anchors.leftMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                height: 30
                mediaKind: row.mediaKind
                isDir: row.isDir
            }

            Column {
                anchors.left: icon.right
                anchors.leftMargin: AppTheme.spacingMd
                anchors.right: actions.left
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Text {
                    width: parent.width
                    text: row.name
                    elide: Text.ElideMiddle
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeBody
                    color: AppTheme.colors.textPrimary
                }

                Text {
                    width: parent.width
                    text: row.restorable
                        ? row.originalDir
                        : qsTr("原路径未知（删除记录缺失）")
                    elide: Text.ElideMiddle
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeTiny
                    color: AppTheme.colors.textFaint
                }
            }

            Column {
                id: actions
                anchors.right: parent.right
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Row {
                    anchors.right: parent.right
                    spacing: AppTheme.spacingXs

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.connectionName
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.formatDeletedAt(row.deletedAt)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text !== ""
                        text: root.formatDaysLeft(row.daysLeft)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: row.daysLeft >= 0 && row.daysLeft <= 3
                            ? AppTheme.colors.danger : AppTheme.colors.textFaint
                    }
                }

                Row {
                    anchors.right: parent.right
                    spacing: AppTheme.spacingXs

                    PrimaryButton {
                        text: qsTr("还原")
                        iconName: "replay"
                        variant: PrimaryButton.Text
                        implicitHeight: 30
                        enabled: row.restorable && !trashModel.busy
                        onClicked: trashModel.restoreRow(row.index)
                    }

                    PrimaryButton {
                        text: ""
                        iconName: "trash"
                        variant: PrimaryButton.Text
                        destructive: true
                        implicitHeight: 30
                        width: 32
                        leftPadding: 8
                        rightPadding: 8
                        enabled: !trashModel.busy
                        onClicked: {
                            root.pendingIndex = row.index
                            root.pendingRow = trashModel.get(row.index)
                            purgeDialog.open()
                        }
                    }
                }
            }
        }
    }

    EmptyState {
        anchors.fill: list
        visible: !trashModel.loading && trashModel.count === 0
        busy: false
        iconName: "trash"
        title: qsTr("回收站是空的")
        description: qsTr("删除的文件与目录会先放到这里，保留期内可随时还原。")
    }

    EmptyState {
        anchors.fill: list
        visible: trashModel.loading
        busy: true
        title: qsTr("正在读取回收站…")
    }

    // 彻底删除单个条目
    ConfirmDialog {
        id: purgeDialog
        title: qsTr("彻底删除")
        message: qsTr("「%1」将被永久删除，无法恢复。").arg(root.pendingRow.name || "")
        confirmText: qsTr("彻底删除")
        destructive: true
        onAccepted: trashModel.purgeRow(root.pendingIndex)
    }

    // 清空回收站
    ConfirmDialog {
        id: clearDialog
        title: qsTr("清空回收站")
        message: qsTr("共 %1 个条目将被永久删除，无法恢复。").arg(trashModel.count)
        confirmText: qsTr("清空")
        destructive: true
        onAccepted: trashModel.purgeAll()
    }

    ConfirmDialog {
        id: errorDialog
        title: qsTr("操作失败")
        confirmText: qsTr("知道了")
        showCancel: false
    }
}
