import QtQuick
import MyHub

/*
  播放器底部控制层（§14.6 PC-201）。

  进度条 + 播放控制 + 时间 + 倍速 / 字幕 / 音轨 / 锁定 / 全屏。
  手机端的手势在这里对应为键盘快捷键，按钮本身只负责点击。
*/
Item {
    id: root

    property bool fullScreen: false

    signal osdRequested(string icon, string text)
    signal speedMenuRequested(var anchor)
    signal subtitleMenuRequested(var anchor)
    signal audioMenuRequested(var anchor)
    signal lockRequested()

    /// 有按钮正在长按（锁按钮）：控制层别在这时自动隐藏，否则长按被打断
    readonly property bool holdActive: lockButton.holdProgress > 0
    signal fullScreenRequested()

    implicitHeight: 92

    PlayerProgressBar {
        id: progress
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: AppTheme.spacingXl
        anchors.rightMargin: AppTheme.spacingXl
        anchors.top: parent.top
        positionMs: Player.positionMs
        durationMs: Player.durationMs

        onSeekRequested: function(ms) {
            Player.seekTo(ms)
            root.osdRequested("forward", Format.duration(ms))
        }
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 10
        spacing: AppTheme.spacingXs

        PlayerButton {
            iconName: "rewind"
            filled: true
            tooltip: qsTr("快退 (←)")
            onClicked: root.seekBy(-Player.seekStepSeconds * 1000)
        }

        Item {
            width: 52
            height: 52

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Qt.rgba(1, 1, 1, 0.12)
            }

            PlayerButton {
                anchors.centerIn: parent
                iconName: Player.state === Player.Playing ? "pause" : "play"
                filled: true
                iconSize: 24
                tooltip: qsTr("播放 / 暂停 (Space)")
                onClicked: Player.togglePause()
            }
        }

        PlayerButton {
            iconName: "forward"
            filled: true
            tooltip: qsTr("快进 (→)")
            onClicked: root.seekBy(Player.seekStepSeconds * 1000)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Format.duration(Player.positionMs) + " / " + Format.duration(Player.durationMs)
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            font.bold: true
            color: Qt.rgba(1, 1, 1, 0.86)
        }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 10
        spacing: AppTheme.spacingXs

        // 音量（§14.6）：图标按钮管静音，右侧滑条管大小；拖动时中央胶囊报百分比。
        // 滑条常驻而不是悬停展开 —— 播放器底部本来就有留白，常驻少一次悬停动作
        PlayerButton {
            id: volumeButton
            iconName: Player.muted || Player.volume <= 0.001 ? "volume-x"
                      : (Player.volume < 0.5 ? "volume-1" : "volume")
            tooltip: Player.followSystemVolume
                     ? qsTr("跟随系统音量（用系统音量键调）")
                     : (Player.muted ? qsTr("取消静音 (M)") : qsTr("静音 (M)"))
            onClicked: {
                if (Player.followSystemVolume) {
                    root.osdRequested("volume", qsTr("音量跟随系统"))
                    return
                }
                Player.toggleMute()
                root.osdRequested(Player.muted ? "volume-x" : "volume",
                                  Player.muted ? qsTr("静音")
                                               : qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
            }
        }

        Item {
            id: volumeSlider
            width: 84
            height: 26
            // 窄窗口先让位给播放/字幕/全屏那几个按钮；静音按钮始终在，功能不丢
            visible: root.width >= 760
            anchors.verticalCenter: parent.verticalCenter
            opacity: Player.followSystemVolume ? 0.35 : 1

            readonly property real value: Math.max(0, Math.min(1, Player.volume))

            Behavior on opacity { NumberAnimation { duration: Motion.fast } }

            Rectangle {
                id: volumeTrack
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                height: 3
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.26)
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: volumeTrack.width * volumeSlider.value
                height: volumeTrack.height
                radius: volumeTrack.radius
                color: Qt.rgba(1, 1, 1, 0.92)
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min(volumeTrack.width - width,
                                         volumeTrack.width * volumeSlider.value - width / 2))
                width: 12
                height: 12
                radius: 6
                color: "#FFFFFF"
                border.width: AppTheme.borderWidth
                border.color: Qt.rgba(0, 0, 0, 0.18)
            }

            MouseArea {
                anchors.fill: parent
                enabled: !Player.followSystemVolume
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                hoverEnabled: true

                function applyAt(x) {
                    const ratio = volumeTrack.width > 0
                                  ? Math.max(0, Math.min(1, x / volumeTrack.width)) : 0
                    Player.volume = ratio
                    root.osdRequested(ratio <= 0.001 ? "volume-x" : "volume",
                                      qsTr("音量 %1%").arg(Math.round(ratio * 100)))
                }

                onPressed: function(mouse) { applyAt(mouse.x) }
                onPositionChanged: function(mouse) {
                    if (pressed)
                        applyAt(mouse.x)
                }
                onDoubleClicked: {
                    Player.volume = 1.0
                    root.osdRequested("volume", qsTr("音量 100%"))
                }
            }
        }

        PlayerButton {
            id: speedButton
            text: root.formatSpeed(Player.speed)
            tooltip: qsTr("播放速度")
            onClicked: root.speedMenuRequested(speedButton)
        }

        PlayerButton {
            id: subtitleButton
            iconName: "subtitle"
            tooltip: qsTr("字幕")
            onClicked: root.subtitleMenuRequested(subtitleButton)
        }

        PlayerButton {
            id: audioButton
            iconName: "music"
            tooltip: qsTr("音轨")
            visible: Player.audioTracks.length > 1
            onClicked: root.audioMenuRequested(audioButton)
        }

        // 界面锁定（§14.6）：长按 0.65s 触发，环跟着按住时长走；
        // 短按只提示「长按」，避免想点全屏却把界面锁了
        Item {
            width: 40
            height: 40

            PlayerButton {
                id: lockButton
                anchors.fill: parent
                iconName: "lock"
                tooltip: qsTr("长按锁定界面（或按 L）")
                holdDuration: 650
                onHeld: root.lockRequested()
                onClicked: root.osdRequested("lock", qsTr("长按 0.6 秒锁定界面"))
            }

            ProgressRing {
                anchors.fill: parent
                anchors.margins: 1
                visible: lockButton.holdProgress > 0.001
                progress: lockButton.holdProgress
                strokeWidth: 2.2
                trackColor: Qt.rgba(1, 1, 1, 0.18)
                indicatorColor: "#FFFFFF"
            }
        }

        PlayerButton {
            iconName: root.fullScreen ? "minimize" : "maximize"
            tooltip: root.fullScreen ? qsTr("退出全屏 (F)") : qsTr("全屏 (F)")
            onClicked: root.fullScreenRequested()
        }
    }

    function seekBy(deltaMs) {
        const target = Math.max(0, Math.min(Player.durationMs > 0 ? Player.durationMs : Number.MAX_SAFE_INTEGER,
                                         Player.positionMs + deltaMs))
        Player.seekBy(deltaMs)
        root.osdRequested(deltaMs < 0 ? "rewind" : "forward", Format.duration(target))
    }

    function formatSpeed(speed) {
        const text = (Math.round(speed * 100) / 100).toFixed(2).replace(/0+$/, "")
        return (text.endsWith(".") ? text + "0" : text) + "×"
    }
}
