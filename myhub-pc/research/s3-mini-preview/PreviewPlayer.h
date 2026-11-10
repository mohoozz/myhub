#pragma once

// S3 专用播放器 Item。
//
// 相对 S1 的 ProbePlayer 增加了三项，用于客观判定「会话是否被重载」：
//   - fileLoadedCount：mpv 每次 FILE_LOADED 自增。reparent / 切换 mini 时
//     该值若增加，就说明会话被重建了（需求 §2.4 明确要求「复用同一会话不重载」）
//   - dropped / fps：双处渲染是否互相干扰的客观指标
//
// 独立于 s1-player/ProbePlayer.h：S1 已验收通过，不去改动它。

#include <mpv/client.h>

#include <MpvAbstractItem>
#include <MpvController>

#include <QQmlEngine>
#include <QString>
#include <QVariant>

class PreviewPlayer : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(QString hwdec READ hwdec NOTIFY hwdecChanged)
    Q_PROPERTY(int fileLoadedCount READ fileLoadedCount NOTIFY fileLoadedCountChanged)

public:
    PreviewPlayer()
    {
        setProperty(QStringLiteral("hwdec"), QStringLiteral("auto-safe"));
        setProperty(QStringLiteral("ao"), QStringLiteral("null"));
        setProperty(QStringLiteral("config"), QStringLiteral("no"));
        setProperty(QStringLiteral("loop"), QStringLiteral("inf"));

        observeProperty(QStringLiteral("time-pos"), MPV_FORMAT_DOUBLE);
        observeProperty(QStringLiteral("hwdec-current"), MPV_FORMAT_STRING);

        connect(mpvController(), &MpvController::propertyChanged, this,
                [this](const QString &name, const QVariant &value) {
                    if (name == QLatin1String("time-pos")) {
                        m_position = value.toDouble();
                        Q_EMIT positionChanged();
                    } else if (name == QLatin1String("hwdec-current")) {
                        m_hwdec = value.toString();
                        Q_EMIT hwdecChanged();
                    }
                });

        // 会话重载检测：每次文件被（重新）加载都会触发
        connect(mpvController(), &MpvController::fileLoaded, this, [this] {
            ++m_fileLoadedCount;
            Q_EMIT fileLoadedCountChanged();
        });
    }

    double position() const { return m_position; }
    QString hwdec() const { return m_hwdec; }
    int fileLoadedCount() const { return m_fileLoadedCount; }

    Q_INVOKABLE void loadFile(const QString &path)
    {
        command({QStringLiteral("loadfile"), path});
    }

    // 供 C++ 侧直接取 mpv 属性（如 frame-drop-count / estimated-vf-fps）
    // 注意：MpvAbstractItem::mpvController() 非 const，故此处不能标 const
    QVariant mpvProperty(const QString &name)
    {
        return mpvController()->getProperty(name);
    }

Q_SIGNALS:
    void positionChanged();
    void hwdecChanged();
    void fileLoadedCountChanged();

private:
    double m_position = 0.0;
    QString m_hwdec;
    int m_fileLoadedCount = 0;
};
