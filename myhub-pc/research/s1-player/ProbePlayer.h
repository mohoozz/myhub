#pragma once

// 最小可用的播放器 Item：mpvqt 只提供抽象基类 MpvAbstractItem，需自行派生。
//
// 必须放在独立头文件中：qmltyperegistrar 生成的注册代码会 #include 声明
// QML_ELEMENT 的头，若直接写在 .cpp 里会导致 moc 产物与 main 被重复编译，
// 链接时报 LNK2005 多重定义。

#include <mpv/client.h>

// MpvQt 的 INTERFACE_INCLUDE_DIRECTORIES 已指向 include/MpvQt 本身，
// 故直接包含头名，不带 MpvQt/ 前缀。
#include <MpvAbstractItem>
#include <MpvController>

#include <QQmlEngine>
#include <QString>
#include <QVariant>

class ProbePlayer : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(QString hwdec READ hwdec NOTIFY hwdecChanged)

public:
    ProbePlayer()
    {
        // 渲染路径由 mpvqt 接管（vo=libmpv），此处只设解码相关选项
        setProperty(QStringLiteral("hwdec"), QStringLiteral("auto-safe"));
        setProperty(QStringLiteral("ao"), QStringLiteral("null"));
        setProperty(QStringLiteral("config"), QStringLiteral("no"));

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
    }

    double position() const { return m_position; }
    QString hwdec() const { return m_hwdec; }

    Q_INVOKABLE void loadFile(const QString &path)
    {
        command({QStringLiteral("loadfile"), path});
    }

Q_SIGNALS:
    void positionChanged();
    void hwdecChanged();

private:
    double m_position = 0.0;
    QString m_hwdec;
};
