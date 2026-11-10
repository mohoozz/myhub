import QtQuick
import MyHub

/*
  mini 播放条（§4.4 / PC-603）。

  职责：跨页面常驻的「最小呈现位」——实时画面预览 / 封面 + 标题 + 进度细条
  + 播放暂停 + 展开 + 关闭。它**不持有播放会话，也不持有渲染面**：
  预览画面由 PlayerVideoLayer 按本条的预览块几何贴上来，
  因此点开回到全屏时进度不回到 0、也不会重新起播。

  视觉纪律：
    · 深浅色都描 1pt 边，描边色取统一 token（AppTheme.colors.separator）
    · 音频无封面时的占位块**必须不透明**，不得透出下层内容
    · 高度取 AppTheme.miniPlayerHeight，与底部装饰统一
*/
Item {
    id: root

    signal expandRequested()
    signal closeRequested()

    height: AppTheme.miniPlayerHeight

    readonly property real progress: Player.durationMs > 0
        ? Math.max(0, Math.min(1, Player.positionMs / Player.durationMs))
        : 0

    // 底部常驻条：不透明底色 + 统一描边
    Rectangle {
        anchors.fill: parent
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.separator
    }

    // ---- 顶部进度细条（可点击 / 拖动定位）----
    Item {
        id: progressArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 6
        z: 2

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 2
            color: AppTheme.colors.separator
        }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            height: progressMouse.containsMouse || progressMouse.pressed ? 4 : 2
            width: progressArea.width * root.progress
            color: AppTheme.colors.primary

            Behavior on height { NumberAnimation { duration: Motion.fast } }
        }

        MouseArea {
            id: progressMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: function(mouse) { seekToX(mouse.x) }
            onPositionChanged: function(mouse) {
                if (mouse.pressed)
                    seekToX(mouse.x)
            }

            function seekToX(x) {
                if (Player.durationMs <= 0)
                    return
                const ratio = Math.max(0, Math.min(1, x / Math.max(1, width)))
                Player.seekTo(Math.round(Player.durationMs * ratio))
            }
        }
    }

    // ---- 画面预览 / 封面 ----
    Item {
        id: previewBox
        anchors.left: parent.left
        anchors.leftMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        width: 96
        height: 48
        clip: true

        // 渲染面不挂在这里：PlayerVideoLayer 按本块的位置/尺寸贴上来
        // （见 PlayerVideoLayer 的注释 —— 重挂载会让 mpv 渲染节点重建）

        // 音频封面：与全屏封面、列表缩略图同源同缓存（§4.3）
        // 无封面时 CoverImage 内部是不透明占位（fieldFill + 音符图标），
        // 不会透出下层内容；描边由外层统一补，保证深浅色一致
        CoverImage {
            id: audioCover
            anchors.fill: parent
            visible: !Player.hasVideo
            connectionId: Player.currentConnectionId
            filePath: Player.currentPath
            mediaKind: "audio"
            radius: AppTheme.radiusSmall
            cropFill: true
            iconRatio: 0.5
        }

        Rectangle {
            anchors.fill: parent
            visible: !Player.hasVideo
            radius: AppTheme.radiusSmall
            color: "transparent"
            border.width: AppTheme.borderWidth
            border.color: AppTheme.colors.separator
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expandRequested()
        }
    }

    // ---- 标题 / 状态 / 时间 ----
    Column {
        anchors.left: previewBox.right
        anchors.leftMargin: AppTheme.spacingMd
        anchors.right: actions.left
        anchors.rightMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Text {
            width: parent.width
            text: Player.title
            elide: Text.ElideMiddle
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            font.bold: true
            color: AppTheme.colors.textPrimary
        }

        Text {
            width: parent.width
            text: root.statusText() + " · " + Format.duration(Player.positionMs)
                  + " / " + (Player.durationMs > 0 ? Format.duration(Player.durationMs) : "--:--")
            elide: Text.ElideRight
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.textSecondary
        }
    }

    function statusText() {
        switch (Player.state) {
        case Player.Loading:
            return qsTr("加载中")
        case Player.Playing:
            return qsTr("播放中")
        case Player.Paused:
            return qsTr("已暂停")
        case Player.Ended:
            return qsTr("已播完")
        case Player.Error:
            return qsTr("播放失败")
        default:
            return qsTr("准备就绪")
        }
    }

    // ---- 操作：展开 / 播放暂停 / 关闭 ----
    Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: AppTheme.spacingSm
        anchors.verticalCenter: parent.verticalCenter
        spacing: AppTheme.spacingXs

        ToolbarButton {
            iconName: "maximize"
            tooltip: qsTr("回到完整播放")
            onClicked: root.expandRequested()
        }

        ToolbarButton {
            iconName: Player.state === Player.Playing ? "pause"
                      : (Player.state === Player.Ended ? "replay" : "play")
            tooltip: Player.state === Player.Playing ? qsTr("暂停") : qsTr("播放")
            onClicked: Player.togglePause()
        }

        ToolbarButton {
            iconName: "x"
            tooltip: qsTr("停止播放")
            onClicked: root.closeRequested()
        }
    }

    // 点击标题/空白处即展开（预览块与按钮各有自己的交互，不冒泡）
    MouseArea {
        anchors.left: previewBox.right
        anchors.right: actions.left
        anchors.top: progressArea.bottom
        anchors.bottom: parent.bottom
        cursorShape: Qt.PointingHandCursor
        onClicked: root.expandRequested()
    }

    // 把预览块的位置/尺寸登记给渲染层（视频预览贴在上面，不搬运渲染面）
    Component.onCompleted: PlayerStage.previewTarget = previewBox
    Component.onDestruction: {
        if (PlayerStage.previewTarget === previewBox)
            PlayerStage.previewTarget = null
    }
}
