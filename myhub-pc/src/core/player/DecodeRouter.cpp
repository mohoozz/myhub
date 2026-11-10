#include "DecodeRouter.h"

#include <QFile>
#include <QFileInfo>
#include <QUrl>

namespace myhub {
namespace {

constexpr int kProbeBytes = 200;

/// 本地路径（file:// 也接受）；远程 URL 返回空
QString localPathOf(const QString &source)
{
    if (source.isEmpty())
        return {};

    if (source.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive)) {
        const QUrl url(source);
        return url.isLocalFile() ? url.toLocalFile() : QString();
    }
    if (source.contains(QStringLiteral("://")))
        return {}; // http / smb / dav ...
    return source;
}

QString suffixOf(const QString &source)
{
    // 不依赖 QFileInfo：URL 里的 '?' 之后是查询串，可能自带点号
    QString path = source;
    if (const int schemeAt = path.indexOf(QStringLiteral("://")); schemeAt >= 0)
        path = path.mid(schemeAt + 3);
    if (const int queryAt = path.indexOf(QLatin1Char('?')); queryAt >= 0)
        path = path.left(queryAt);

    const int slashAt = path.lastIndexOf(QLatin1Char('/'));
    const QString name = slashAt >= 0 ? path.mid(slashAt + 1) : path;
    const int dotAt = name.lastIndexOf(QLatin1Char('.'));
    if (dotAt <= 0 || dotAt == name.size() - 1)
        return {};
    return name.mid(dotAt + 1).toLower();
}

MediaContainer fromMagic(const QByteArray &head)
{
    const auto at = [&head](int offset, const char *magic, int length) {
        return head.size() >= offset + length
            && qstrncmp(head.constData() + offset, magic, length) == 0;
    };

    // EBML（mkv / webm）：1A 45 DF A3
    if (head.size() >= 4 && static_cast<quint8>(head.at(0)) == 0x1A
        && static_cast<quint8>(head.at(1)) == 0x45 && static_cast<quint8>(head.at(2)) == 0xDF
        && static_cast<quint8>(head.at(3)) == 0xA3) {
        return MediaContainer::Matroska; // webm 与 mkv 同族，硬解表现一致
    }
    if (at(4, "ftyp", 4))
        return MediaContainer::Mp4;
    if (at(0, "RIFF", 4) && at(8, "AVI ", 4))
        return MediaContainer::Avi;
    if (at(0, "FLV\x01", 4))
        return MediaContainer::Flv;
    if (at(0, "OggS", 4))
        return MediaContainer::Ogg;
    if (at(0, ".RMF", 4))
        return MediaContainer::RealMedia;
    // ASF 头 GUID：30 26 B2 75 8E 66 CF 11
    if (head.size() >= 8 && static_cast<quint8>(head.at(0)) == 0x30
        && static_cast<quint8>(head.at(1)) == 0x26 && static_cast<quint8>(head.at(2)) == 0xB2
        && static_cast<quint8>(head.at(3)) == 0x75) {
        return MediaContainer::Asf;
    }
    // MPEG-PS：00 00 01 BA
    if (head.size() >= 4 && static_cast<quint8>(head.at(0)) == 0x00
        && static_cast<quint8>(head.at(1)) == 0x00 && static_cast<quint8>(head.at(2)) == 0x01
        && static_cast<quint8>(head.at(3)) == 0xBA) {
        return MediaContainer::MpegPs;
    }
    // MPEG-TS：包长 188，两个连续包首字节都是 0x47
    if (head.size() >= 189 && static_cast<quint8>(head.at(0)) == 0x47
        && static_cast<quint8>(head.at(188)) == 0x47) {
        return MediaContainer::MpegTs;
    }
    return MediaContainer::Unknown;
}

/// 主视频流几乎没有硬解器、或硬解链路上极易「有画面无声」的容器
bool prefersSoftware(MediaContainer container)
{
    switch (container) {
    case MediaContainer::RealMedia: // RealVideo：无硬件解码器
    case MediaContainer::Avi:       // 多为 Xvid/DivX/MS-MPEG4
    case MediaContainer::Flv:       // H.263 / VP6
    case MediaContainer::Asf:       // WMV / VC-1
    case MediaContainer::Ogg:       // Theora
    case MediaContainer::MpegPs:    // MPEG-1/2 PS，常见 AC-3 混流
    case MediaContainer::Vob:       // DVD：MPEG-2 + AC-3/DTS
        return true;
    case MediaContainer::Mp4:
    case MediaContainer::Matroska:
    case MediaContainer::Webm:
    case MediaContainer::MpegTs: // 广播/录播 ts 多为 H.264+AAC，硬解正常
    case MediaContainer::Unknown:
        return false;
    }
    return false;
}

} // namespace

QStringList DecodeRouter::softwareOnlySuffixes()
{
    return {QStringLiteral("rm"),  QStringLiteral("rmvb"), QStringLiteral("avi"),
            QStringLiteral("flv"), QStringLiteral("wmv"),  QStringLiteral("asf"),
            QStringLiteral("vob"), QStringLiteral("mpg"),  QStringLiteral("mpeg"),
            QStringLiteral("m1v"), QStringLiteral("m2v"),  QStringLiteral("ogv"),
            QStringLiteral("ogm"), QStringLiteral("divx"), QStringLiteral("3gp")};
}

MediaContainer DecodeRouter::fromSuffix(const QString &source)
{
    const QString suffix = suffixOf(source);
    if (suffix.isEmpty())
        return MediaContainer::Unknown;

    if (suffix == QStringLiteral("mp4") || suffix == QStringLiteral("mov")
        || suffix == QStringLiteral("m4v") || suffix == QStringLiteral("m4a")) {
        return MediaContainer::Mp4;
    }
    if (suffix == QStringLiteral("mkv") || suffix == QStringLiteral("mka")
        || suffix == QStringLiteral("mk3d")) {
        return MediaContainer::Matroska;
    }
    if (suffix == QStringLiteral("webm"))
        return MediaContainer::Webm;
    if (suffix == QStringLiteral("ts") || suffix == QStringLiteral("m2ts")
        || suffix == QStringLiteral("mts")) {
        return MediaContainer::MpegTs;
    }
    if (suffix == QStringLiteral("avi") || suffix == QStringLiteral("divx")
        || suffix == QStringLiteral("3gp")) {
        return MediaContainer::Avi;
    }
    if (suffix == QStringLiteral("flv") || suffix == QStringLiteral("f4v"))
        return MediaContainer::Flv;
    if (suffix == QStringLiteral("wmv") || suffix == QStringLiteral("asf"))
        return MediaContainer::Asf;
    if (suffix == QStringLiteral("vob"))
        return MediaContainer::Vob;
    if (suffix == QStringLiteral("mpg") || suffix == QStringLiteral("mpeg")
        || suffix == QStringLiteral("m1v") || suffix == QStringLiteral("m2v")) {
        return MediaContainer::MpegPs;
    }
    if (suffix == QStringLiteral("rm") || suffix == QStringLiteral("rmvb"))
        return MediaContainer::RealMedia;
    if (suffix == QStringLiteral("ogg") || suffix == QStringLiteral("ogv")
        || suffix == QStringLiteral("ogm")) {
        return MediaContainer::Ogg;
    }
    return MediaContainer::Unknown;
}

MediaContainer DecodeRouter::probe(const QString &source)
{
    const QString local = localPathOf(source);
    if (!local.isEmpty()) {
        QFile file(local);
        // 一次 200 字节的同步读：本地文件不存在/无权限时立刻失败，不需要超时机制
        if (file.open(QIODevice::ReadOnly)) {
            const QByteArray head = file.read(kProbeBytes);
            file.close();
            if (const MediaContainer byMagic = fromMagic(head); byMagic != MediaContainer::Unknown)
                return byMagic;
        }
    }
    return fromSuffix(source);
}

QString DecodeRouter::containerName(MediaContainer container)
{
    switch (container) {
    case MediaContainer::Mp4:
        return QStringLiteral("mp4");
    case MediaContainer::Matroska:
        return QStringLiteral("matroska");
    case MediaContainer::Webm:
        return QStringLiteral("webm");
    case MediaContainer::Avi:
        return QStringLiteral("avi");
    case MediaContainer::Flv:
        return QStringLiteral("flv");
    case MediaContainer::MpegTs:
        return QStringLiteral("mpegts");
    case MediaContainer::MpegPs:
        return QStringLiteral("mpegps");
    case MediaContainer::Vob:
        return QStringLiteral("vob");
    case MediaContainer::RealMedia:
        return QStringLiteral("realmedia");
    case MediaContainer::Asf:
        return QStringLiteral("asf");
    case MediaContainer::Ogg:
        return QStringLiteral("ogg");
    case MediaContainer::Unknown:
        break;
    }
    return QStringLiteral("unknown");
}

DecodeDecision DecodeRouter::decide(const QString &preference, const QString &source)
{
    const QString pref = preference.trimmed().toLower();

    // 1) 用户强制：直接定死，运行期不得自动改判
    if (pref == QStringLiteral("software"))
        return {QStringLiteral("no"), true, QStringLiteral("preference:software")};
    if (pref == QStringLiteral("hardware"))
        return {QStringLiteral("auto"), true, QStringLiteral("preference:hardware")};

    // 2) 容器已知无硬解（或硬解易丢音轨）：起播即软解，省掉一次重载
    const MediaContainer container = probe(source);
    if (prefersSoftware(container)) {
        return {QStringLiteral("no"), false,
                QStringLiteral("container:") + containerName(container)};
    }

    // 3) 默认：优先硬解，失败由 mpv 自身回落（auto-safe 不尝试不安全后端）
    return {QStringLiteral("auto-safe"), false, QStringLiteral("auto")};
}

} // namespace myhub
