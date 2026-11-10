#include "AppPaths.h"

#include <QDir>
#include <QStandardPaths>

namespace myhub {

namespace {
constexpr auto kAppFolder = "MyHub";
}

QString AppPaths::dataDir()
{
    // AppDataLocation 在 Windows 为 %APPDATA%\<Org>\<App>，在 macOS 为
    // ~/Library/Application Support/<App>；此处已由 QCoreApplication 的
    // organizationName/applicationName 决定，无需再拼 MyHub。
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
}

QString AppPaths::cacheDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
}

QString AppPaths::logDir()
{
#ifdef Q_OS_MACOS
    return QDir::homePath() + QStringLiteral("/Library/Logs/") + QLatin1String(kAppFolder);
#else
    return dataDir() + QStringLiteral("/Logs");
#endif
}

QString AppPaths::backupDir()
{
    return dataDir() + QStringLiteral("/backup");
}

QString AppPaths::defaultDownloadDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    return base.isEmpty() ? dataDir() + QStringLiteral("/Downloads")
                          : base + QStringLiteral("/") + QLatin1String(kAppFolder);
}

QString AppPaths::databaseFile()
{
    return dataDir() + QStringLiteral("/myhub.sqlite");
}

QString AppPaths::settingsFile()
{
    return dataDir() + QStringLiteral("/settings.ini");
}

QString AppPaths::cachePartition(const QString &name)
{
    return cacheDir() + QLatin1Char('/') + name;
}

bool AppPaths::ensureDir(const QString &path)
{
    if (path.isEmpty())
        return false;
    QDir dir(path);
    if (dir.exists())
        return true;
    return QDir().mkpath(path);
}

void AppPaths::initializeAll()
{
    ensureDir(dataDir());
    ensureDir(cacheDir());
    ensureDir(logDir());
    ensureDir(backupDir());

    // 缓存分区（需求文档 §5.5）
    for (const auto *p : {"mediaSegments", "comicPages", "thumbnails", "novelChapters",
                          "novelIndexes", "directoryListings"}) {
        ensureDir(cachePartition(QLatin1String(p)));
    }
}

} // namespace myhub
