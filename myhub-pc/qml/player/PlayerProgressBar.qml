import QtQuick
import MyHub

/*
  播放进度条（§14.6 PC-201）。

  - 已播放段用主色、轨道用白色低透明度（沉浸场景不引入其它色相）
  - 悬停 / 拖动时轨道变粗、显示圆形把手与目标时间气泡
  - 拖动过程中只更新本地比例，松手才真正 seek（避免 seek 风暴）
*/
Item {
    id: root

    property real positionMs: 0
    property real durationMs: 0
    property bool interactive: true

    signal seekRequested(real ms)

    implicitHeight: 20

    readonly property real ratio: durationMs > 0
                                   ? Math.max(0, Math.min(1, positionMs / durationMs))
                                   : 0
    /// 拖动中的比例（-1 表示未拖动）
    property real dragRatio: -1
    property real hoverX: -1
    readonly property bool active: dragRatio >= 0 || hoverX >= 0
    readonly property real shownRatio: dragRatio >= 0 ? dragRatio : ratio

    function ratioAt(x) {
        return Math.max(0, Math.min(1, x / Math.max(1, width)))
    }

    Rectangle {
        id: rail
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: root.active ? 5 : 3
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.22)
        Behavior on height { NumberAnimation { duration: Motion.fast } }
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: rail.width * root.shownRatio
        height: rail.height
        radius: rail.radius
        color: AppTheme.colors.primary
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 12
        radius: 6
        color: "#FFFFFF"
        visible: root.active && root.interactive
        x: Math.max(0, Math.min(root.width - width, rail.width * root.shownRatio - width / 2))
        scale: root.dragRatio >= 0 ? 1.15 : 1
        Behavior on scale { NumberAnimation { duration: Motion.fast } }
    }

    // 悬停时间气泡
    Rectangle {
        id: bubble
        readonly property real targetMs: root.durationMs * root.ratioAt(root.hoverX)

        visible: root.hoverX >= 0 && root.dragRatio < 0 && root.durationMs > 0
        x: Math.max(0, Math.min(root.width - width, root.hoverX - width / 2))
        y: -30
        width: bubbleText.implicitWidth + 16
        height: 24
        radius: AppTheme.radiusSmall
        color: Qt.rgba(0, 0, 0, 0.82)
        border.width: AppTheme.borderWidth
        border.color: Qt.rgba(1, 1, 1, 0.16)

        Text {
            id: bubbleText
            anchors.centerIn: parent
            text: Format.duration(bubble.targetMs)
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: "#FFFFFF"
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.topMargin: -8
        anchors.bottomMargin: -8
        enabled: root.interactive
        hoverEnabled: root.interactive
        cursorShape: Qt.PointingHandCursor

        onPressed: function(mouse) {
            root.dragRatio = root.ratioAt(mouse.x)
        }
        onPositionChanged: function(mouse) {
            if (mouse.pressed)
                root.dragRatio = root.ratioAt(mouse.x)
            else
                root.hoverX = mouse.x
        }
        onReleased: function(mouse) {
            if (root.dragRatio < 0)
                return
            const target = root.ratioAt(mouse.x)
            root.dragRatio = -1
            if (root.durationMs > 0)
                root.seekRequested(target * root.durationMs)
        }
        onExited: root.hoverX = -1
        onCanceled: root.dragRatio = -1
    }
}
