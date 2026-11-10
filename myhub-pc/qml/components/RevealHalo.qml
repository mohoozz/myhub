import QtQuick
import MyHub

/*
  「定位到原路径」的呼吸灯（PC-109）。

  只负责画：`active` 为真时描边呼吸，为假时整体淡出（不瞬间消失，避免闪烁）。
  何时亮、亮多久由目录页决定（约 10s 后自动熄灭）。
*/
Item {
    id: root

    property bool active: false
    property real cornerRadius: AppTheme.radiusInput
    property color haloColor: AppTheme.colors.primary

    // 外层负责淡入淡出：只被 active 的布尔值驱动，不与内层的呼吸动画抢 opacity
    opacity: root.active ? 1.0 : 0.0
    Behavior on opacity {
        NumberAnimation {
            duration: 220
            easing.type: Easing.OutQuad
        }
    }

    Rectangle {
        id: ring
        anchors.fill: parent
        radius: root.cornerRadius
        color: "transparent"
        border.width: 2
        border.color: root.haloColor

        SequentialAnimation on opacity {
            running: root.active
            loops: Animation.Infinite
            NumberAnimation {
                from: 0.25
                to: 0.95
                duration: 780
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 0.95
                to: 0.25
                duration: 780
                easing.type: Easing.InOutSine
            }
        }
    }
}
