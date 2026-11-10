pragma ComponentBehavior: Bound

import QtQuick
import MyHub

/*
  正在播放：三竖条均衡器（§3.1 状态指示）。

  纪律：
    · 只用主色，不引入其它色相（§2.10）
    · 暂停/加载时不空转（running 绑 active），停在静态高度上
    · 尺寸由调用方给（列表 14 高、网格角标 12 高），组件本身不自作主张
*/
Item {
    id: root

    /// 动画开关：仅「正在播放」时为 true，暂停/缓冲时静止
    property bool active: true
    property color color: AppTheme.colors.primary
    property real barWidth: 2.5
    property real barGap: 2

    implicitWidth: barWidth * 3 + barGap * 2
    implicitHeight: 14

    Row {
        anchors.centerIn: parent
        spacing: root.barGap

        Repeater {
            model: 3

            Item {
                id: slot
                required property int index

                width: root.barWidth
                height: root.implicitHeight

                Rectangle {
                    id: fill
                    anchors.bottom: parent.bottom
                    width: parent.width
                    radius: width / 2
                    color: root.color
                    // 暂停/未播放时的静态高度；动画运行期间由动画改写该属性
                    height: slot.height * (0.3 + 0.12 * slot.index)

                    SequentialAnimation {
                        running: root.active
                        loops: Animation.Infinite
                        // 三根相位错开，看起来像在跑，而不是齐刷刷上下跳
                        PauseAnimation { duration: 90 * slot.index }
                        PropertyAnimation {
                            target: fill
                            property: "height"
                            to: slot.height * 0.95
                            duration: 300 + 80 * slot.index
                            easing.type: Easing.InOutQuad
                        }
                        PropertyAnimation {
                            target: fill
                            property: "height"
                            to: slot.height * 0.28
                            duration: 300 + 80 * slot.index
                            easing.type: Easing.InOutQuad
                        }
                    }
                }
            }
        }
    }
}
