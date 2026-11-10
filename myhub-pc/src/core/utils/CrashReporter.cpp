#include "CrashReporter.h"
#include "AppPaths.h"

#include <QByteArray>
#include <QDateTime>
#include <QFile>
#include <QTextStream>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>

#ifdef Q_OS_WIN
#include <io.h>
#define MH_OPEN ::_open
#define MH_WRITE ::_write
#define MH_CLOSE ::_close
#include <fcntl.h>
#include <sys/stat.h>
#define MH_OPEN_FLAGS (_O_WRONLY | _O_CREAT | _O_APPEND | _O_BINARY)
#define MH_OPEN_MODE (_S_IREAD | _S_IWRITE)
#else
#include <fcntl.h>
#include <unistd.h>
#define MH_OPEN ::open
#define MH_WRITE ::write
#define MH_CLOSE ::close
#define MH_OPEN_FLAGS (O_WRONLY | O_CREAT | O_APPEND)
#define MH_OPEN_MODE 0644
#endif

namespace myhub {

namespace {

// 信号处理期间不可分配内存，故路径预先缓存为 C 字符串
char g_crashPath[1024] = {0};

void rawAppend(const char *text)
{
    if (g_crashPath[0] == '\0' || text == nullptr)
        return;
    const int fd = MH_OPEN(g_crashPath, MH_OPEN_FLAGS, MH_OPEN_MODE);
    if (fd < 0)
        return;
    const auto len = static_cast<unsigned int>(std::strlen(text));
    [[maybe_unused]] auto written = MH_WRITE(fd, text, len);
    MH_CLOSE(fd);
}

const char *signalName(int sig)
{
    switch (sig) {
    case SIGSEGV:
        return "SIGSEGV (segmentation fault)";
    case SIGABRT:
        return "SIGABRT (abort)";
    case SIGFPE:
        return "SIGFPE (floating point exception)";
    case SIGILL:
        return "SIGILL (illegal instruction)";
#ifdef SIGBUS
    case SIGBUS:
        return "SIGBUS (bus error)";
#endif
    default:
        return "unknown signal";
    }
}

extern "C" void signalHandler(int sig)
{
    // async-signal-safe：仅做原始写入
    rawAppend("\n==== CRASH ====\nsignal: ");
    rawAppend(signalName(sig));
    rawAppend("\nversion: " MYHUB_VERSION "\n");
    rawAppend("note: see myhub-*.log for the preceding activity\n");

    // 恢复默认处理并重新抛出，保留系统级崩溃转储
    std::signal(sig, SIG_DFL);
    std::raise(sig);
}

void terminateHandler()
{
    rawAppend("\n==== CRASH ====\nunhandled C++ exception\n");
    if (auto ex = std::current_exception()) {
        try {
            std::rethrow_exception(ex);
        } catch (const std::exception &e) {
            rawAppend("what: ");
            rawAppend(e.what());
            rawAppend("\n");
        } catch (...) {
            rawAppend("what: (non-std exception)\n");
        }
    }
    rawAppend("version: " MYHUB_VERSION "\n");
    std::abort();
}

} // namespace

void CrashReporter::install()
{
    AppPaths::ensureDir(AppPaths::logDir());

    const QByteArray path = crashLogPath().toLocal8Bit();
    std::strncpy(g_crashPath, path.constData(), sizeof(g_crashPath) - 1);
    g_crashPath[sizeof(g_crashPath) - 1] = '\0';

    // 记录本次会话启动时间，便于判断崩溃发生在哪次运行
    {
        QFile f(crashLogPath());
        if (f.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
            QTextStream ts(&f);
            ts << QStringLiteral("---- session %1 (v%2) ----\n")
                      .arg(QDateTime::currentDateTime().toString(Qt::ISODate),
                           QLatin1String(MYHUB_VERSION));
        }
    }

    std::signal(SIGSEGV, signalHandler);
    std::signal(SIGABRT, signalHandler);
    std::signal(SIGFPE, signalHandler);
    std::signal(SIGILL, signalHandler);
#ifdef SIGBUS
    std::signal(SIGBUS, signalHandler);
#endif

    std::set_terminate(terminateHandler);
}

QString CrashReporter::crashLogPath()
{
    return AppPaths::logDir() + QStringLiteral("/crash.log");
}

bool CrashReporter::hasPendingReport()
{
    QFile f(crashLogPath());
    if (!f.exists())
        return false;
    return readReport().contains(QStringLiteral("==== CRASH ===="));
}

QString CrashReporter::readReport()
{
    QFile f(crashLogPath());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return {};
    return QString::fromUtf8(f.readAll());
}

void CrashReporter::clearReport()
{
    QFile::remove(crashLogPath());
}

} // namespace myhub
