import QtQuick
import QtQuick.Window
import MyHub

/*
  根窗口（§2.2）。

  启动期显示 Loading 动画，就绪后切入主外壳 —— **不得出现长白屏**（§14.4）。
*/
Window {
    id: window

    width: 1280
    height: 820
    minimumWidth: 640
    minimumHeight: 480
    visible: true
    title: qsTr("MyHub")
    // 小窗形态下窗口背景必须是纯黑：视频比例不符时露出来的是黑边而不是主题底色
    color: WindowController.floating ? "#000000" : AppTheme.colors.pageBg

    Component.onCompleted: {
        WindowController.attach(window)
        WindowController.restoreGeometry()
    }

    // 最小化主窗口 → 自动进悬浮小窗（§4.4，「默认关闭，运行期改动立即生效」）。
    // 判定放在 QML：开关读的是 AppSettings 当前值，改完下一次最小化就生效，不用重开视频
    onVisibilityChanged: function(vis) {
        if (vis === Window.Minimized
                && WindowController.minimizeToFloating
                && !WindowController.floating
                && Player.state !== Player.Idle) {
            // 等最小化动画结束再变身，否则 Windows 会吞掉 show()
            Qt.callLater(PlayerStage.showFloating)
        }
    }

    // 主外壳：就绪后淡入；小窗形态下整个外壳收起（小窗只该看到画面）
    RootShell {
        id: shell
        anchors.fill: parent
        opacity: AppState.ready && !WindowController.floating ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: Motion.normal }
        }
    }

    // 视频渲染层（§4.4）：唯一的渲染面宿主，常驻不重建；
    // 全屏 / mini 只改它的几何，因此切换呈现位不会重新起播
    PlayerVideoLayer {
        anchors.fill: parent
        z: 490
    }

    // 全屏播放器（§14.6）：覆盖主外壳，但压在启动 Loading 之下
    PlayerView {
        id: playerView
        anchors.fill: parent

        // 退出播放后把键盘焦点还给主外壳，否则 Ctrl+1..6 失效；
        // 小窗形态不抢焦点 —— 那边还要用 Esc / 空格
        onVisibleChanged: if (!visible && !WindowController.floating) shell.restoreFocus()
    }

    // 悬浮小窗的内容层（§4.4）：只在 stage.floating 时可见，
    // 视频面仍是上面那一层，这里只有压在画面上的控制带与拖动/缩放热区
    FloatingPlayerOverlay {
        anchors.fill: parent
        z: 520
    }

    // 启动 Loading
    LaunchLoading {
        anchors.fill: parent
        statusText: AppState.statusText
        opacity: AppState.ready ? 0 : 1
        visible: opacity > 0
        z: 1000

        Behavior on opacity {
            NumberAnimation { duration: Motion.normal }
        }
    }

    // 启动失败提示
    ConfirmDialog {
        id: bootFailDialog
        title: qsTr("启动异常")
        confirmText: qsTr("知道了")
        cancelText: ""
    }

    Connections {
        target: AppState
        function onBootFailed(reason) {
            bootFailDialog.message = reason
            bootFailDialog.open()
        }
    }
}
