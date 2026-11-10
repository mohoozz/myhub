import QtQuick
import MyHub

/*
  视频渲染面容器（全进程唯一 mpv 实例的宿主的容器）。

  - 渲染面本身由 C++ 创建并挂进 root：MpvVideoItem 继承自 mpvqt 的第三方
    基类，QML 类型系统无法解析其继承链，不能在 QML 里直接声明（详见
    PlayerBridge::claimSurface 的注释）
  - 整个进程只有这一个渲染面，且**只认领一次**：挂在 PlayerVideoLayer 里，
    全屏 ↔ mini 只改这一层的几何（见 PlayerVideoLayer 的注释）
  - 纯音频 / 无视频轨的呈现由宿主决定（全屏用大封面，mini 用不透明占位块）
*/
Item {
    id: root

    /// 宿主在创建时调用一次：把渲染面挂进来（之后再调用也不会重挂载）
    function claim() {
        Player.claimSurface(root)
    }
}
