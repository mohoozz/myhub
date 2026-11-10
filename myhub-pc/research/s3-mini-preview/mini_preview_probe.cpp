// S3：mini 实时预览（单会话双处渲染）
//
// 判定（TODO §0.1-S3 + 需求 §2.4）：
//   1. 主画面与 mini 预览**同时渲染且互不干扰**
//   2. 两处画面内容一致（证明 mini 是同一会话的实时画面，而非静态图/另一实例）
//   3. 主画面隐藏后 mini 仍能出画（对应「mini 条跨页面保持」）
//   4. reparent（全屏 ↔ mini）**不重载会话**：fileLoadedCount 不增、position 连续
//   5. 只有一个 mpv 实例 —— 双处渲染不应带来成倍 CPU 开销
//
// 测量方法说明：
//   - `grabWindow()` 会阻塞渲染线程强制同步，本身就会制造丢帧，
//     故丢帧只在**无 grab 的稳态窗口**内测。
//   - 丢帧存在偶发性，单次采样不足以下结论。因此对 main-only 与 main+mini
//     各取**等长的稳态窗口**作对照，并支持多轮重复（--rounds N）取汇总。
//
// 输出：s3-mini-report.txt + 截帧 PNG

#include "PreviewPlayer.h"

#include <QGuiApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QTextStream>
#include <QTimer>

// windows.h 的 min/max 宏会破坏 std::min —— 必须在包含前抑制
#ifndef NOMINMAX
#  define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cmath>

namespace {

QTextStream *g_out = nullptr;
bool g_allOk = true;

void report(const QString &line)
{
    fprintf(stdout, "%s\n", qPrintable(line));
    fflush(stdout);
    if (g_out) { *g_out << line << '\n'; g_out->flush(); }
}

void check(bool cond, const QString &label, const QString &detail)
{
    if (!cond) g_allOk = false;
    report(QStringLiteral("[%1] %2 %3")
               .arg(cond ? QStringLiteral("OK") : QStringLiteral("FAIL"),
                    label.leftJustified(26), detail));
}

double processCpuSeconds()
{
    FILETIME creation {}, exitT {}, kernel {}, user {};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exitT, &kernel, &user))
        return 0.0;
    auto toSec = [](const FILETIME &ft) {
        ULARGE_INTEGER u;
        u.LowPart = ft.dwLowDateTime;
        u.HighPart = ft.dwHighDateTime;
        return static_cast<double>(u.QuadPart) / 1e7;
    };
    return toSec(kernel) + toSec(user);
}

struct RegionStats {
    double nonBlackRatio = 0;
    int distinctColors = 0;
    double meanLuma = 0;
    QList<double> hist;      // 12 bin 亮度分布，用于判定两区域是否同源
};

RegionStats analyzeRegion(const QImage &img, const QRect &r)
{
    RegionStats s;
    if (img.isNull() || r.isEmpty())
        return s;

    const QRect clipped = r.intersected(img.rect());
    if (clipped.isEmpty())
        return s;

    const QImage rgb = img.copy(clipped).convertToFormat(QImage::Format_RGB32);
    QSet<QRgb> colors;
    qint64 nonBlack = 0, total = 0, lumaSum = 0;
    QList<qint64> bins(12, 0);

    const int step = qMax(1, qMin(rgb.width(), rgb.height()) / 60);
    for (int y = 0; y < rgb.height(); y += step) {
        for (int x = 0; x < rgb.width(); x += step) {
            const QRgb px = rgb.pixel(x, y);
            const int luma = qGray(px);
            ++total;
            lumaSum += luma;
            if (luma > 16) ++nonBlack;
            if (colors.size() < 4096) colors.insert(px & 0xF0F0F0);
            bins[qMin(11, luma * 12 / 256)] += 1;
        }
    }

    if (total > 0) {
        s.nonBlackRatio = static_cast<double>(nonBlack) / total;
        s.meanLuma = static_cast<double>(lumaSum) / total;
        for (qint64 b : bins)
            s.hist.append(static_cast<double>(b) / total);
    }
    s.distinctColors = colors.size();
    return s;
}

double histSimilarity(const RegionStats &a, const RegionStats &b)
{
    if (a.hist.size() != b.hist.size() || a.hist.isEmpty())
        return 0.0;
    double sum = 0;
    for (int i = 0; i < a.hist.size(); ++i)
        sum += std::min(a.hist[i], b.hist[i]);
    return sum;
}

} // namespace

int main(int argc, char *argv[])
{
    const QString mediaDir = argc > 1 ? QString::fromLocal8Bit(argv[1])
                                      : QStringLiteral(".");
    // 丢帧有偶发性，可重复多轮稳态对照
    const int rounds = argc > 2 ? qMax(1, QString::fromLocal8Bit(argv[2]).toInt()) : 3;

    // mpvqt(FBO) 的硬性要求，见需求文档 §4.3.1
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);

    QFile outFile(QStringLiteral("s3-mini-report.txt"));
    outFile.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream ts(&outFile);
    g_out = &ts;

    report(QStringLiteral("=== S3: mini live preview (single session, dual render) ==="));
    report(QStringLiteral("steady-state rounds : %1 x 2.8s per mode").arg(rounds));

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(3); }, Qt::QueuedConnection);
    engine.loadFromModule("S3Probe", "MiniPreviewProbe");

    if (engine.rootObjects().isEmpty()) {
        check(false, QStringLiteral("QML load"), QStringLiteral("no root object"));
        return 3;
    }
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window)
        return 3;

    auto *player = window->findChild<PreviewPlayer *>(QStringLiteral("videoPlayer"));
    auto *stageHost = window->findChild<QQuickItem *>(QStringLiteral("stageHost"));
    auto *miniStage = window->findChild<QQuickItem *>(QStringLiteral("miniStage"));
    if (!player || !stageHost || !miniStage) {
        check(false, QStringLiteral("QML objects"), QStringLiteral("missing named items"));
        return 3;
    }

    auto rectOf = [&](QQuickItem *item) -> QRect {
        if (!item) return {};
        const QPointF tl = item->mapToScene(QPointF(0, 0));
        const qreal dpr = window->devicePixelRatio();
        return QRect(static_cast<int>(tl.x() * dpr), static_cast<int>(tl.y() * dpr),
                     static_cast<int>(item->width() * dpr),
                     static_cast<int>(item->height() * dpr));
    };
    auto miniPreviewRect = [&]() {
        return rectOf(window->findChild<QQuickItem *>(QStringLiteral("miniPreview")));
    };
    auto drops = [&]() {
        return player->mpvProperty(QStringLiteral("frame-drop-count")).toDouble();
    };

    // ---- 稳态采样器：在无 grab 的窗口内测 drops 与 CPU ----
    struct Sampler {
        double drops0 = 0, cpu0 = 0, wall0 = 0, pos0 = 0;
        QList<double> dropDeltas;
        QList<double> cpuRatios;
        int wrapped = 0;          // 播放回绕次数（会重置 frame-drop-count，必须排除）

        void begin(double d, double c, double w, double p)
        {
            drops0 = d; cpu0 = c; wall0 = w; pos0 = p;
        }
        void end(double d, double c, double w, double p)
        {
            // 回绕（loop 到头重播）时 mpv 重置 frame-drop-count，
            // 该轮数据无效，直接丢弃，否则会出现负增量污染结论。
            if (p < pos0 || d < drops0) {
                ++wrapped;
                return;
            }
            dropDeltas.append(d - drops0);
            cpuRatios.append((c - cpu0) / qMax(0.001, w - wall0));
        }
        double maxDrops() const
        {
            double m = 0;
            for (double d : dropDeltas) m = std::max(m, d);
            return m;
        }
        double totalDrops() const
        {
            double s = 0;
            for (double d : dropDeltas) s += d;
            return s;
        }
        double avgCpu() const
        {
            if (cpuRatios.isEmpty()) return 0;
            double s = 0;
            for (double c : cpuRatios) s += c;
            return s / cpuRatios.size();
        }
        QString dropsList() const
        {
            if (dropDeltas.isEmpty())
                return QStringLiteral("(no valid round)");
            QStringList parts;
            for (double d : dropDeltas) parts << QString::number(d, 'f', 0);
            QString s = parts.join(QLatin1Char('/'));
            if (wrapped > 0)
                s += QStringLiteral("  [%1 round(s) discarded: playback wrapped]").arg(wrapped);
            return s;
        }
        int validRounds() const { return dropDeltas.size(); }
    };

    // 三组等长对照：仅主画面 / 双处渲染(全分辨率纹理) / 双处渲染(限制纹理尺寸)
    Sampler mainOnly, dual, dualOptimized;

    int phase = 0;
    int round = 0;
    int loadsAfterStart = 0;
    double posBeforeReparent = 0;
    double dropsBeforeSwitch = 0, dropsOnHide = 0, dropsOnReparent = 0;
    double dropsAtStartup = 0;
    bool layerRequired = false;

    QElapsedTimer wall;
    wall.start();

    auto *timer = new QTimer(&app);
    timer->setInterval(1400);

    QObject::connect(timer, &QTimer::timeout, &app, [&]() {
        const double now = wall.elapsed() / 1000.0;

        switch (phase) {
        // ---------- 启动 ----------
        case 0:
            if (window->rendererInterface()) {
                report(QStringLiteral("backend             : %1")
                           .arg(window->rendererInterface()->graphicsApi()
                                        == QSGRendererInterface::OpenGL
                                    ? QStringLiteral("OpenGL")
                                    : QStringLiteral("other")));
            }
            player->loadFile(mediaDir + QStringLiteral("/long_1080p.mkv"));
            break;

        case 1:
            // 已加载完成，此刻的丢帧数即启动期开销
            dropsAtStartup = drops();
            loadsAfterStart = player->fileLoadedCount();
            report(QStringLiteral("\n--- A: steady-state baseline, MAIN ONLY (%1 rounds) ---")
                       .arg(rounds));
            mainOnly.begin(drops(), processCpuSeconds(), now, player->position());
            break;

        // ---------- A：main-only 稳态对照（每轮 2 个周期 = 2.8s）----------
        case 2:
            break;

        case 3:
            mainOnly.end(drops(), processCpuSeconds(), now, player->position());
            if (++round < rounds) {
                mainOnly.begin(drops(), processCpuSeconds(), now, player->position());
                // return 不走 ++phase，故直接设为下一轮要执行的空等待阶段
                phase = 2;
                return;
            }
            report(QStringLiteral("    main-only drops per round: %1")
                       .arg(mainOnly.dropsList()));
            round = 0;
            break;

        case 4: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-main-only.png"));
            const RegionStats st = analyzeRegion(frame, rectOf(stageHost));

            check(st.nonBlackRatio > 0.5 && st.distinctColors > 20,
                  QStringLiteral("main stage renders"),
                  QStringLiteral("nonBlack=%1% colors=%2")
                      .arg(st.nonBlackRatio * 100, 0, 'f', 1).arg(st.distinctColors));

            window->setProperty("miniVisible", true);
            report(QStringLiteral("\n--- B: main + mini preview ---"));
            break;
        }

        case 5:
            break;      // 让 mini 稳定渲染

        case 6: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-dual.png"));

            const RegionStats stage = analyzeRegion(frame, rectOf(stageHost));
            const RegionStats mini = analyzeRegion(frame, miniPreviewRect());

            check(mini.nonBlackRatio > 0.5 && mini.distinctColors > 8,
                  QStringLiteral("mini preview renders"),
                  QStringLiteral("nonBlack=%1% colors=%2 meanLuma=%3")
                      .arg(mini.nonBlackRatio * 100, 0, 'f', 1)
                      .arg(mini.distinctColors).arg(mini.meanLuma, 0, 'f', 1));

            check(stage.nonBlackRatio > 0.5,
                  QStringLiteral("main still renders"),
                  QStringLiteral("nonBlack=%1% (mini does not blank the main stage)")
                      .arg(stage.nonBlackRatio * 100, 0, 'f', 1));

            // 同源判定：mini 若是另一实例或静态图，直方图不会如此接近
            const double sim = histSimilarity(stage, mini);
            check(sim > 0.70,
                  QStringLiteral("mini mirrors main"),
                  QStringLiteral("luma-hist similarity=%1 (main %2 vs mini %3)")
                      .arg(sim, 0, 'f', 3).arg(stage.meanLuma, 0, 'f', 1)
                      .arg(mini.meanLuma, 0, 'f', 1));

            check(player->fileLoadedCount() == loadsAfterStart,
                  QStringLiteral("single mpv session"),
                  QStringLiteral("fileLoadedCount stayed %1 (no second instance)")
                      .arg(player->fileLoadedCount()));

            report(QStringLiteral("\n--- C: steady-state DUAL render (%1 rounds, no grab) ---")
                       .arg(rounds));
            dual.begin(drops(), processCpuSeconds(), now, player->position());
            break;
        }

        // ---------- C：dual 稳态（与 A 等长，严格对照）----------
        case 7:
            break;

        case 8: {
            dual.end(drops(), processCpuSeconds(), now, player->position());
            if (++round < rounds) {
                dual.begin(drops(), processCpuSeconds(), now, player->position());
                phase = 7;      // 空等待阶段，不可回到带判定的 case 6
                return;
            }
            report(QStringLiteral("    dual drops per round     : %1").arg(dual.dropsList()));

            // 开启纹理尺寸限制，做第三组等长对照
            window->setProperty("limitTextureSize", true);
            report(QStringLiteral("\n--- C2: steady-state DUAL with textureSize limited "
                                  "to 114x64 (%1 rounds) ---").arg(rounds));
            round = 0;
            dualOptimized.begin(drops(), processCpuSeconds(), now, player->position());
            break;
        }

        case 9:
            break;

        case 10: {
            dualOptimized.end(drops(), processCpuSeconds(), now, player->position());
            if (++round < rounds) {
                dualOptimized.begin(drops(), processCpuSeconds(), now, player->position());
                phase = 9;      // 空等待阶段，不可回到带判定的 case 8
                return;
            }
            report(QStringLiteral("    dual(optimized) per round: %1")
                       .arg(dualOptimized.dropsList()));

            // 核心判定：双处渲染的丢帧不应显著高于**等长的单处基线**
            const double extra = dualOptimized.totalDrops() - mainOnly.totalDrops();
            const bool enoughData =
                mainOnly.validRounds() > 0 && dualOptimized.validRounds() > 0;
            check(enoughData && extra <= 2,
                  QStringLiteral("mini adds no drops"),
                  QStringLiteral("optimized=%1 vs main-only=%2 (extra=%3); "
                                 "unoptimized was %4")
                      .arg(dualOptimized.totalDrops(), 0, 'f', 0)
                      .arg(mainOnly.totalDrops(), 0, 'f', 0)
                      .arg(extra, 0, 'f', 0)
                      .arg(dual.totalDrops(), 0, 'f', 0));

            report(QStringLiteral("\n--- D: hide main, mini only ---"));
            dropsBeforeSwitch = drops();
            window->setProperty("mainVisible", false);
            break;
        }

        case 11:
            break;

        case 12: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-mini-only.png"));
            const RegionStats mini = analyzeRegion(frame, miniPreviewRect());

            // 「mini 条跨页面保持」的关键：主画面不可见时 mini 仍须有画面
            check(mini.nonBlackRatio > 0.5 && mini.distinctColors > 8,
                  QStringLiteral("mini survives hidden main"),
                  QStringLiteral("nonBlack=%1% colors=%2")
                      .arg(mini.nonBlackRatio * 100, 0, 'f', 1).arg(mini.distinctColors));

            check(player->position() > 0.5,
                  QStringLiteral("playback continues"),
                  QStringLiteral("time-pos=%1s while main hidden")
                      .arg(player->position(), 0, 'f', 2));

            dropsOnHide = drops() - dropsBeforeSwitch;

            // 对照：关掉 layer.enabled，主画面仍隐藏，看 mini 是否还能出画。
            // 这决定了 M2 实现时 layer 是不是必需品。
            window->setProperty("playerLayerEnabled", false);
            break;
        }

        case 13: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-mini-nolayer.png"));
            const RegionStats mini = analyzeRegion(frame, miniPreviewRect());
            layerRequired = !(mini.nonBlackRatio > 0.5 && mini.distinctColors > 8);
            report(QStringLiteral("    (control) layer.enabled=false while main hidden: "
                                  "mini nonBlack=%1% colors=%2 -> layer is %3")
                       .arg(mini.nonBlackRatio * 100, 0, 'f', 1)
                       .arg(mini.distinctColors)
                       .arg(layerRequired ? QStringLiteral("REQUIRED")
                                          : QStringLiteral("not required")));

            window->setProperty("playerLayerEnabled", true);
            window->setProperty("mainVisible", true);
            report(QStringLiteral("\n--- E: reparent to mini stage ---"));
            posBeforeReparent = player->position();
            dropsBeforeSwitch = drops();
            break;
        }

        case 14:
            // 把播放器 Item 整体移入 mini 容器（模拟「进入 mini 播放条」）
            player->setParentItem(miniStage);
            player->setWidth(miniStage->width());
            player->setHeight(miniStage->height());
            break;

        case 15: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-reparented.png"));
            const RegionStats st = analyzeRegion(frame, rectOf(miniStage));

            check(st.nonBlackRatio > 0.5,
                  QStringLiteral("renders after reparent"),
                  QStringLiteral("nonBlack=%1% colors=%2")
                      .arg(st.nonBlackRatio * 100, 0, 'f', 1).arg(st.distinctColors));

            check(player->fileLoadedCount() == loadsAfterStart,
                  QStringLiteral("session NOT reloaded"),
                  QStringLiteral("fileLoadedCount %1 -> %2")
                      .arg(loadsAfterStart).arg(player->fileLoadedCount()));

            const double posNow = player->position();
            check(posNow >= posBeforeReparent - 0.05,
                  QStringLiteral("position continuous"),
                  QStringLiteral("%1s -> %2s (no rewind to 0)")
                      .arg(posBeforeReparent, 0, 'f', 2).arg(posNow, 0, 'f', 2));

            dropsOnReparent = drops() - dropsBeforeSwitch;

            // 还原到主舞台（模拟「点击 mini 展开回全屏」）
            player->setParentItem(stageHost);
            player->setWidth(stageHost->width());
            player->setHeight(stageHost->height());
            report(QStringLiteral("\n--- F: back to full stage ---"));
            break;
        }

        case 16:
            break;

        case 17: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s3-frame-restored.png"));
            const RegionStats st = analyzeRegion(frame, rectOf(stageHost));

            check(st.nonBlackRatio > 0.5,
                  QStringLiteral("restored to full"),
                  QStringLiteral("nonBlack=%1%").arg(st.nonBlackRatio * 100, 0, 'f', 1));

            check(player->fileLoadedCount() == loadsAfterStart,
                  QStringLiteral("still same session"),
                  QStringLiteral("fileLoadedCount=%1 across 2 reparents")
                      .arg(player->fileLoadedCount()));

            const double fps =
                player->mpvProperty(QStringLiteral("estimated-vf-fps")).toDouble();

            report(QStringLiteral("\n--- measurements ---"));
            report(QStringLiteral("hwdec               : %1").arg(player->hwdec()));
            report(QStringLiteral("vf-fps              : %1").arg(fps, 0, 'f', 1));
            report(QStringLiteral("CPU main-only       : %1%% of one core")
                       .arg(mainOnly.avgCpu() * 100, 0, 'f', 1));
            report(QStringLiteral("CPU main+mini(full) : %1%% of one core")
                       .arg(dual.avgCpu() * 100, 0, 'f', 1));
            report(QStringLiteral("CPU main+mini(opt)  : %1%% of one core")
                       .arg(dualOptimized.avgCpu() * 100, 0, 'f', 1));
            report(QStringLiteral("drops main-only     : %1 (per round: %2)")
                       .arg(mainOnly.totalDrops(), 0, 'f', 0).arg(mainOnly.dropsList()));
            report(QStringLiteral("drops mini full-res : %1 (per round: %2)  <- 1920x1080 copy")
                       .arg(dual.totalDrops(), 0, 'f', 0).arg(dual.dropsList()));
            report(QStringLiteral("drops mini 114x64   : %1 (per round: %2)  <- textureSize set")
                       .arg(dualOptimized.totalDrops(), 0, 'f', 0)
                       .arg(dualOptimized.dropsList()));
            report(QStringLiteral("layer.enabled       : %1 for mini to render "
                                  "while main is hidden")
                       .arg(layerRequired ? QStringLiteral("REQUIRED")
                                          : QStringLiteral("not required")));
            report(QStringLiteral("drops on hide-main  : %1").arg(dropsOnHide, 0, 'f', 0));
            report(QStringLiteral("drops on reparent   : %1").arg(dropsOnReparent, 0, 'f', 0));
            report(QStringLiteral("drops at startup    : %1").arg(dropsAtStartup, 0, 'f', 0));
            report(QStringLiteral("drops total         : %1 (incl. grabWindow stalls, "
                                  "which are a measurement artifact)")
                       .arg(drops(), 0, 'f', 0));
            break;
        }

        default:
            report(QStringLiteral("\n%1")
                       .arg(g_allOk ? QStringLiteral("RESULT: S3 PASSED")
                                    : QStringLiteral("RESULT: S3 HAS FAILURES")));
            QCoreApplication::exit(g_allOk ? 0 : 1);
            return;
        }
        ++phase;
    });

    timer->start();

    QTimer::singleShot(120000, &app, [] {
        report(QStringLiteral("TIMEOUT"));
        QCoreApplication::exit(4);
    });

    const int rc = app.exec();
    outFile.close();
    return rc;
}
