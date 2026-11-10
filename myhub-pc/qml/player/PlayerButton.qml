import QtQuick
import MyHub

/*
  播放器专用按钮（§14.6）。

  与工具栏 ToolbarButton 分开的原因：ToolbarButton 的悬停底色取主题卡片色，
  而播放器是强制纯黑沉浸场景，浅色块会破坏画面；这里统一用白色低透明度叠加。
*/
Item {
    id: root

    /// 图标名（Icons.qml）；与 text 二选一
    property string iconName: ""
    /// 纯文本按钮（如倍速 1.0×）
    property string text: ""
    property int iconSize: 20
    /// 实心图标（play / pause / rewind / forward）
    property bool filled: false
    /// 常亮选中态（如按钮对应的菜单已展开）
    property bool active: false
    property color color: "#FFFFFF"
    property string tooltip: ""

    signal clicked()

    implicitWidth: text !== "" ? 58 : 40
    implicitHeight: 40

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.active
               ? Qt.rgba(1, 1, 1, 0.16)
               : Qt.rgba(1, 1, 1, mouse.containsMouse ? 0.10 : 0)
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    AppIcon {
        anchors.centerIn: parent
        visible: root.iconName !== ""
        name: root.iconName
        width: root.iconSize
        height: root.iconSize
        color: root.color
        filled: root.filled
    }

    Text {
        anchors.centerIn: parent
        visible: root.text !== ""
        text: root.text
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeBody
        font.bold: true
        color: root.color
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    scale: mouse.pressed ? AppTheme.pressScale : 1
    Behavior on scale { NumberAnimation { duration: Motion.fast } }
}
