import QtQuick
import MyHub

// 列表委托访问外层 id，绑定组件上下文（qmllint 约定）
pragma ComponentBehavior: Bound

/*
  设置页的连接源列表（PC-501）。

  纪律：
    - 连接测试状态：正常绿点 / 异常红点，**状态持久化缓存**
    - **仅手动点击「测试连接」或重启应用才重新判定**（不得每次进入页面重测）
    - 与浏览页卡片**同一数据源**，状态实时一致
*/
Item {
    id: root

    signal addRequested()
    signal editRequested(var data)

    ConnectionListModel {
        id: allConnections
        enabledOnly: false
    }

    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 44

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("连接源")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: AppTheme.colors.textPrimary
        }

        PrimaryButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("添加")
            iconName: "plus"
            variant: PrimaryButton.Secondary
            onClicked: root.addRequested()
        }
    }

    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: AppTheme.spacingSm
        clip: true
        spacing: AppTheme.spacingSm
        model: allConnections

        delegate: Item {
            id: row
            required property int index
            required property string connectionId
            required property string name
            required property string type
            required property string typeDisplay
            required property string mountPoint
            required property string summary
            required property bool enabled
            required property var reachable
            required property bool testing
            required property string statusText

            width: list.width
            height: 76

            Rectangle {
                anchors.fill: parent
                radius: AppTheme.radiusCard
                color: rowMouse.containsMouse ? AppTheme.colors.hoverFill : "transparent"
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder
                Behavior on color { ColorAnimation { duration: Motion.fast } }
            }

            Item {
                anchors.fill: parent
                anchors.margins: AppTheme.spacingMd

                AppIcon {
                    id: typeIcon
                    name: row.type === "webdav" ? "cloud"
                        : row.type === "smb" ? "server" : "hard-drive"
                    width: 24
                    height: 24
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: row.enabled ? AppTheme.colors.primary
                                       : AppTheme.colors.textFaint
                }

                Column {
                    anchors.left: typeIcon.right
                    anchors.leftMargin: AppTheme.spacingMd
                    anchors.right: actions.left
                    anchors.rightMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Row {
                        spacing: AppTheme.spacingSm

                        Text {
                            text: row.name
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            font.bold: true
                            color: row.enabled ? AppTheme.colors.textPrimary
                                               : AppTheme.colors.textFaint
                        }
                        StatusDot {
                            anchors.verticalCenter: parent.verticalCenter
                            reachable: row.reachable
                            testing: row.testing
                        }
                        Text {
                            text: row.statusText
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTiny
                            color: {
                                if (row.testing)
                                    return AppTheme.colors.textSecondary
                                if (row.reachable === undefined || row.reachable === null)
                                    return AppTheme.colors.textFaint
                                return row.reachable ? AppTheme.colors.stateOk
                                                     : AppTheme.colors.stateBad
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        text: row.typeDisplay + " · " + row.mountPoint
                            + (row.summary !== "" ? "  ·  " + row.summary : "")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        elide: Text.ElideMiddle
                    }
                }

                Row {
                    id: actions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: AppTheme.spacingXs

                    ToolbarButton {
                        iconName: "refresh"
                        tooltip: qsTr("测试连接")
                        busy: row.testing
                        // 仅此处手动触发重新判定
                        onClicked: ConnectionStore.testConnection(row.connectionId, "")
                    }
                    ToolbarButton {
                        iconName: "edit"
                        tooltip: qsTr("编辑")
                        onClicked: root.editRequested(allConnections.get(row.index))
                    }
                    ToolbarButton {
                        iconName: "trash"
                        tooltip: qsTr("删除")
                        onClicked: {
                            deleteDialog.targetId = row.connectionId
                            deleteDialog.targetName = row.name
                            deleteDialog.open()
                        }
                    }
                }
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                // 让出按钮区域的点击
                acceptedButtons: Qt.NoButton
            }
        }

        EmptyState {
            anchors.fill: parent
            visible: allConnections.count === 0
            iconName: "database"
            title: qsTr("还没有连接源")
            description: qsTr("添加 WebDAV、SMB 或本地目录，开始管理你的媒体库。")
            actionText: qsTr("添加连接源")
            onActionTriggered: root.addRequested()
        }
    }

    // 删除确认（居中圆角，§14.4）
    ConfirmDialog {
        id: deleteDialog
        property string targetId: ""
        property string targetName: ""

        title: qsTr("删除连接源")
        message: qsTr("确定要删除「%1」吗？\n\n此操作会同时清除该连接源保存的账号凭据与目录缓存，但不会影响服务器上的任何文件。")
            .arg(targetName)
        confirmText: qsTr("删除")
        destructive: true

        onAccepted: ConnectionStore.removeById(targetId)
    }
}
