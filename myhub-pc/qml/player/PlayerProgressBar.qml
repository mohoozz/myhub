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

    /// 按下点（x 像素）与按下时的播放位置，拖动按「相对位移」换算，不做绝对定位
    property real pressX: 0
    property real pressMs: 0
    /// 位移超过阈值才算拖动；3px 以内当作点击（点击仍是绝对跳转，用来远跳）
    property bool dragging: false
    readonly property real dragThresholdPx: 3

    function ratioAt(x) {
        return Math.max(0, Math.min(1, x / Math.max(1, width)))
    }

    /**
     * 拖动位移 → 时间偏移（§14.6「拖动跨度随距离分级」）。
     *
     * 绝对定位在长片上太灵敏：两小时片子拖 2px 就是几分钟，想微调 5 秒根本做不到。
     * 这里按位移分三档，慢起快收：
     *   0~24px   0.08s/px ≈ 2 秒（想精调几秒就够用，手不抖）
     *   24~96px  0.25s/px ≈ 再加 18 秒（常规拖动）
     *   >96px    1.0s/px（快速拉，但整体仍被 clamp 住）
     * 总跨度封顶 60s（短片按片长 3/4 收窄），远距离用点击而不是拖 —— 避免一拖 40 分钟。
     */
    function dragDeltaMs(dx) {
        const d = Math.abs(dx)
        const near = Math.min(d, 24) * 0.08
        const mid = Math.max(0, Math.min(d, 96) - 24) * 0.25
        const far = Math.max(0, d - 96) * 1.0
        const spanMs = (near + mid + far) * 1000
        const capMs = Math.min(60000, durationMs * 0.75)
        return (dx < 0 ? -1 : 1) * Math.min(spanMs, capMs)
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

    // 时间气泡：拖动时也显示 —— 拖动是相对位移，把手不再跟着指针，
    // 没有数值反馈就不知道松手会跳到哪
    Rectangle {
        id: bubble
        readonly property real targetRatio: root.dragRatio >= 0 ? root.dragRatio
                                                                : root.ratioAt(root.hoverX)
        readonly property real targetMs: root.durationMs * targetRatio
        readonly property real anchorX: root.dragRatio >= 0
                                        ? root.width * root.dragRatio : root.hoverX

        visible: root.durationMs > 0 && root.active
        x: Math.max(0, Math.min(root.width - width, anchorX - width / 2))
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
            root.pressX = mouse.x
            root.pressMs = root.positionMs
            root.dragging = false
            // 按下不改把手位置：拖动是从当前位置微调，先跳过去再微调等于白跳一次
            root.dragRatio = root.ratio
        }
        onPositionChanged: function(mouse) {
            if (!mouse.pressed) {
                root.hoverX = mouse.x
                return
            }
            if (!root.dragging && Math.abs(mouse.x - root.pressX) >= root.dragThresholdPx)
                root.dragging = true
            if (root.dragging) {
                const target = Math.max(0, Math.min(root.durationMs,
                        root.pressMs + root.dragDeltaMs(mouse.x - root.pressX)))
                root.dragRatio = root.durationMs > 0 ? target / root.durationMs : 0
            }
        }
        onReleased: function(mouse) {
            if (root.dragRatio < 0)
                return
            // 没拖动 = 点击：绝对跳到点中的位置（长片远跳走这条路，不靠拖）
            const ratio = root.dragging ? root.dragRatio : root.ratioAt(mouse.x)
            root.dragRatio = -1
            root.dragging = false
            if (root.durationMs > 0)
                root.seekRequested(ratio * root.durationMs)
        }
        onExited: root.hoverX = -1
        onCanceled: {
            root.dragRatio = -1
            root.dragging = false
        }
    }
}
