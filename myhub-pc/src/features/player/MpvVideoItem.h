#pragma once

#include <MpvAbstractItem>
#include <MpvController>

namespace myhub {

/**
 * libmpv 渲染面（mpvqt 的 QQuickFramebufferObject 派生类）。
 *
 * 由 C++ 侧创建并挂到 QML 容器下（PlayerBridge::claimSurface），**不在 QML 里声明**：
 * 基类 MpvAbstractItem 是第三方库类型、没有 QML 元数据，QML 的类型校验器无法确认本类
 * 继承自 QQuickItem，会拒绝把它作为子元素（报 "Cannot assign object to list property"）。
 *
 * 视频帧始终由**同一个**实例渲染。全屏 / mini 切换**只改宿主容器的几何**，
 * 不重挂载也不改 visible：render context 绑在场景图渲染节点上，重挂载或隐藏都会让
 * 节点销毁重建（实测 →「切回全屏黑屏」+ 渲染线程死锁）。宿主见 PlayerVideoLayer。
 *
 * 注意：mpvqt 走 OpenGL FBO，main.cpp 必须在 QGuiApplication 之前
 * 设置 QQuickWindow::setGraphicsApi(OpenGL)（S1 实测，见研究记录）。
 */
class MpvVideoItem : public MpvAbstractItem
{
    Q_OBJECT

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    ~MpvVideoItem() override;

    /// MpvAbstractItem::mpvController() 是 protected，引擎侧需要控制器发命令 / 订阅属性
    MpvController *controller() { return mpvController(); }
};

} // namespace myhub
