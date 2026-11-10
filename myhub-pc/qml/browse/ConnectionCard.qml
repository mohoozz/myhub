import QtQuick
import MyHub

/*
  连接源卡片（§3.1 浏览首页）。

  显示：类型图标 + 名称 + 挂载点 + 连接状态绿/红点 + 内外网文案。

  纪律：卡片状态与设置页连接源列表**由同一数据源驱动**，实时一致（§14.9）。
*/
Item {
    id: root

    property string name: ""
    property string typeName: ""
    property string typeDisplay: ""
    property string mountPoint: ""
    property string summary: ""
    property var reachable: undefined
    property bool testing: false
    property string statusText: ""

    signal clicked()
    signal testRequested()

    implicitHeight: 92

    readonly property string _typeIcon: {
        switch (typeName) {
        case "webdav": return "cloud"
        case "smb":    return "server"
        case "local":  return "hard-drive"
        default:       return "database"
        }
    }

    CellPressHighlight {
        anchors.fill: parent
        hovered: mouse.containsMouse
        pressed: mouse.pressed
        inset: 0
        radius: AppTheme.radiusCard
    }

    // 卡片本体（统一描边 1pt）
    Rectangle {
        anchors.fill: parent
        radius: AppTheme.radiusCard
        color: "transparent"
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    Item {
        anchors.fill: parent
        anchors.margins: AppTheme.spacingLg

        AppIcon {
            id: typeIcon
            name: root._typeIcon
            width: 30
            height: 30
            anchors.left: parent.left
            anchors.top: parent.top
            color: AppTheme.colors.primary
        }

        Column {
            anchors.left: typeIcon.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.right: statusCol.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: typeIcon.verticalCenter
            spacing: 3

            Text {
                width: parent.width
                text: root.name
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeHeading
                color: AppTheme.colors.textPrimary
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: root.typeDisplay + " · " + root.mountPoint
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
                elide: Text.ElideRight
            }
        }

        // 状态：绿点 / 红点 + 内外网文案
        Row {
            id: statusCol
            anchors.right: parent.right
            anchors.verticalCenter: typeIcon.verticalCenter
            spacing: AppTheme.spacingSm

            Text {
                text: root.statusText
                anchors.verticalCenter: parent.verticalCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: {
                    if (root.testing)
                        return AppTheme.colors.textSecondary
                    if (root.reachable === undefined || root.reachable === null)
                        return AppTheme.colors.textFaint
                    return root.reachable ? AppTheme.colors.stateOk
                                          : AppTheme.colors.stateBad
                }
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 160)
            }

            StatusDot {
                anchors.verticalCenter: parent.verticalCenter
                reachable: root.reachable
                testing: root.testing
            }
        }

        // 地址摘要
        Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: root.summary
            visible: text !== ""
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            color: AppTheme.colors.textFaint
            elide: Text.ElideMiddle
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
