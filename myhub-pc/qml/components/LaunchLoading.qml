import QtQuick
import MyHub

/*
  启动 Loading（§2.2.4 / §14.4）。

  纪律：**启动期必须有 loading 动画，不得出现长白屏**。
*/
Rectangle {
    id: root

    property string statusText: ""

    color: AppTheme.colors.pageBg

    Column {
        anchors.centerIn: parent
        spacing: AppTheme.spacingLg

        // 品牌图标 + 旋转环
        Item {
            width: 72
            height: 72
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
                anchors.centerIn: parent
                width: 56
                height: 56
                radius: AppTheme.radiusCard
                color: AppTheme.colors.primary

                AppIcon {
                    anchors.centerIn: parent
                    name: "folder"
                    width: 30
                    height: 30
                    color: AppTheme.colors.textOnPrimary
                }
            }

            // 旋转指示环
            Item {
                id: ring
                anchors.centerIn: parent
                width: 72
                height: 72

                Rectangle {
                    width: 7
                    height: 7
                    radius: 3.5
                    color: AppTheme.colors.primary
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                }

            }

            RotationAnimation {
                target: ring
                from: 0
                to: 360
                duration: 1100
                loops: Animation.Infinite
                running: root.visible
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "MyHub"
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTitle
            font.bold: true
            color: AppTheme.colors.textPrimary
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.statusText
            visible: text !== ""
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.textSecondary
        }
    }
}
