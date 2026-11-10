import QtQuick
import MyHub

/*
  置顶悬浮小窗的内容层（§4.4 PC-603）。

  窗口本身由 `WindowController.enterFloating()` 变身而来（无边框 + 置顶 + 小尺寸），
  这里只负责小窗里的最小控制集：播放暂停 / 进度 / 音量 / 还原 / 关闭。

  纪律：
    · 视频面仍由玩家 VideoLayer（z 490）呈现，本层 z 更高、背景全透明，
      所以小窗里看不到「另一个播放器」，只有一条压在画面上的控制带
    · 全部交互都不碰会话：还原回主窗口只改窗口形态与呈现位，不重载、不丢进度
    · 播放中控制带跟着鼠标显隐（移入显示、移出收起）；暂停时保持常显
    · 无边框窗口没有系统标题栏：顶部条负责拖动，四边热区负责缩放
*/
Item {
    id: root

    visible: PlayerStage.floating
    focus: visible

    readonly property bool playing: Player.state === Player.Playing

    /**
     * 控制带可见性：鼠标在小窗内就显示，移出即收起；暂停时保持常显。
     *
     * 这里刻意**不用 QML Timer 做「3s 自动隐去」**：小窗是靠改窗口 flags 变身来的，
     * 窗口重建后 QML 侧的 Timer 在本机实测不再回调（C++ 的 QTimer 正常），
     * 用 Timer 会让控制条永远不隐。HoverHandler 只依赖鼠标事件，行为可预测。
     */
    readonly property bool chromeVisible: hoverHandler.hovered || !playing

    onVisibleChanged: if (visible) forceActiveFocus()

    HoverHandler {
        id: hoverHandler
    }

    // 音频 / 纯音频模式：小窗里给个居中封面，别留一块黑
    CoverImage {
        anchors.centerIn: parent
        width: Math.min(root.width, root.height) * 0.62
        height: width
        radius: width / 2
        visible: !Player.hasVideo
        connectionId: Player.currentConnectionId
        filePath: Player.currentPath
        mediaKind: "audio"
        cropFill: true
        iconRatio: 0.42
    }

    // 画面区：单击播放 / 暂停，双击还原回主窗口
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true

        onClicked: Player.togglePause()
        onDoubleClicked: PlayerStage.restoreFromFloating()
    }

    // ---------------------------------------------------------------- 顶部条

    Rectangle {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 30
        color: Qt.rgba(0, 0, 0, 0.58)
        opacity: root.chromeVisible ? 1 : 0
        visible: opacity > 0

        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

        // 拖动区：无边框窗口自己实现系统拖动（带 Windows 的贴边 / 多屏吸附）
        MouseArea {
            anchors.fill: parent
            onPressed: WindowController.startSystemMove()
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingSm
            anchors.right: actionRow.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            text: Player.title
            elide: Text.ElideMiddle
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            color: "#FFFFFF"
        }

        Row {
            id: actionRow
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            PlayerButton {
                iconName: "maximize"
                tooltip: qsTr("还原回主窗口 (Esc)")
                implicitWidth: 30
                implicitHeight: 26
                iconSize: 14
                onClicked: PlayerStage.restoreFromFloating()
            }

            PlayerButton {
                iconName: "x"
                tooltip: qsTr("关闭播放")
                implicitWidth: 30
                implicitHeight: 26
                iconSize: 14
                onClicked: Player.close()
            }
        }
    }

    // ---------------------------------------------------------------- 底部条

    Rectangle {
        id: bottomBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 48
        color: Qt.rgba(0, 0, 0, 0.62)
        opacity: root.chromeVisible ? 1 : 0
        visible: opacity > 0

        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

        PlayerProgressBar {
            id: progress
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: AppTheme.spacingSm
            anchors.rightMargin: AppTheme.spacingSm
            anchors.top: parent.top
            anchors.topMargin: 2
            height: 18
            positionMs: Player.positionMs
            durationMs: Player.durationMs
            onSeekRequested: function(ms) {
                Player.seekTo(ms)
            }
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingSm
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            spacing: AppTheme.spacingXs

            PlayerButton {
                id: playButton
                iconName: root.playing ? "pause" : "play"
                tooltip: root.playing ? qsTr("暂停 (空格)") : qsTr("播放 (空格)")
                implicitWidth: 30
                implicitHeight: 26
                iconSize: 16
                onClicked: Player.togglePause()
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Format.duration(Player.positionMs) + " / " + Format.duration(Player.durationMs)
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
                color: Qt.rgba(1, 1, 1, 0.72)
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingSm
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            spacing: AppTheme.spacingXs

            // 音量：小窗里不展开滑杆，点图标静音、滚轮微调
            PlayerButton {
                id: volumeButton
                iconName: Player.muted || Player.volume <= 0.001
                          ? "volume-x"
                          : (Player.volume < 0.5 ? "volume-1" : "volume")
                tooltip: qsTr("静音（滚轮调音量）")
                implicitWidth: 30
                implicitHeight: 26
                iconSize: 16
                onClicked: Player.toggleMute()
            }

            WheelHandler {
                onWheel: function(event) {
                    Player.adjustVolume(event.angleDelta.y > 0 ? Player.volumeStep
                                                               : -Player.volumeStep)
                }
            }
        }
    }

    // ---------------------------------------------------------------- 缩放热区

    // 无边框窗口没有系统边框：四边各留 5px 热区交给 startSystemResize
    MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 5
        cursorShape: Qt.SizeHorCursor
        onPressed: WindowController.startSystemResize(Qt.LeftEdge)
    }

    MouseArea {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 5
        cursorShape: Qt.SizeHorCursor
        onPressed: WindowController.startSystemResize(Qt.RightEdge)
    }

    MouseArea {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 5
        cursorShape: Qt.SizeVerCursor
        onPressed: WindowController.startSystemResize(Qt.TopEdge)
    }

    MouseArea {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 5
        cursorShape: Qt.SizeVerCursor
        onPressed: WindowController.startSystemResize(Qt.BottomEdge)
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            PlayerStage.restoreFromFloating()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Space) {
            Player.togglePause()
            event.accepted = true
        }
    }
}
