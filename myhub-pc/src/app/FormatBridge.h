#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

namespace myhub {

/**
 * 展示用格式化（QML 单例 `Format`）。
 *
 * QML 侧没有 std::format / QString::arg 的便捷写法，字幕时间轴、文件大小、
 * 百分比这类文案统一走这里，避免各页面各写一套（数字格式不一致是原型评审最容易看出的差异）。
 */
class FormatBridge : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Format)
    QML_SINGLETON

public:
    static FormatBridge *create(QQmlEngine *, QJSEngine *);

    // 无默认参数：让 Qt 走 create() 工厂（否则默认构造会抢在工厂之前生效）
    explicit FormatBridge(QObject *parent);

    /// 毫秒 → "1:02:03" / "02:03"；负数返回 "--:--"
    Q_INVOKABLE QString duration(qint64 milliseconds) const;

    /// 字节 → "1.2 GB"
    Q_INVOKABLE QString fileSize(qint64 bytes) const;
};

} // namespace myhub
