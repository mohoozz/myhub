import QtQuick
import MyHub

/*
  视频渲染层的唯一宿主（§4.4）。

  **纪律（踩过的坑，别改回去）**：
    · 渲染面一生只挂一次。mpv 的 render context 绑在场景图的渲染节点上，
      换 parentItem 或翻转 visible 都会让该节点销毁重建 —— 实测表现为
      「切到 mini 再切回来整片黑」以及渲染线程偶发死锁
    · 所以「全屏 ↔ mini ↔ 悬浮小窗」只改这一层的 x / y / width / height，
      不搬父项、不动 visible —— 会话、进度、解码器状态全程不变
    · 不用 0 尺寸来「隐藏」：mpv 会把画面渲染到 FBO 0（默认帧缓冲），
      等于糊满整个窗口。不呈现时收到 1×1

  分层：固定 z 490 —— 压在窗口内容（含 mini 播放条）之上，
  又在 PlayerView（z 500）之下；全屏时由 PlayerView 的透明背景让位。
*/
Item {
    id: root

    /// mini 播放条的预览块（由 MiniPlayerBar 注册进 PlayerStage）
    readonly property Item previewTarget: PlayerStage.previewTarget

    /// 全屏 / 悬浮小窗：铺满窗口；mini：贴在播放条的预览块上；其余：不呈现
    readonly property bool presented: PlayerStage.full || PlayerStage.floating
                                      || (PlayerStage.miniVisible && Player.hasVideo)

    readonly property rect targetRect: {
        if (PlayerStage.full || PlayerStage.floating)
            return Qt.rect(0, 0, root.width, root.height)
        const target = previewTarget
        if (!presented || !target)
            return Qt.rect(0, 0, 1, 1)
        const origin = target.mapToItem(root, 0, 0)
        return Qt.rect(origin.x, origin.y, target.width, target.height)
    }

    // 渲染面由 C++ 创建（QML 无法声明 MpvVideoItem），这里只负责把它挂进来一次
    PlayerSurface {
        id: surface
        x: root.targetRect.x
        y: root.targetRect.y
        width: root.targetRect.width
        height: root.targetRect.height
    }

    Component.onCompleted: surface.claim()
}
