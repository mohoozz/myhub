import QtQuick
import MyHub

/*
  侧边栏导航项（§2.2.1）。

  - 选中项：浅蓝胶囊高亮（与 iOS 一致）
  - 折叠态：仅图标，hover 浮出文字提示
*/
Item {
    id: root

    property string iconName: ""
    property string label: ""
    property bool selected: false
    property bool collapsed: false

    signal clicked()

    implicitHeight: 40

    Rectangle {
        id: capsule
        anchors.fill: parent
        anchors.leftMargin: AppTheme.spacingSm
        anchors.rightMargin: AppTheme.spacingSm
        radius: AppTheme.radiusInput + 2

        // 选中为浅蓝胶囊
        color: {
            if (root.selected)
                return AppTheme.colors.primaryWeak
            if (mouse.containsMouse)
                return AppTheme.colors.hoverFill
            return "transparent"
        }

        Behavior on color { ColorAnimation { duration: Motion.fast } }

        AppIcon {
            id: icon
            name: root.iconName
            width: 19
            height: 19
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: root.collapsed
                ? (parent.width - width) / 2
                : AppTheme.spacingMd
            color: root.selected ? AppTheme.colors.primary
                                 : AppTheme.colors.textSecondary

            Behavior on anchors.leftMargin {
                NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut }
            }
        }

        Text {
            anchors.left: icon.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            visible: !root.collapsed
            opacity: root.collapsed ? 0 : 1
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            font.bold: root.selected
            color: root.selected ? AppTheme.colors.primary
                                 : AppTheme.colors.textPrimary

            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    // 折叠态 hover 浮出文字（§2.2.1）
    Rectangle {
        id: tooltip
        visible: root.collapsed && mouse.containsMouse
        x: parent.width + 6
        anchors.verticalCenter: parent.verticalCenter
        width: tooltipText.implicitWidth + AppTheme.spacingMd * 2
        height: 30
        radius: AppTheme.radiusSmall
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
        z: 100

        Text {
            id: tooltipText
            anchors.centerIn: parent
            text: root.label
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.textPrimary
        }
    }
}
