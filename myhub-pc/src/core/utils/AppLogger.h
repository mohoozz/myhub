#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

class QFile;
class QTextStream;

namespace myhub {

/**
 * 文件日志（PC-707，移植自 iOS 端 AppLogger）。
 *
 * - 按天滚动 `myhub-YYYY-MM-DD.log`，保留最近 7 份
 * - 单文件超过上限自动截断
 * - 新构建首次启动归档旧日志
 * - 分模块 tag，便于按链路排查
 */
class AppLogger : public QObject
{
    Q_OBJECT
public:
    /// 模块 tag（与 iOS 端一致，见需求文档 §2.11 PC-707）
    enum Module
    {
        App,
        Lifecycle,
        NetworkRoute,
        Stream,
        Player,
        PlayerAudio,
        NovelIndex,
        ComicReader,
        Browser,
        Database,
        Storage,
    };
    Q_ENUM(Module)

    enum Level
    {
        Debug,
        Info,
        Warning,
        Critical
    };
    Q_ENUM(Level)

    static AppLogger &instance();

    /// 安装 qInstallMessageHandler 并打开当天日志文件
    void initialize();
    void shutdown();

    void log(Level level, Module module, const QString &message);

    /// 当前日志文件完整路径
    QString currentLogFilePath() const;
    /// 日志目录
    QString logDirectory() const;
    /// 读取最近 N 行（设置 → 关于 → 日志查看）
    QStringList tail(int maxLines = 500) const;
    void clear();

    static QString moduleTag(Module m);

private:
    explicit AppLogger(QObject *parent = nullptr);
    ~AppLogger() override;

    void rotateIfNeeded();
    void pruneOldLogs();
    void archiveOnNewBuild();
    void writeLine(const QString &line);

    struct Private;
    Private *d;
};

} // namespace myhub

// 便捷宏
#define MH_LOG(level, mod, msg) \
    ::myhub::AppLogger::instance().log(::myhub::AppLogger::level, ::myhub::AppLogger::mod, msg)

#define MH_INFO(mod, msg) MH_LOG(Info, mod, msg)
#define MH_WARN(mod, msg) MH_LOG(Warning, mod, msg)
#define MH_ERROR(mod, msg) MH_LOG(Critical, mod, msg)
#define MH_DEBUG(mod, msg) MH_LOG(Debug, mod, msg)
