#include "MediaType.h"
#include "../storage/StoragePath.h"

#include <QObject>
#include <QSet>

namespace myhub {

namespace {

// 需求文档 §8.1
const QSet<QString> &videoExts()
{
    static const QSet<QString> s = {
        QStringLiteral("mp4"),  QStringLiteral("m4v"),  QStringLiteral("mov"),
        QStringLiteral("mkv"),  QStringLiteral("avi"),  QStringLiteral("flv"),
        QStringLiteral("rmvb"), QStringLiteral("rm"),   QStringLiteral("ts"),
        QStringLiteral("m2ts"), QStringLiteral("wmv"),  QStringLiteral("vob"),
        QStringLiteral("mpg"),  QStringLiteral("mpeg"), QStringLiteral("webm"),
        QStringLiteral("asf"),  QStringLiteral("divx"), QStringLiteral("3gp"),
    };
    return s;
}

const QSet<QString> &audioExts()
{
    static const QSet<QString> s = {
        QStringLiteral("mp3"), QStringLiteral("m4a"),  QStringLiteral("flac"),
        QStringLiteral("wav"), QStringLiteral("ogg"),  QStringLiteral("ape"),
        QStringLiteral("aac"), QStringLiteral("aiff"), QStringLiteral("dts"),
        QStringLiteral("mka"),
    };
    return s;
}

const QSet<QString> &imageExts()
{
    static const QSet<QString> s = {
        QStringLiteral("jpg"),  QStringLiteral("jpeg"), QStringLiteral("png"),
        QStringLiteral("gif"),  QStringLiteral("webp"), QStringLiteral("bmp"),
        QStringLiteral("heic"),
    };
    return s;
}

const QSet<QString> &comicExts()
{
    static const QSet<QString> s = {
        QStringLiteral("zip"),
        QStringLiteral("cbz"),
        QStringLiteral("rar"),
        QStringLiteral("cbr"),
    };
    return s;
}

const QSet<QString> &subtitleExts()
{
    static const QSet<QString> s = {
        QStringLiteral("srt"),
        QStringLiteral("ass"),
        QStringLiteral("ssa"),
    };
    return s;
}

/// 可在线编辑的纯文本扩展名：正文类（txt/md/log…）+ 字幕 + 常见配置/代码文本
const QSet<QString> &editableTextExts()
{
    static const QSet<QString> s = {
        QStringLiteral("txt"),      QStringLiteral("text"), QStringLiteral("md"),
        QStringLiteral("markdown"), QStringLiteral("log"),  QStringLiteral("nfo"),
        QStringLiteral("json"),     QStringLiteral("xml"),  QStringLiteral("yaml"),
        QStringLiteral("yml"),      QStringLiteral("ini"),  QStringLiteral("conf"),
        QStringLiteral("cfg"),      QStringLiteral("toml"), QStringLiteral("properties"),
        QStringLiteral("csv"),      QStringLiteral("tsv"),  QStringLiteral("cue"),
        QStringLiteral("lrc"),      QStringLiteral("srt"),  QStringLiteral("ass"),
        QStringLiteral("ssa"),      QStringLiteral("vtt"),  QStringLiteral("sub"),
        QStringLiteral("html"),     QStringLiteral("htm"),  QStringLiteral("css"),
        QStringLiteral("js"),       QStringLiteral("ts"),   QStringLiteral("py"),
        QStringLiteral("c"),        QStringLiteral("h"),    QStringLiteral("cpp"),
        QStringLiteral("hpp"),      QStringLiteral("java"), QStringLiteral("sh"),
        QStringLiteral("bat"),      QStringLiteral("ps1"),  QStringLiteral("sql"),
    };
    return s;
}

} // namespace

bool MediaType::isVideo(const QString &ext)
{
    return videoExts().contains(ext.toLower());
}
bool MediaType::isAudio(const QString &ext)
{
    return audioExts().contains(ext.toLower());
}
bool MediaType::isImage(const QString &ext)
{
    return imageExts().contains(ext.toLower());
}
bool MediaType::isComicArchive(const QString &ext)
{
    return comicExts().contains(ext.toLower());
}
bool MediaType::isSubtitle(const QString &ext)
{
    return subtitleExts().contains(ext.toLower());
}

bool MediaType::isNovel(const QString &ext)
{
    const QString e = ext.toLower();
    return e == QLatin1String("txt") || e == QLatin1String("epub");
}

bool MediaType::isPlayable(const QString &ext)
{
    return isVideo(ext) || isAudio(ext);
}

bool MediaType::isEditableText(const QString &path, bool isDir)
{
    if (isDir)
        return false;
    return editableTextExts().contains(StoragePath::extension(path).toLower());
}

MediaType::Kind MediaType::fromExtension(const QString &ext)
{
    const QString e = ext.toLower();
    if (e.isEmpty())
        return Unknown;
    if (isVideo(e))
        return Video;
    if (isAudio(e))
        return Audio;
    if (isImage(e))
        return Image;
    if (isComicArchive(e))
        return Comic;
    if (isSubtitle(e))
        return Subtitle;
    // txt 默认走纯文本阅读器（§14.1），epub 先归小说，图集判定在阅读层覆盖
    if (e == QLatin1String("txt"))
        return Text;
    if (e == QLatin1String("epub"))
        return Novel;
    return Unknown;
}

MediaType::Kind MediaType::fromPath(const QString &path, bool isDir)
{
    if (isDir)
        return Directory;
    return fromExtension(StoragePath::extension(path));
}

QString MediaType::displayName(Kind kind)
{
    switch (kind) {
    case Directory:
        return QObject::tr("文件夹");
    case Video:
        return QObject::tr("视频");
    case Audio:
        return QObject::tr("音频");
    case Novel:
        return QObject::tr("小说");
    case Comic:
        return QObject::tr("漫画");
    case Image:
        return QObject::tr("图片");
    case Subtitle:
        return QObject::tr("字幕");
    case Text:
        return QObject::tr("文本");
    case Unknown:
        break;
    }
    return QObject::tr("文件");
}

QString MediaType::badgeId(Kind kind)
{
    switch (kind) {
    case Directory:
        return QStringLiteral("folder");
    case Video:
        return QStringLiteral("video");
    case Audio:
        return QStringLiteral("audio");
    case Novel:
        return QStringLiteral("novel");
    case Comic:
        return QStringLiteral("comic");
    case Image:
        return QStringLiteral("image");
    case Subtitle:
        return QStringLiteral("subtitle");
    case Text:
        return QStringLiteral("text");
    case Unknown:
        break;
    }
    return QStringLiteral("file");
}

MediaType::Kind MediaType::fromBadgeId(const QString &badge)
{
    if (badge == QLatin1String("folder")) {
        return Directory;
    }
    if (badge == QLatin1String("video")) {
        return Video;
    }
    if (badge == QLatin1String("audio")) {
        return Audio;
    }
    if (badge == QLatin1String("novel")) {
        return Novel;
    }
    if (badge == QLatin1String("comic")) {
        return Comic;
    }
    if (badge == QLatin1String("image")) {
        return Image;
    }
    if (badge == QLatin1String("subtitle")) {
        return Subtitle;
    }
    if (badge == QLatin1String("text")) {
        return Text;
    }
    return Unknown;
}

QString MediaType::displayNameForBadge(const QString &badge)
{
    return displayName(fromBadgeId(badge));
}

} // namespace myhub
