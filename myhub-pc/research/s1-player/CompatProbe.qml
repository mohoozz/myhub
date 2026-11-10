import QtQuick
import QtQuick.Window
import QtWebEngine
import S1Compat

/*
  左半：libmpv 视频（OpenGL FBO 路径）
  右半：QtWebEngine 网页

  用于验证两者在 OpenGL 后端下能否同时出画。
*/
Window {
    width: 1280
    height: 720
    visible: true
    title: qsTr("S1 Compat Probe")
    color: "black"

    Row {
        anchors.fill: parent

        ProbePlayer {
            id: player
            width: parent.width / 2
            height: parent.height
        }

        WebEngineView {
            id: web
            width: parent.width / 2
            height: parent.height

            // 用内联 HTML，避免依赖网络
            url: "data:text/html;charset=utf-8," + encodeURIComponent(
                '<html><body style="margin:0;background:linear-gradient(135deg,#2563EB,#F59E0B);">' +
                '<div style="color:#fff;font:bold 42px sans-serif;padding:60px;">' +
                'QtWebEngine OK<br/><span style="font-size:24px">coexisting with libmpv</span></div>' +
                '<div style="background:#10B981;height:200px;margin:40px;border-radius:24px"></div>' +
                '</body></html>')
        }
    }
}
