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

        PlayerButton {
            iconName: "lock"
            tooltip: qsTr("锁定界面 (L)")
            onClicked: root.lockRequested()
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
