import QtQuick
import MyHub

/*
  工具栏图标按钮（§2.10）。
  按压动画 + hover 高亮 + 可选忙碌指示。
*/
Item {
    id: root

    property string iconName: ""
    property string tooltip: ""
    /// 气泡朝上（贴近窗口底部的工具条用，避免提示被裁掉）
    property bool tooltipAbove: false
    property bool busy: false

    signal clicked()

    implicitWidth: 34
    implicitHeight: 34

    opacity: enabled ? 1.0 : 0.4

    scale: mouse.pressed ? AppTheme.pressScale : 1.0
    Behavior on scale {
        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut }
    }

    Rectangle {
        anchors.fill: parent
        radius: AppTheme.radiusSmall
        color: mouse.containsMouse && root.enabled
            ? AppTheme.colors.hoverFill : "transparent"
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    AppIcon {
        id: icon
        anchors.centerIn: parent
        name: root.iconName
        width: 17
        height: 17
        color: AppTheme.colors.textSecondary
    }

    // 忙碌时旋转（刷新中指示）。
    // 用独立动画对象驱动，避免把 Animator 的 running 误当作图标自身属性。
    RotationAnimation {
        target: icon
        from: 0
        to: 360
        duration: 800
        loops: Animation.Infinite
        running: root.busy
        onStopped: icon.rotation = 0
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    // 简易气泡提示
    Rectangle {
        visible: root.tooltip !== "" && mouse.containsMouse
        y: root.tooltipAbove ? -height - 4 : root.height + 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: tipText.implicitWidth + AppTheme.spacingMd
        height: 26
        radius: AppTheme.radiusSmall
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
        z: 200

        Text {
            id: tipText
            anchors.centerIn: parent
            text: root.tooltip
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            color: AppTheme.colors.textSecondary
        }
    }
}
