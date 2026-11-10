// S6-B：libsmb2 在 Windows(MSVC) 下的 SMB2/3 实链路验证
//
// 判定（TODO §0.1-S6）：跑通一次 SMB 目录列举 + Range 读。
//
// 连接目标为本机临时共享（由 smb-setup.ps1 创建），使用一次性测试账户，
// 不涉及用户真实凭据。

// libsmb2.h 会引入 ws2tcpip.h，必须先于其它头拉入 winsock2，
// 否则 windows.h 带入旧版 winsock.h 造成 getsockopt 重载冲突。
#ifndef WIN32_LEAN_AND_MEAN
#  define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#  define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

// smb2.h 使用 uint32_t/uint64_t 但**不自带 <stdint.h>**。
// 在 C++ 下若未先引入，编译器会把类型名当作 override specifier，
// 报出一片误导性的 "未知重写说明符"(C3646)。
#include <cstdint>
#include <fcntl.h>

// smb2.h 须先于 libsmb2.h：前者定义 SMB2_GUID_SIZE 等协议常量
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

FILE *g_report = nullptr;
bool g_allOk = true;

void report(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    if (g_report) {
        va_start(ap, fmt);
        vfprintf(g_report, fmt, ap);
        va_end(ap);
        fflush(g_report);
    }
}

void check(bool cond, const char *label, const std::string &detail)
{
    if (!cond)
        g_allOk = false;
    report("[%s] %-22s %s\n", cond ? "OK" : "FAIL", label, detail.c_str());
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: smb_probe <server> <share> <user> <password>\n");
        return 2;
    }
    const char *server = argv[1];
    const char *share  = argv[2];
    const char *user   = argv[3];
    const char *pass   = argv[4];

    g_report = fopen("s6-smb-report.txt", "w");
    report("=== S6-B: libsmb2 SMB2/3 over MSVC ===\n");
    report("target : \\\\%s\\%s  (user=%s)\n\n", server, share, user);

    // Windows 下需自行初始化 Winsock（libsmb2 不代劳）
    WSADATA wsa {};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        check(false, "WSAStartup", "failed");
        return 1;
    }

    smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        check(false, "smb2_init_context", "returned null");
        WSACleanup();
        return 1;
    }

    smb2_set_user(smb2, user);
    smb2_set_password(smb2, pass);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);

    // ---- 1) 连接 ----
    const int rc = smb2_connect_share(smb2, server, share, user);
    if (rc < 0) {
        std::string err = smb2_get_error(smb2) ? smb2_get_error(smb2) : "unknown";
        check(false, "connect share", "rc=" + std::to_string(rc) + " err=" + err);
        smb2_destroy_context(smb2);
        WSACleanup();
        report("\nRESULT: S6-B FAILED (cannot connect)\n");
        if (g_report) fclose(g_report);
        return 1;
    }
    check(true, "connect share", "connected");

    // ---- 2) 目录列举 ----
    {
        smb2dir *dir = smb2_opendir(smb2, "");
        if (!dir) {
            check(false, "list root", smb2_get_error(smb2) ? smb2_get_error(smb2) : "opendir failed");
        } else {
            std::vector<std::string> names;
            int dirs = 0, files = 0;
            smb2dirent *ent = nullptr;
            while ((ent = smb2_readdir(smb2, dir)) != nullptr) {
                const std::string n = ent->name ? ent->name : "";
                if (n == "." || n == "..")
                    continue;
                const bool isDir = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
                isDir ? ++dirs : ++files;
                names.push_back(n + (isDir ? "/" : ""));
            }
            smb2_closedir(smb2, dir);

            std::string joined;
            for (const std::string &n : names) joined += n + " ";

            char d[384];
            snprintf(d, sizeof(d), "dirs=%d files=%d [%.200s]", dirs, files, joined.c_str());
            check(dirs >= 2 && files >= 2, "list root", d);
        }
    }

    // ---- 3) 子目录列举 ----
    {
        smb2dir *dir = smb2_opendir(smb2, "media");
        if (!dir) {
            check(false, "list subdir", "opendir(media) failed");
        } else {
            int count = 0;
            smb2dirent *ent = nullptr;
            while ((ent = smb2_readdir(smb2, dir)) != nullptr) {
                const std::string n = ent->name ? ent->name : "";
                if (n != "." && n != "..") ++count;
            }
            smb2_closedir(smb2, dir);
            check(count >= 1, "list subdir",
                  "media/ entries=" + std::to_string(count));
        }
    }

    // ---- 4) stat ----
    {
        smb2_stat_64 st {};
        const int r = smb2_stat(smb2, "ramp.bin", &st);
        char d[160];
        snprintf(d, sizeof(d), "size=%llu type=%u",
                 static_cast<unsigned long long>(st.smb2_size), st.smb2_type);
        check(r == 0 && st.smb2_size == 256, "stat ramp.bin", d);
    }

    // ---- 5) Range 读（边下边播的核心能力）----
    {
        smb2fh *fh = smb2_open(smb2, "ramp.bin", O_RDONLY);
        if (!fh) {
            check(false, "open for range read",
                  smb2_get_error(smb2) ? smb2_get_error(smb2) : "open failed");
        } else {
            // ramp.bin 内容为 0..255，故 offset N 处的字节值应等于 N
            struct RangeCase { uint64_t offset; uint32_t len; };
            const RangeCase cases[] = {{0, 16}, {64, 32}, {200, 56}, {255, 1}};

            bool allMatch = true;
            std::string detail;
            for (const RangeCase &c : cases) {
                std::vector<uint8_t> buf(c.len, 0xAA);
                const int n = smb2_pread(smb2, fh, buf.data(), c.len, c.offset);

                bool match = (n == static_cast<int>(c.len));
                if (match) {
                    for (uint32_t i = 0; i < c.len; ++i) {
                        if (buf[i] != static_cast<uint8_t>(c.offset + i)) {
                            match = false;
                            break;
                        }
                    }
                }
                if (!match) allMatch = false;

                char line[80];
                snprintf(line, sizeof(line), "[%llu,+%u)=%s ",
                         static_cast<unsigned long long>(c.offset), c.len,
                         match ? "ok" : "BAD");
                detail += line;
            }
            check(allMatch, "range read", detail);

            // 越界读应返回 0 而非错误数据
            uint8_t tail[8] = {};
            const int n = smb2_pread(smb2, fh, tail, sizeof(tail), 1000);
            check(n <= 0, "read past EOF",
                  "pread(offset=1000) returned " + std::to_string(n));

            smb2_close(smb2, fh);
        }
    }

    // ---- 6) 断开 ----
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
    WSACleanup();
    check(true, "disconnect", "clean");

    report("\n%s\n", g_allOk ? "RESULT: S6-B PASSED" : "RESULT: S6-B HAS FAILURES");
    if (g_report) fclose(g_report);
    return g_allOk ? 0 : 1;
}
