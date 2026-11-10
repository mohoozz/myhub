import QtQuick
import QtQuick.Window
import S1Probe

/*
  S1-B 渲染验证窗口。

  布局刻意贴近真实播放页：视频铺满 + 上层 QML 叠加控制条，
  用于验证「叠加层不被视频遮挡」（S2 前置判定）。
*/
Window {
    id: win

    width: 1280
    height: 720
    visible: true
    title: qsTr("S1 Render Probe")
    color: "black"

    ProbePlayer {
        id: player
        anchors.fill: parent
    }

    // 叠加层：初始隐藏，由 C++ 在第 4 阶段打开
    Item {
        id: overlay
        objectName: "overlay"
        anchors.fill: parent
        visible: false
        z: 10

        // 底部控制条（半透明黑底 —— 会显著改变合成后的平均亮度）
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 150
            color: "#CC000000"

            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.6
                height: 56
                radius: 12
                color: "#FFFFFFFF"
            }
        }

        // 顶部信息条
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 110
            color: "#CC000000"

            Text {
                anchors.centerIn: parent
                color: "white"
                font.pixelSize: 28
                text: "overlay  pos=" + player.position.toFixed(2)
                      + "s  hwdec=" + player.hwdec
            }
        }
    }
}
