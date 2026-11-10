#include "AppLogger.h"
#include "AppPaths.h"

#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QMutexLocker>
#include <QSettings>
#include <QTextStream>

namespace myhub {

namespace {
// 显式用 qint64 起算：`8 * 1024 * 1024` 是 int 乘法，改上限时容易悄悄溢出
constexpr qint64 kMaxFileBytes = qint64(8) * 1024 * 1024; // 单文件上限 8MB
constexpr int kKeepFiles = 7;                             // 保留 7 份
QtMessageHandler g_previousHandler = nullptr;
} // namespace

struct AppLogger::Private
{
    QMutex mutex;
    QFile file;
    QDate fileDate;
    bool initialized = false;
};

AppLogger::AppLogger(QObject *parent)
    : QObject(parent)
    , d(new Private)
{}

AppLogger::~AppLogger()
{
    shutdown();
    delete d;
}

AppLogger &AppLogger::instance()
{
    static AppLogger s_instance;
    return s_instance;
}

QString AppLogger::moduleTag(Module m)
{
    switch (m) {
    case App:
        return QStringLiteral("app");
    case Lifecycle:
        return QStringLiteral("lifecycle");
    case NetworkRoute:
        return QStringLiteral("network-route");
    case Stream:
        return QStringLiteral("stream");
    case Player:
        return QStringLiteral("player");
    case PlayerAudio:
        return QStringLiteral("player-audio");
    case NovelIndex:
        return QStringLiteral("novel-index");
    case ComicReader:
        return QStringLiteral("comic-reader");
    case Browser:
        return QStringLiteral("browser");
    case Database:
        return QStringLiteral("database");
    case Storage:
        return QStringLiteral("storage");
    }
    return QStringLiteral("app");
}

static const char *levelTag(AppLogger::Level l)
{
    switch (l) {
    case AppLogger::Debug:
        return "D";
    case AppLogger::Info:
        return "I";
    case AppLogger::Warning:
        return "W";
    case AppLogger::Critical:
        return "E";
    }
    return "I";
}

// 把 Qt 自身的 qDebug/qWarning 也收进文件日志
static void messageHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    AppLogger::Level level = AppLogger::Debug;
    switch (type) {
    case QtDebugMsg:
        level = AppLogger::Debug;
        break;
    case QtInfoMsg:
        level = AppLogger::Info;
        break;
    case QtWarningMsg:
        level = AppLogger::Warning;
        break;
    case QtCriticalMsg:
    case QtFatalMsg:
        level = AppLogger::Critical;
        break;
    }

    // 框架产生的 debug 输出（QML 引擎 JIT、qt.qml.* / qt.scenegraph.* 类别等）
    // 量极大且对排障无用，会把业务日志淹没，故不写入文件日志，
    // 仅转交默认处理器输出到控制台/调试器。
    //
    // 注意：业务侧的 MH_DEBUG 直接调用 log()，不经过本处理器，因此不受影响。
    if (level == AppLogger::Debug) {
        if (g_previousHandler)
            g_previousHandler(type, ctx, msg);
        return;
    }

    QString text = msg;
    if (ctx.category && qstrcmp(ctx.category, "default") != 0)
        text = QStringLiteral("[%1] %2").arg(QLatin1String(ctx.category), msg);

    AppLogger::instance().log(level, AppLogger::App, text);

    if (g_previousHandler)
        g_previousHandler(type, ctx, msg);
}

void AppLogger::initialize()
{
    QMutexLocker lock(&d->mutex);
    if (d->initialized)
        return;

    AppPaths::ensureDir(AppPaths::logDir());
    d->initialized = true;
    lock.unlock();

    archiveOnNewBuild();
    rotateIfNeeded();
    pruneOldLogs();

    g_previousHandler = qInstallMessageHandler(messageHandler);

    log(Info, App,
        QStringLiteral("==== MyHub %1 started (%2) ====")
            .arg(QLatin1String(MYHUB_VERSION), QDateTime::currentDateTime().toString(Qt::ISODate)));
}

void AppLogger::shutdown()
{
    QMutexLocker lock(&d->mutex);
    if (!d->initialized)
        return;
    if (d->file.isOpen()) {
        QTextStream ts(&d->file);
        ts << QStringLiteral("==== session end ====\n");
        ts.flush();
        d->file.close();
    }
    d->initialized = false;
}

QString AppLogger::logDirectory() const
{
    return AppPaths::logDir();
}

QString AppLogger::currentLogFilePath() const
{
    const QDate today = QDate::currentDate();
    return AppPaths::logDir()
        + QStringLiteral("/myhub-%1.log").arg(today.toString(QStringLiteral("yyyy-MM-dd")));
}

void AppLogger::rotateIfNeeded()
{
    QMutexLocker lock(&d->mutex);
    const QDate today = QDate::currentDate();

    if (d->file.isOpen() && d->fileDate == today) {
        // 单文件超限则截断重开（保留当天最新内容）
        if (d->file.size() > kMaxFileBytes) {
            d->file.close();
            d->file.setFileName(currentLogFilePath());
            d->file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
        }
        return;
    }

    if (d->file.isOpen())
        d->file.close();

    d->fileDate = today;
    d->file.setFileName(currentLogFilePath());
    d->file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
}

void AppLogger::pruneOldLogs()
{
    QDir dir(AppPaths::logDir());
    if (!dir.exists())
        return;

    QFileInfoList files =
        dir.entryInfoList({QStringLiteral("myhub-*.log")}, QDir::Files, QDir::Name);
    while (files.size() > kKeepFiles) {
        QFile::remove(files.first().absoluteFilePath());
        files.removeFirst();
    }
}

void AppLogger::archiveOnNewBuild()
{
    // 新构建首启：把旧日志整体归档，便于区分版本间的问题
    QSettings s(AppPaths::settingsFile(), QSettings::IniFormat);
    const QString lastBuild = s.value(QStringLiteral("app.lastBuildVersion")).toString();
    const QString current = QLatin1String(MYHUB_VERSION);
    if (lastBuild == current)
        return;

    if (!lastBuild.isEmpty()) {
        QDir dir(AppPaths::logDir());
        const QString archive = AppPaths::logDir() + QStringLiteral("/archive-%1").arg(lastBuild);
        AppPaths::ensureDir(archive);
        for (const QFileInfo &fi :
             dir.entryInfoList({QStringLiteral("myhub-*.log")}, QDir::Files)) {
            QFile::rename(fi.absoluteFilePath(), archive + QLatin1Char('/') + fi.fileName());
        }
    }
    s.setValue(QStringLiteral("app.lastBuildVersion"), current);
}

void AppLogger::writeLine(const QString &line)
{
    QMutexLocker lock(&d->mutex);
    if (!d->file.isOpen())
        return;
    QTextStream ts(&d->file);
    ts.setEncoding(QStringConverter::Utf8);
    ts << line << '\n';
    ts.flush();
}

void AppLogger::log(Level level, Module module, const QString &message)
{
    if (!d->initialized)
        return;

    rotateIfNeeded();

    const QString line =
        QStringLiteral("%1 %2/%3: %4")
            .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")),
                 QLatin1String(levelTag(level)), moduleTag(module), message);

    writeLine(line);
}

QStringList AppLogger::tail(int maxLines) const
{
    QFile f(currentLogFilePath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return {};

    QStringList all;
    QTextStream ts(&f);
    ts.setEncoding(QStringConverter::Utf8);
    while (!ts.atEnd()) {
        all << ts.readLine();
        // 防止超大文件一次性读爆内存：滚动保留窗口
        // 用 qsizetype 起算，避免 int * int 在 maxLines 很大时溢出
        if (all.size() > qsizetype(maxLines) * 4)
            all.remove(0, all.size() - qsizetype(maxLines) * 2);
    }
    if (all.size() > maxLines)
        return all.mid(all.size() - maxLines);
    return all;
}

void AppLogger::clear()
{
    {
        QMutexLocker lock(&d->mutex);
        if (d->file.isOpen()) {
            d->file.close();
        }
    }
    QDir dir(AppPaths::logDir());
    for (const QFileInfo &fi : dir.entryInfoList({QStringLiteral("myhub-*.log")}, QDir::Files))
        QFile::remove(fi.absoluteFilePath());
    rotateIfNeeded();
}

} // namespace myhub
