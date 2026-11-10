import QtQuick
import MyHub

/*
  播放器顶部控制层（§14.6）。

  左：退出 + 标题；右：纯音频模式、音量、更多。
  声音/亮度的数值反馈统一交给外层胶囊显示。
*/
Item {
    id: root

    /// 数值反馈（由 PlayerView 的中央胶囊呈现）
    signal osdRequested(string icon, string text)
    signal closeRequested()
    signal minimizeRequested()
    signal floatingRequested()
    signal moreMenuRequested(var anchor)

    implicitHeight: 56

    PlayerButton {
        id: closeButton
        anchors.left: parent.left
        anchors.leftMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        iconName: "x"
        tooltip: qsTr("退出播放 (Esc)")
        onClicked: root.closeRequested()
    }

    Text {
        anchors.left: closeButton.right
        anchors.leftMargin: AppTheme.spacingSm
        anchors.right: actionRow.left
        anchors.rightMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        text: Player.title
        elide: Text.ElideMiddle
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeHeading
        color: "#FFFFFF"
    }

    Row {
        id: actionRow
        anchors.right: parent.right
        anchors.rightMargin: AppTheme.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        spacing: AppTheme.spacingXs

        // ---- 置顶悬浮小窗（§4.4，替代画中画）----
        PlayerButton {
            id: floatingButton
            iconName: "pip"
            tooltip: qsTr("悬浮小窗 (Ctrl+P)")
            onClicked: root.floatingRequested()
        }

        // ---- 收进 mini 播放条（退出按钮是直接退出，二者分开，§4.4）----
        PlayerButton {
            id: minimizeButton
            iconName: "minimize"
            tooltip: qsTr("收进 mini 播放条 (Ctrl+M)")
            onClicked: root.minimizeRequested()
        }

        // ---- 纯音频模式（PC-206）----
        PlayerButton {
            id: audioOnlyButton
            iconName: "music"
            active: Player.audioOnly
            tooltip: qsTr("纯音频模式")
            onClicked: {
                Player.toggleAudioOnly()
                root.osdRequested("music", Player.audioOnly ? qsTr("纯音频模式：开") : qsTr("纯音频模式：关"))
            }
        }

        // ---- 音量：悬停展开滑杆 ----
        Item {
            id: volumeArea
            width: muteButton.width + volumeSlider.width
            height: muteButton.height
            anchors.verticalCenter: parent.verticalCenter

            PlayerButton {
                id: muteButton
                anchors.right: parent.right
                iconName: Player.muted || Player.volume <= 0.001
                          ? "volume-x"
                          : (Player.volume < 0.5 ? "volume-1" : "volume")
                tooltip: qsTr("静音 (M)")
                onClicked: {
                    Player.toggleMute()
                    root.osdRequested(Player.muted ? "volume-x" : "volume",
                                      Player.muted ? qsTr("静音") : qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
                }
            }

            Item {
                id: volumeSlider
                anchors.right: muteButton.left
                anchors.verticalCenter: parent.verticalCenter
                width: volumeHover.hovered || volumeMouse.pressed ? 76 : 0
                height: 20
                clip: true

                Behavior on width { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 3
                    radius: 1.5
                    color: Qt.rgba(1, 1, 1, 0.24)
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * Player.volume
                    height: 3
                    radius: 1.5
                    color: "#FFFFFF"
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10
                    height: 10
                    radius: 5
                    color: "#FFFFFF"
                    x: Math.max(0, Math.min(parent.width - width, parent.width * Player.volume - width / 2))
                }

                MouseArea {
                    id: volumeMouse
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onPressed: function(mouse) { applyVolume(mouse.x) }
                    onPositionChanged: function(mouse) {
                        if (mouse.pressed)
                            applyVolume(mouse.x)
                    }

                    function applyVolume(x) {
                        const value = Math.max(0, Math.min(1, x / Math.max(1, width)))
                        Player.volume = value
                        root.osdRequested("volume", qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
                    }
                }
            }

            HoverHandler { id: volumeHover }

            WheelHandler {
                onWheel: function(event) {
                    Player.adjustVolume(event.angleDelta.y > 0 ? Player.volumeStep : -Player.volumeStep)
                    root.osdRequested("volume", qsTr("音量 %1%").arg(Math.round(Player.volume * 100)))
                }
            }
        }

        // ---- 更多：解码方式 / 字幕字号 / 亮度 ----
        PlayerButton {
            id: moreButton
            iconName: "more-horizontal"
            tooltip: qsTr("更多")
            onClicked: root.moreMenuRequested(moreButton)
        }
    }
}
