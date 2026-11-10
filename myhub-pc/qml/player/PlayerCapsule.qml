import QtQuick
import MyHub

/*
  中央数值反馈胶囊（§14.6 PC-703）。

  进度 / 音量 / 亮度 / 倍速的每次操作都必须给出**具体数值**，
  0.8s 后自动隐去（Motion.capsuleHideDelay）。
*/
Rectangle {
    id: root

    property string iconName: ""
    property string text: ""
    property bool shown: false

    function flash(icon, message) {
        iconName = icon
        text = message
        shown = true
        hideTimer.restart()
    }

    implicitWidth: content.implicitWidth + AppTheme.spacingLg * 2
    implicitHeight: 44
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.68)
    border.width: AppTheme.borderWidth
    border.color: Qt.rgba(1, 1, 1, 0.14)

    opacity: shown ? 1 : 0
    visible: opacity > 0
    scale: shown ? 1 : 0.94
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    Behavior on scale { NumberAnimation { duration: Motion.normal; easing.type: Motion.easeOut } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: AppTheme.spacingSm

        AppIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.iconName !== ""
            name: root.iconName
            width: 18
            height: 18
            color: "#FFFFFF"
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            font.bold: true
            color: "#FFFFFF"
        }
    }

    Timer {
        id: hideTimer
        interval: Motion.capsuleHideDelay
        onTriggered: root.shown = false
    }
}
