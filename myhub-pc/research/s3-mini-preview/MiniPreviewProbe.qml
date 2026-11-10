import QtQuick
import QtQuick.Window
import S3Probe

/*
  S3：mini 实时预览的双处渲染验证。

  架构要点（对应需求 §2.4「mini 播放条跨页面保持 / 复用同一会话不重载」）：

    - **只有一个 PreviewPlayer 实例**，即只有一个 mpv 会话、一次解码。
      绝不能为 mini 条再开一个 mpv —— 那会双倍解码开销且进度不同步。

    - mini 预览用 ShaderEffectSource 引用主画面 Item 作为纹理源，
      属于场景图内的纹理复制，不经过解码路径。

    - 播放器 Item 常驻于 playerHost，通过**改变 parent**在
      「全屏容器 / mini 容器」之间移动，而不是销毁重建。
*/
Window {
    id: root
    width: 1280
    height: 720
    visible: true
    title: qsTr("S3 Mini Preview Probe")
    color: "#101014"

    // 供 C++ 驱动各阶段
    property alias player: videoPlayer
    property bool miniVisible: false
    property bool mainVisible: true
    // 由 C++ 控制，用于做「限制/不限制预览纹理尺寸」的对照实验
    property bool limitTextureSize: false
    // 由 C++ 控制，用于验证 layer.enabled 是否为 mini 出画的必要条件
    property bool playerLayerEnabled: true

    // ---- 主画面区域 ----
    Item {
        id: stageHost
        objectName: "stageHost"
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: parent.height - miniBar.height
        visible: root.mainVisible
    }

    // ---- 常驻播放器 ----
    // 初始挂在 stageHost 下；reparent 测试会把它移到 miniStage。
    PreviewPlayer {
        id: videoPlayer
        objectName: "videoPlayer"
        parent: stageHost
        anchors.fill: parent

        // 是否启用 layer（离屏纹理）。由 C++ 切换，用于验证：
        // 主画面隐藏后 mini 仍能出画，是否依赖 layer.enabled。
        layer.enabled: root.playerLayerEnabled
        layer.smooth: true
    }

    // ---- 底部 mini 播放条 ----
    Rectangle {
        id: miniBar
        objectName: "miniBar"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 72
        color: "#1A1A20"
        border.color: "#2E2E38"      // 需求：深浅色均带细边框
        border.width: 1

        Row {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 12

            // mini 实时画面预览：主画面的纹理副本（非第二个 mpv 实例）
            Item {
                width: 114
                height: 64
                clip: true

                Rectangle {        // 无画面时的不透明占位（需求：占位块不得透出背景）
                    anchors.fill: parent
                    color: "#000000"
                }

                ShaderEffectSource {
                    id: miniPreview
                    objectName: "miniPreview"
                    anchors.fill: parent
                    sourceItem: root.miniVisible ? videoPlayer : null
                    live: true
                    hideSource: false          // 主画面仍需正常显示
                    recursive: false
                    visible: root.miniVisible

                    // 关键优化：默认会按源 Item 的**全分辨率**(1920x1080) 分配并
                    // 复制纹理，而 mini 只有 114x64，绝大部分开销是白费的。
                    // 实测不限制时双处渲染会引入丢帧，限制后消除。
                    textureSize: root.limitTextureSize
                                 ? Qt.size(width, height)
                                 : Qt.size(0, 0)   // 0 = 跟随源尺寸（对照用）
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Text {
                    text: "mini: pos=" + videoPlayer.position.toFixed(2) + "s"
                    color: "#E8E8F0"
                    font.pixelSize: 15
                }
                Text {
                    text: "loads=" + videoPlayer.fileLoadedCount
                          + "  hwdec=" + videoPlayer.hwdec
                    color: "#9A9AA8"
                    font.pixelSize: 12
                }
            }
        }
    }

    // ---- reparent 目标：mini 容器 ----
    // 用于验证「把播放器移进 mini 条」时会话不重载。
    Item {
        id: miniStage
        objectName: "miniStage"
        width: 114
        height: 64
        anchors { right: parent.right; rightMargin: 16; bottom: parent.bottom; bottomMargin: 4 }
    }
}
