#include "MpvVideoItem.h"

#include <QQuickItem>

namespace myhub {

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : MpvAbstractItem(parent)
{
    /*
      mpv 选项基线。核心原则：**不读用户本机的 mpv 配置**（config=no），
      否则同一份代码在不同机器上行为不一致（S1 研究结论）。
    */
    setProperty(QStringLiteral("config"), false);
    setProperty(QStringLiteral("keep-open"), QStringLiteral("yes")); // 播完留最后一帧
    setProperty(QStringLiteral("osc"), false);                       // 控制层由 QML 自绘
    setProperty(QStringLiteral("osd-level"), 0);
    setProperty(QStringLiteral("input-default-bindings"), false);
    setProperty(QStringLiteral("input-vo-keyboard"), false);
    setProperty(QStringLiteral("audio-client-name"), QStringLiteral("MyHub"));
    // 精确同名优先：与视频同目录同名的字幕自动加载（PC-208）
    setProperty(QStringLiteral("sub-auto"), QStringLiteral("exact"));
    setProperty(QStringLiteral("hwdec"), QStringLiteral("auto-safe")); // 硬解优先，自动回退
}

MpvVideoItem::~MpvVideoItem() = default;

} // namespace myhub
