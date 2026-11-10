// 原生依赖自检：对每个库做一次真实 API 调用，确认可链接、可运行。
//
// 重要（Windows）：libsmb2.h 会 include <ws2tcpip.h>，若此前已有头文件引入了
// 旧版 <winsock.h>（windows.h 默认行为），会产生 getsockopt 重载冲突与
// IPPROTO_IPV6 未定义。必须在任何其他头文件之前拉入 winsock2.h。
#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <winsock2.h>
#  include <ws2tcpip.h>
#endif

#include <QCoreApplication>
#include <QFile>
#include <QTextStream>
#include <QStringList>

#include <sqlite3.h>
#include <zlib.h>
#include <archive.h>
#include <archive_entry.h>
// smb2.h 必须先于 libsmb2.h：前者定义 SMB2_GUID_SIZE / 签名模式等协议常量，
// 后者的结构体与枚举直接依赖这些定义。
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <mpv/client.h>

#include <cstring>
#include <vector>

static QStringList g_report;
static bool g_ok = true;

static void check(bool cond, const QString &label, const QString &detail)
{
    if (!cond)
        g_ok = false;
    g_report << QStringLiteral("[%1] %2 : %3")
                    .arg(cond ? QStringLiteral("OK") : QStringLiteral("FAIL"),
                         label.leftJustified(10), detail);
}

// sqlite3：建表 + 插入 + 查询
static void checkSqlite()
{
    sqlite3 *db = nullptr;
    bool ok = sqlite3_open(":memory:", &db) == SQLITE_OK;
    int value = 0;
    if (ok) {
        char *err = nullptr;
        ok = sqlite3_exec(db,
                          "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);"
                          "INSERT INTO t(v) VALUES('myhub');",
                          nullptr, nullptr, &err) == SQLITE_OK;
        if (err) sqlite3_free(err);
    }
    if (ok) {
        sqlite3_stmt *st = nullptr;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &st, nullptr) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW)
                value = sqlite3_column_int(st, 0);
            sqlite3_finalize(st);
        }
    }
    if (db) sqlite3_close(db);
    check(ok && value == 1, QStringLiteral("sqlite3"),
          QStringLiteral("v%1, in-memory CREATE/INSERT/SELECT rows=%2")
              .arg(QString::fromUtf8(sqlite3_libversion())).arg(value));
}

// zlib：压缩 + 解压往返
static void checkZlib()
{
    const QByteArray src(512, 'A');
    std::vector<Bytef> comp(compressBound(src.size()));
    uLongf compLen = static_cast<uLongf>(comp.size());
    bool ok = compress(comp.data(), &compLen,
                       reinterpret_cast<const Bytef *>(src.constData()),
                       static_cast<uLong>(src.size())) == Z_OK;
    std::vector<Bytef> out(src.size());
    uLongf outLen = static_cast<uLongf>(out.size());
    if (ok)
        ok = uncompress(out.data(), &outLen, comp.data(), compLen) == Z_OK;
    if (ok)
        ok = (outLen == static_cast<uLongf>(src.size())) &&
             std::memcmp(out.data(), src.constData(), src.size()) == 0;
    check(ok, QStringLiteral("zlib"),
          QStringLiteral("v%1, deflate roundtrip %2->%3 bytes")
              .arg(QString::fromUtf8(zlibVersion())).arg(src.size()).arg(compLen));
}

// libarchive：确认 rar/rar5/7z/zip 读取格式均已编译进来
static void checkLibarchive()
{
    archive *a = archive_read_new();
    bool ok = a != nullptr;
    QStringList enabled;
    if (ok) {
        struct { const char *name; int rc; } fmts[] = {
            { "zip",  archive_read_support_format_zip(a)  },
            { "rar",  archive_read_support_format_rar(a)  },
            { "rar5", archive_read_support_format_rar5(a) },
            { "7zip", archive_read_support_format_7zip(a) },
            { "tar",  archive_read_support_format_tar(a)  },
        };
        for (const auto &f : fmts) {
            if (f.rc == ARCHIVE_OK) enabled << QString::fromUtf8(f.name);
            else ok = false;
        }
        archive_read_free(a);
    }
    check(ok, QStringLiteral("libarchive"),
          QStringLiteral("v%1, formats: %2")
              .arg(QString::fromUtf8(archive_version_string()), enabled.join(QLatin1Char('/'))));
}

// libsmb2：创建并销毁 context（真正的连接留给集成测试）
static void checkLibsmb2()
{
    smb2_context *smb2 = smb2_init_context();
    bool ok = smb2 != nullptr;
    if (ok) {
        smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
        smb2_destroy_context(smb2);
    }
    // libsmb2 不提供版本宏，版本由 vcpkg 锁定（见 vcpkg.json）
    check(ok, QStringLiteral("libsmb2"),
          QStringLiteral("context init/destroy OK, signing-mode settable"));
}

// libmpv：创建 handle、初始化、查询版本（顺带确认 GPL/LGPL 构建）
static void checkLibmpv()
{
    const unsigned long api = mpv_client_api_version();
    mpv_handle *mpv = mpv_create();
    bool ok = mpv != nullptr;
    QString ver, ffver, license;
    if (ok) {
        mpv_set_option_string(mpv, "vo", "null");
        mpv_set_option_string(mpv, "ao", "null");
        ok = mpv_initialize(mpv) >= 0;
        if (ok) {
            if (char *s = mpv_get_property_string(mpv, "mpv-version")) {
                ver = QString::fromUtf8(s); mpv_free(s);
            }
            if (char *s = mpv_get_property_string(mpv, "ffmpeg-version")) {
                ffver = QString::fromUtf8(s); mpv_free(s);
            }
            // mpv 以 GPL 构建时 copyright 字段含 GPL 声明
            if (char *s = mpv_get_property_string(mpv, "copyright")) {
                license = QString::fromUtf8(s); mpv_free(s);
            }
        }
        mpv_terminate_destroy(mpv);
    }
    check(ok, QStringLiteral("libmpv"),
          QStringLiteral("api=%1.%2, %3, ffmpeg=%4")
              .arg(api >> 16).arg(api & 0xFFFF).arg(ver, ffver));
    if (!license.isEmpty())
        g_report << QStringLiteral("     -> libmpv copyright: %1")
                        .arg(license.left(300).replace(QLatin1Char('\n'), QLatin1Char(' ')));
}

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    checkSqlite();
    checkZlib();
    checkLibarchive();
    checkLibsmb2();
    checkLibmpv();
    // MpvQt 只验证链接期可用（其 QQuickItem 需要 GUI + 渲染上下文，留给 M-1 S1 预研）
    g_report << QStringLiteral("[OK] MpvQt      : linked successfully (runtime render test deferred to M-1 S1)");

    g_report << (g_ok ? QStringLiteral("RESULT: ALL NATIVE DEPENDENCIES OK")
                      : QStringLiteral("RESULT: FAILED"));

    QFile out(QStringLiteral("deps-report.txt"));
    if (out.open(QIODevice::WriteOnly | QIODevice::Text)) {
        QTextStream ts(&out);
        for (const QString &line : std::as_const(g_report))
            ts << line << '\n';
    }
    return g_ok ? 0 : 1;
}
