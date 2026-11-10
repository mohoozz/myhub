import QtQuick
import MyHub

/*
  纯音频播放态（PC-206 / §4.3 AudioCoverView）。

  音频文件或「纯音频模式」下不渲染视频面，改显示唱片封面 ——
  仍然保留音频轨道输出，只是不显示画面。

  纪律：
    · 封面与 mini 条、列表缩略图**同源同缓存**：都走 CoverService（`CoverImage`），
      优先级 = 内嵌标签封面 → 同目录同名图 → cover/folder/front → 占位
    · 唱片**播放时旋转、暂停冻结**：旋转角由 RotationAnimator 保持，
      不做「归零重来」，恢复播放从当前角度继续
    · 占位**必须不透明**（深色底 + 音符图标），不得透出下层画面
    · 封面尺寸随窗口缩放，竖屏/小窗下不挤压文字
*/
Item {
    id: root

    readonly property bool spinning: Player.state === Player.Playing
    readonly property real discSize: Math.max(140, Math.min(320,
        Math.min(root.width * 0.42, root.height * 0.46)))
    readonly property bool hasCover: discImage.hasCover

    Column {
        anchors.centerIn: parent
        spacing: AppTheme.spacingXl

        // ---------------- 唱片主体 ----------------
        Item {
            id: disc
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.discSize
            height: root.discSize

            // 外圈：黑胶盘的厚度感（与封面同转，避免看起来像「贴图在转」）
            Rectangle {
                anchors.centerIn: parent
                width: disc.width + 10
                height: width
                radius: width / 2
                color: Qt.rgba(0, 0, 0, 0.55)
                border.width: AppTheme.borderWidth
                border.color: Qt.rgba(1, 1, 1, 0.12)
            }

            Item {
                id: rotator
                anchors.fill: parent

                RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: 16000
                    loops: Animation.Infinite
                    running: root.spinning
                }

                CoverImage {
                    id: discImage
                    anchors.fill: parent
                    // 本地 / 远程都用当前会话的归属，CoverService 自己选适配器
                    connectionId: Player.currentConnectionId
                    filePath: Player.currentPath
                    mediaKind: "audio"
                    radius: width / 2
                    cropFill: true
                    iconRatio: 0.42
                }

                // 中心轴孔：只在真有封面时出现（占位态加个孔反而像坏了）
                Rectangle {
                    anchors.centerIn: parent
                    visible: root.hasCover
                    width: disc.width * 0.16
                    height: width
                    radius: width / 2
                    color: AppTheme.colors.immersiveBg
                    border.width: AppTheme.borderWidth
                    border.color: Qt.rgba(1, 1, 1, 0.22)
                }
            }
        }

        // ---------------- 曲目信息 ----------------
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: AppTheme.spacingSm
            width: Math.min(root.width - AppTheme.spacingXl * 4, 520)

            Text {
                width: parent.width
                text: Player.mediaTitle
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTitle
                font.bold: true
                color: "#FFFFFF"
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                // 有作者就显示作者（文件名解析出来的），没有才退回状态说明
                text: Player.mediaArtist !== ""
                      ? Player.mediaArtist
                      : (Player.audioOnly ? qsTr("纯音频模式") : qsTr("音频"))
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: Qt.rgba(1, 1, 1, 0.55)
            }
        }
    }
}
