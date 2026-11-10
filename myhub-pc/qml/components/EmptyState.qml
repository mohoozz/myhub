import QtQuick
import MyHub

/*
  状态占位（§3.1 四态：加载 / 空目录 / 搜索无结果 / 错误）。
*/
Item {
    id: root

    property string iconName: "inbox"
    property string title: ""
    property string description: ""
    property string actionText: ""
    property bool busy: false

    signal actionTriggered()

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 360)
        spacing: AppTheme.spacingMd

        // 加载态：旋转指示器
        Item {
            width: 48
            height: 48
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.busy

            // 底环
            Rectangle {
                anchors.centerIn: parent
                width: 28
                height: 28
                radius: width / 2
                color: "transparent"
                border.width: 2.5
                border.color: AppTheme.colors.primary
                opacity: 0.22
            }

            // 旋转的进度弧（用遮挡矩形裁出缺口）
            Item {
                id: arc
                anchors.centerIn: parent
                width: 28
                height: 28

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2.5
                    border.color: AppTheme.colors.primary
                }
                Rectangle {
                    width: parent.width / 2 + 2
                    height: parent.height / 2 + 2
                    color: AppTheme.colors.pageBg
                    anchors.right: parent.right
                    anchors.top: parent.top
                }
            }

            RotationAnimation {
                target: arc
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.busy && root.visible
            }
        }

        AppIcon {
            name: root.iconName
            visible: !root.busy && root.iconName !== ""
            width: 44
            height: 44
            anchors.horizontalCenter: parent.horizontalCenter
            color: AppTheme.colors.textFaint
            strokeWidth: 1.4
        }

        Text {
            width: parent.width
            visible: root.title !== ""
            text: root.title
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            color: AppTheme.colors.textPrimary
            wrapMode: Text.Wrap
        }

        Text {
            width: parent.width
            visible: root.description !== ""
            text: root.description
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.textSecondary
            wrapMode: Text.Wrap
            lineHeight: 1.4
        }

        PrimaryButton {
            visible: root.actionText !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.actionText
            variant: PrimaryButton.Secondary
            onClicked: root.actionTriggered()
        }
    }
}
