import QtQuick
import MyHub

/*
  连接状态圆点（PC-101）。

  正常绿点 / 异常红点 / 未知灰点 / 测试中呼吸动画。
  这是配色纪律中少数允许使用非主色的场合。
*/
Item {
    id: root

    /// undefined = 未测试；true = 可达；false = 不可达
    property var reachable: undefined
    property bool testing: false
    property real dotSize: 8

    implicitWidth: dotSize
    implicitHeight: dotSize

    Rectangle {
        id: dot
        anchors.centerIn: parent
        width: root.dotSize
        height: root.dotSize
        radius: width / 2
        color: {
            if (root.testing)
                return AppTheme.colors.textFaint
            if (root.reachable === undefined || root.reachable === null)
                return AppTheme.colors.textFaint
            return root.reachable ? AppTheme.colors.stateOk : AppTheme.colors.stateBad
        }

        Behavior on color {
            ColorAnimation { duration: Motion.fast }
        }
    }

    // 测试中：呼吸动画
    SequentialAnimation {
        running: root.testing
        loops: Animation.Infinite
        alwaysRunToEnd: true

        NumberAnimation {
            target: dot; property: "opacity"
            from: 1.0; to: 0.3
            duration: 600; easing.type: Motion.easeInOut
        }
        NumberAnimation {
            target: dot; property: "opacity"
            from: 0.3; to: 1.0
            duration: 600; easing.type: Motion.easeInOut
        }
        onStopped: dot.opacity = 1.0
    }
}
