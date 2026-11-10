// S1-A：libmpv 纯解码能力验证（无 GUI）
//
// 独立回答 S1 判定中与渲染后端无关的部分：
//   - 硬解是否真的生效（hwdec-current 实测，而非只看配置）
//   - 解码 1080p HEVC 的 CPU 占用
//   - seek 是否准确
//   - 多容器（mkv / avi / ts / mp4）能否解复用
//   - 音轨 / 字幕轨能否枚举与切换
//   - 倍速是否生效
//
// 渲染集成（vo=libmpv + Qt 场景图）在 render_probe 中单独验证。

#include <mpv/client.h>

#include <windows.h>

#include <cmath>
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

// 取进程累计 CPU 时间（秒）
double processCpuSeconds()
{
    FILETIME creation {}, exit {}, kernel {}, user {};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        return 0.0;
    auto toSec = [](const FILETIME &ft) {
        ULARGE_INTEGER u;
        u.LowPart = ft.dwLowDateTime;
        u.HighPart = ft.dwHighDateTime;
        return static_cast<double>(u.QuadPart) / 1e7;   // 100ns 单位
    };
    return toSec(kernel) + toSec(user);
}

double wallSeconds()
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return static_cast<double>(c.QuadPart) / static_cast<double>(f.QuadPart);
}

std::string propString(mpv_handle *mpv, const char *name)
{
    char *s = nullptr;
    if (mpv_get_property(mpv, name, MPV_FORMAT_STRING, &s) < 0 || !s)
        return {};
    std::string out(s);
    mpv_free(s);
    return out;
}

double propDouble(mpv_handle *mpv, const char *name)
{
    double v = 0;
    if (mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) < 0)
        return NAN;
    return v;
}

int propInt(mpv_handle *mpv, const char *name)
{
    int64_t v = 0;
    if (mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) < 0)
        return -1;
    return static_cast<int>(v);
}

// 等待文件加载完成；返回是否成功
bool waitLoaded(mpv_handle *mpv, double timeoutSec)
{
    const double deadline = wallSeconds() + timeoutSec;
    while (wallSeconds() < deadline) {
        mpv_event *ev = mpv_wait_event(mpv, 0.1);
        if (ev->event_id == MPV_EVENT_FILE_LOADED)
            return true;
        if (ev->event_id == MPV_EVENT_END_FILE) {
            auto *ef = static_cast<mpv_event_end_file *>(ev->data);
            if (ef && ef->reason == MPV_END_FILE_REASON_ERROR) {
                report("    end-file error: %s\n", mpv_error_string(ef->error));
                return false;
            }
        }
    }
    return false;
}

// 等待播放推进到至少 minPos 秒
bool waitPlaybackProgress(mpv_handle *mpv, double minPos, double timeoutSec)
{
    const double deadline = wallSeconds() + timeoutSec;
    while (wallSeconds() < deadline) {
        mpv_wait_event(mpv, 0.05);
        const double pos = propDouble(mpv, "time-pos");
        if (!std::isnan(pos) && pos >= minPos)
            return true;
    }
    return false;
}

mpv_handle *createMpv(const char *hwdec, const char *vo)
{
    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return nullptr;

    mpv_set_option_string(mpv, "vo", vo);
    mpv_set_option_string(mpv, "ao", "null");
    mpv_set_option_string(mpv, "hwdec", hwdec);
    mpv_set_option_string(mpv, "msg-level", "all=no");
    // 预研需要确定性：关掉配置文件与缓存干扰
    mpv_set_option_string(mpv, "config", "no");
    mpv_set_option_string(mpv, "ytdl", "no");

    if (mpv_initialize(mpv) < 0) {
        mpv_terminate_destroy(mpv);
        return nullptr;
    }
    return mpv;
}

bool loadFile(mpv_handle *mpv, const std::string &path)
{
    const char *cmd[] = {"loadfile", path.c_str(), nullptr};
    if (mpv_command(mpv, cmd) < 0)
        return false;
    return waitLoaded(mpv, 15.0);
}

// ---------------------------------------------------------------------------

std::string g_mediaDir;

std::string media(const char *name)
{
    return g_mediaDir + "\\" + name;
}

// 1) 解码器可初始化性
//
// ⚠️ 重要限制：本探针用 vo=null（无渲染上下文）。
//   - 真正的 zero-copy 硬解（hwdec=d3d11va）**需要 GPU 渲染上下文**，
//     在 vo=null 下必然回退软解（hwdec-current=no）——这是预期行为，不是缺陷。
//   - vo=null 下解码帧会被立即丢弃，故 **CPU 占用与丢帧数在此处无参考价值**，
//     硬解生效性与 CPU 占用一律以 render_probe（真实渲染路径）为准。
//
// 本函数只回答：各 hwdec 模式能否初始化且不致播放失败（容错性）。
void testHardwareDecode()
{
    report("\n--- 1) decoder init under vo=null (NOT a hwdec verdict) ---\n");

    struct Mode { const char *hwdec; const char *label; };
    const Mode modes[] = {
        {"no",              "software"},
        {"d3d11va",         "d3d11va"},
        {"d3d11va-copy",    "d3d11va-copy"},
        {"auto-safe",       "auto-safe"},
    };

    for (const Mode &m : modes) {
        mpv_handle *mpv = createMpv(m.hwdec, "null");
        if (!mpv) {
            check(false, m.label, "mpv_create/initialize failed");
            continue;
        }

        if (!loadFile(mpv, media("hevc_1080p.mkv"))) {
            check(false, m.label, "load failed");
            mpv_terminate_destroy(mpv);
            continue;
        }

        const std::string current = propString(mpv, "hwdec-current");
        const std::string codec   = propString(mpv, "video-codec");

        // 正常速度播放一小段，确认解复用+解码管线不报错即可
        const bool advanced = waitPlaybackProgress(mpv, 0.5, 10.0);

        char detail[256];
        snprintf(detail, sizeof(detail),
                 "hwdec-current=%-14s codec=%.20s advancing=%s",
                 current.empty() ? "(none)" : current.c_str(),
                 codec.c_str(), advanced ? "yes" : "no");
        check(advanced, m.label, detail);

        mpv_terminate_destroy(mpv);
    }
    report("    (zero-copy hwdec + CPU usage are measured in render_probe)\n");
}

// 2) seek 准确性
void testSeek()
{
    report("\n--- 2) seek accuracy ---\n");

    mpv_handle *mpv = createMpv("auto-safe", "null");
    if (!mpv || !loadFile(mpv, media("hevc_1080p.mkv"))) {
        check(false, "seek", "setup failed");
        if (mpv) mpv_terminate_destroy(mpv);
        return;
    }

    mpv_set_option_string(mpv, "pause", "yes");

    const double targets[] = {5.0, 20.0, 12.5, 0.0, 29.0};
    bool allAccurate = true;
    std::string detail;

    for (double t : targets) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%.3f", t);
        const char *cmd[] = {"seek", buf, "absolute", "exact", nullptr};
        if (mpv_command(mpv, cmd) < 0) {
            allAccurate = false;
            continue;
        }

        // 等 seek 落定
        const double deadline = wallSeconds() + 5.0;
        bool settled = false;
        while (wallSeconds() < deadline) {
            mpv_event *ev = mpv_wait_event(mpv, 0.05);
            if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART) { settled = true; break; }
        }

        const double pos = propDouble(mpv, "time-pos");
        const double err = std::isnan(pos) ? 999.0 : std::fabs(pos - t);
        if (err > 0.5 || !settled)
            allAccurate = false;

        char line[128];
        snprintf(line, sizeof(line), "%.1f->%.2f(err %.3f) ", t, pos, err);
        detail += line;
    }

    check(allAccurate, "seek exact", detail);
    mpv_terminate_destroy(mpv);
}

// 3) 多容器解复用
void testContainers()
{
    report("\n--- 3) container demuxing ---\n");

    const char *files[] = {"hevc_1080p.mkv", "multitrack.mkv",
                           "sample.avi", "sample.ts", "sample.mp4"};

    for (const char *f : files) {
        mpv_handle *mpv = createMpv("auto-safe", "null");
        if (!mpv) continue;

        const bool loaded = loadFile(mpv, media(f));
        std::string detail;
        if (loaded) {
            const std::string codec = propString(mpv, "video-codec");
            const double dur = propDouble(mpv, "duration");
            const int w = propInt(mpv, "width");
            const int h = propInt(mpv, "height");
            // 确认能真正解出帧，而不只是打开了容器
            const bool advanced = waitPlaybackProgress(mpv, 0.3, 10.0);
            char buf[160];
            snprintf(buf, sizeof(buf), "codec=%s %dx%d dur=%.1fs frames_advancing=%s",
                     codec.c_str(), w, h, dur, advanced ? "yes" : "no");
            detail = buf;
            if (!advanced) g_allOk = false;
        } else {
            detail = "load failed";
        }
        check(loaded, f, detail);
        mpv_terminate_destroy(mpv);
    }
}

// 4) 音轨 / 字幕轨枚举与切换
void testTracks()
{
    report("\n--- 4) track enumeration & switching ---\n");

    mpv_handle *mpv = createMpv("auto-safe", "null");
    if (!mpv || !loadFile(mpv, media("multitrack.mkv"))) {
        check(false, "tracks", "setup failed");
        if (mpv) mpv_terminate_destroy(mpv);
        return;
    }

    const int trackCount = propInt(mpv, "track-list/count");
    int audioTracks = 0;
    std::string langs;
    for (int i = 0; i < trackCount; ++i) {
        char key[64];
        snprintf(key, sizeof(key), "track-list/%d/type", i);
        const std::string type = propString(mpv, key);
        if (type == "audio") {
            ++audioTracks;
            snprintf(key, sizeof(key), "track-list/%d/lang", i);
            const std::string lang = propString(mpv, key);
            langs += (lang.empty() ? "?" : lang);
            langs += " ";
        }
    }

    char d1[128];
    snprintf(d1, sizeof(d1), "total=%d audio=%d langs=[%s]",
             trackCount, audioTracks, langs.c_str());
    check(audioTracks >= 2, "audio track enum", d1);

    // 切到第二条音轨
    mpv_set_option_string(mpv, "pause", "yes");
    const int before = propInt(mpv, "aid");
    mpv_set_property_string(mpv, "aid", "2");
    const int after = propInt(mpv, "aid");
    char d2[96];
    snprintf(d2, sizeof(d2), "aid %d -> %d", before, after);
    check(after == 2 && after != before, "audio track switch", d2);

    // 外挂字幕
    mpv_terminate_destroy(mpv);
    mpv = createMpv("auto-safe", "null");
    if (mpv && loadFile(mpv, media("hevc_1080p.mkv"))) {
        const std::string sub = media("hevc_1080p.srt");
        const char *cmd[] = {"sub-add", sub.c_str(), nullptr};
        const bool added = mpv_command(mpv, cmd) >= 0;
        const int subCount = propInt(mpv, "sub-text") >= 0 ? 1 : 0;
        (void)subCount;
        const int sid = propInt(mpv, "sid");
        char d3[96];
        snprintf(d3, sizeof(d3), "sub-add ok=%d sid=%d", added ? 1 : 0, sid);
        check(added && sid >= 1, "external subtitle", d3);
    }
    if (mpv) mpv_terminate_destroy(mpv);
}

// 5) 字幕文本编码（UTF-8 中文是否被正确解码）
//
// 起因：render_probe 截帧中中文字幕显示为乱码。此处用 sub-text 属性做客观比对，
// 不依赖肉眼看图。字幕文件为**带 BOM 的 UTF-8**，理应被无条件正确识别。
void testSubtitleEncoding()
{
    report("\n--- 5) subtitle text encoding ---\n");

    // 预期首行文本（源文件以 UTF-8 存储）
    const char *expected = "MyHub S1 \xE5\xAD\x97\xE5\xB9\x95\xE6\xB5\x8B\xE8\xAF\x95";

    // 额外生成一份**无 BOM** 的 UTF-8 字幕作对照，判定 BOM 是否为诱因
    const std::string noBomPath = g_mediaDir + "\\nobom.srt";
    {
        FILE *f = fopen(noBomPath.c_str(), "wb");
        if (f) {
            const char *srt =
                "1\r\n00:00:01,000 --> 00:00:04,000\r\n"
                "MyHub S1 \xE5\xAD\x97\xE5\xB9\x95\xE6\xB5\x8B\xE8\xAF\x95\r\n\r\n";
            fwrite(srt, 1, strlen(srt), f);
            fclose(f);
        }
    }

    struct Case { const char *codepage; const char *subFile; const char *label; };
    const Case cases[] = {
        {nullptr,  "hevc_1080p.srt", "auto + BOM"},
        {"utf-8",  "hevc_1080p.srt", "utf-8 + BOM"},
        {nullptr,  nullptr,          "auto + no BOM"},
        {"utf-8",  nullptr,          "utf-8 + no BOM"},
    };

    for (const Case &c : cases) {
        mpv_handle *mpv = createMpv("auto-safe", "null");
        if (!mpv) continue;

        if (c.codepage)
            mpv_set_option_string(mpv, "sub-codepage", c.codepage);

        if (!loadFile(mpv, media("hevc_1080p.mkv"))) {
            check(false, c.label, "load failed");
            mpv_terminate_destroy(mpv);
            continue;
        }

        const std::string sub = c.subFile ? media(c.subFile) : noBomPath;
        const char *addCmd[] = {"sub-add", sub.c_str(), nullptr};
        mpv_command(mpv, addCmd);

        // 跳到字幕可见区间（第一条 1s~4s）
        const char *seekCmd[] = {"seek", "2.0", "absolute", "exact", nullptr};
        mpv_command(mpv, seekCmd);

        // 等字幕渲染出文本
        std::string text;
        const double deadline = wallSeconds() + 5.0;
        while (wallSeconds() < deadline) {
            mpv_wait_event(mpv, 0.05);
            text = propString(mpv, "sub-text");
            if (!text.empty()) break;
        }

        const bool match = text.find(expected) != std::string::npos;

        // 输出十六进制：控制台代码页是 GBK，直接打印会二次失真，
        // 只有字节级比对才能判定「是 mpv 解码错」还是「只是显示错」。
        std::string hex;
        for (size_t i = 0; i < text.size() && i < 28; ++i) {
            char b[4];
            snprintf(b, sizeof(b), "%02X ", static_cast<unsigned char>(text[i]));
            hex += b;
        }
        std::string expHex;
        for (size_t i = 0; expected[i] && i < 28; ++i) {
            char b[4];
            snprintf(b, sizeof(b), "%02X ", static_cast<unsigned char>(expected[i]));
            expHex += b;
        }

        char detail[512];
        snprintf(detail, sizeof(detail), "%s\n        got : %s\n        want: %s",
                 match ? "matches UTF-8" : "MISMATCH", hex.c_str(), expHex.c_str());
        check(match, c.label, detail);

        mpv_terminate_destroy(mpv);
    }
}

// 6) 倍速
void testSpeed()
{
    report("\n--- 5) playback speed ---\n");

    mpv_handle *mpv = createMpv("auto-safe", "null");
    if (!mpv || !loadFile(mpv, media("hevc_1080p.mkv"))) {
        check(false, "speed", "setup failed");
        if (mpv) mpv_terminate_destroy(mpv);
        return;
    }

    bool allOk = true;
    std::string detail;
    for (double s : {0.5, 1.0, 1.5, 2.0, 3.0}) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%.2f", s);
        mpv_set_property_string(mpv, "speed", buf);
        const double got = propDouble(mpv, "speed");
        if (std::isnan(got) || std::fabs(got - s) > 0.01)
            allOk = false;
        char line[32];
        snprintf(line, sizeof(line), "%.1fx ", got);
        detail += line;
    }
    check(allOk, "speed set/get", detail);
    mpv_terminate_destroy(mpv);
}

} // namespace

int main(int argc, char **argv)
{
    g_mediaDir = (argc > 1) ? argv[1] : ".";

    g_report = fopen("s1-decode-report.txt", "w");

    report("=== S1-A: libmpv decode capability probe ===\n");
    report("media dir : %s\n", g_mediaDir.c_str());
    report("mpv api   : %lu.%lu\n",
           mpv_client_api_version() >> 16, mpv_client_api_version() & 0xFFFF);

    {
        mpv_handle *mpv = createMpv("auto-safe", "null");
        if (mpv) {
            report("mpv version: %s\n", propString(mpv, "mpv-version").c_str());
            report("ffmpeg     : %s\n", propString(mpv, "ffmpeg-version").c_str());
            mpv_terminate_destroy(mpv);
        }
    }

    testHardwareDecode();
    testSeek();
    testContainers();
    testTracks();
    testSubtitleEncoding();
    testSpeed();

    report("\n%s\n", g_allOk ? "RESULT: S1-A PASSED" : "RESULT: S1-A HAS FAILURES");

    if (g_report)
        fclose(g_report);
    return g_allOk ? 0 : 1;
}
