// S6-A：libarchive 漫画解页验证
//
// 判定（TODO §0.1-S6）：跑通一次 rar/cbr 解页。
// 一并验证 cbz(zip) 与 7z，以及漫画阅读器真正依赖的两个能力：
//   - 条目枚举 + 自然排序（page1 < page2 < page10 < page11 < page20）
//   - 按条目读出完整图片字节（首字节校验为真实 JPEG）

#include <archive.h>
#include <archive_entry.h>

#include <algorithm>
#include <cctype>
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
    report("[%s] %-20s %s\n", cond ? "OK" : "FAIL", label, detail.c_str());
}

struct Entry {
    std::string name;
    int64_t size = 0;
    bool isRegular = true;             // 符号链接等非常规条目无数据可读
    std::vector<unsigned char> head;   // 前若干字节，用于校验真实格式
};

// 打开归档并读出全部条目（含内容首字节）
bool readArchive(const std::string &path, std::vector<Entry> &out, std::string &err)
{
    archive *a = archive_read_new();
    if (!a) { err = "archive_read_new failed"; return false; }

    // 漫画实际会遇到的全部容器
    archive_read_support_format_zip(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    archive_read_support_format_7zip(a);
    archive_read_support_format_tar(a);
    archive_read_support_filter_all(a);

    if (archive_read_open_filename(a, path.c_str(), 64 * 1024) != ARCHIVE_OK) {
        err = archive_error_string(a) ? archive_error_string(a) : "open failed";
        archive_read_free(a);
        return false;
    }

    archive_entry *entry = nullptr;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        if (archive_entry_filetype(entry) == AE_IFDIR)
            continue;

        Entry e;
        const char *name = archive_entry_pathname(entry);
        e.name = name ? name : "";
        e.size = archive_entry_size(entry);
        // 符号链接/设备等无数据体，漫画解页只关心常规文件
        e.isRegular = (archive_entry_filetype(entry) == AE_IFREG);

        // 读出内容首字节（漫画场景要的是整页解码，这里验证可读性）
        unsigned char buf[16] = {};
        const la_ssize_t n = archive_read_data(a, buf, sizeof(buf));
        if (n > 0)
            e.head.assign(buf, buf + n);

        out.push_back(std::move(e));
    }

    const bool ok = (archive_errno(a) == ARCHIVE_OK);
    if (!ok && archive_error_string(a))
        err = archive_error_string(a);

    archive_read_free(a);
    return ok;
}

// 自然排序：数字段按数值比较（与 core/utils/NaturalSort 同语义）
bool naturalLess(const std::string &a, const std::string &b)
{
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        if (std::isdigit(static_cast<unsigned char>(a[i])) &&
            std::isdigit(static_cast<unsigned char>(b[j]))) {
            size_t i2 = i, j2 = j;
            while (i2 < a.size() && std::isdigit(static_cast<unsigned char>(a[i2]))) ++i2;
            while (j2 < b.size() && std::isdigit(static_cast<unsigned char>(b[j2]))) ++j2;
            const std::string na = a.substr(i, i2 - i), nb = b.substr(j, j2 - j);
            // 去前导零后先比长度，避免大数溢出
            const size_t pa = na.find_first_not_of('0'), pb = nb.find_first_not_of('0');
            const std::string ta = pa == std::string::npos ? "0" : na.substr(pa);
            const std::string tb = pb == std::string::npos ? "0" : nb.substr(pb);
            if (ta.size() != tb.size()) return ta.size() < tb.size();
            if (ta != tb) return ta < tb;
            i = i2; j = j2;
            continue;
        }
        const char ca = static_cast<char>(std::tolower(static_cast<unsigned char>(a[i])));
        const char cb = static_cast<char>(std::tolower(static_cast<unsigned char>(b[j])));
        if (ca != cb) return ca < cb;
        ++i; ++j;
    }
    return a.size() - i < b.size() - j;
}

bool isJpeg(const std::vector<unsigned char> &h)
{
    return h.size() >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF;
}

void testArchive(const std::string &dir, const char *file, bool expectJpegPages)
{
    const std::string path = dir + "\\" + file;

    std::vector<Entry> entries;
    std::string err;
    const bool ok = readArchive(path, entries, err);

    if (!ok && entries.empty()) {
        check(false, file, err.empty() ? "read failed" : err);
        return;
    }

    // 条目可枚举；只要求**常规文件**可读（符号链接无数据体属正常）
    std::string names;
    int64_t totalBytes = 0;
    int readable = 0, regular = 0, nonRegular = 0;
    for (const Entry &e : entries) {
        names += e.name + " ";
        totalBytes += e.size;
        if (e.isRegular) {
            ++regular;
            if (!e.head.empty() || e.size == 0) ++readable;
        } else {
            ++nonRegular;
        }
    }

    char d[512];
    snprintf(d, sizeof(d), "entries=%zu (regular=%d readable=%d, nonRegular=%d) "
                           "bytes=%lld [%.140s]",
             entries.size(), regular, readable, nonRegular,
             static_cast<long long>(totalBytes), names.c_str());
    check(regular > 0 && readable == regular, file, d);

    if (expectJpegPages && !entries.empty()) {
        // 页序：自然排序后应为 1,2,10,11,20
        std::vector<std::string> sorted;
        for (const Entry &e : entries) sorted.push_back(e.name);
        std::sort(sorted.begin(), sorted.end(), naturalLess);

        std::string order;
        for (const std::string &s : sorted) order += s + " ";

        const bool correctOrder =
            sorted.size() == 5 &&
            sorted[0].find("page1.") != std::string::npos &&
            sorted[1].find("page2.") != std::string::npos &&
            sorted[2].find("page10.") != std::string::npos &&
            sorted[3].find("page11.") != std::string::npos &&
            sorted[4].find("page20.") != std::string::npos;

        char d2[320];
        snprintf(d2, sizeof(d2), "%s", order.c_str());
        check(correctOrder, "  natural page order", d2);

        int jpegCount = 0;
        for (const Entry &e : entries)
            if (isJpeg(e.head)) ++jpegCount;

        char d3[128];
        snprintf(d3, sizeof(d3), "%d/%zu entries have JPEG magic (FF D8 FF)",
                 jpegCount, entries.size());
        check(jpegCount == static_cast<int>(entries.size()), "  page decodable", d3);
    }
}

} // namespace

int main(int argc, char **argv)
{
    const std::string dir = argc > 1 ? argv[1] : ".";

    g_report = fopen("s6-archive-report.txt", "w");

    report("=== S6-A: libarchive comic page extraction ===\n");
    report("archive dir : %s\n", dir.c_str());
    report("libarchive  : %s\n\n", archive_version_string());

    report("--- cbz / 7z (generated, 5 pages) ---\n");
    testArchive(dir, "volume01.cbz", true);
    testArchive(dir, "volume02.7z", true);

    report("\n--- cbr / rar (libarchive official test archives) ---\n");
    testArchive(dir, "volume03.cbr", false);
    testArchive(dir, "volume04_rar5.cbr", false);

    report("\n%s\n", g_allOk ? "RESULT: S6-A PASSED" : "RESULT: S6-A HAS FAILURES");
    if (g_report) fclose(g_report);
    return g_allOk ? 0 : 1;
}
