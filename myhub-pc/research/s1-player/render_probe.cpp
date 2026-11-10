// S1-B：libmpv → Qt Quick 场景图渲染集成验证
//
// 验证点：
//   - mpvqt 的 MpvAbstractItem 能否在 Qt Quick 中真正出画（非黑屏）
//   - Windows 上需要哪个 RHI 后端（mpvqt 基于 QQuickFramebufferObject = OpenGL）
//   - 渲染路径下硬解是否仍然生效
//   - QML 叠加层是否会被视频遮挡（S2 的前置判定）
//   - 用 grabWindow 截帧取像素，作为「真的有画面」的客观证据
//
// 输出：s1-render-report.txt + 若干 PNG 截帧

#include "ProbePlayer.h"

#include <QGuiApplication>
#include <QFile>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QTextStream>
#include <QTimer>
#include <QtMath>

#include <windows.h>

#include <cmath>

namespace {

QTextStream *g_out = nullptr;
bool g_allOk = true;

void report(const QString &line)
{
    fprintf(stdout, "%s\n", qPrintable(line));
    fflush(stdout);
    if (g_out) {
        *g_out << line << '\n';
        g_out->flush();
    }
}

void check(bool cond, const QString &label, const QString &detail)
{
    if (!cond)
        g_allOk = false;
    report(QStringLiteral("[%1] %2 %3")
               .arg(cond ? QStringLiteral("OK") : QStringLiteral("FAIL"),
                    label.leftJustified(24), detail));
}

// 进程累计 CPU 时间（秒）—— 在真实渲染路径下测才有意义
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

QString backendName(QSGRendererInterface::GraphicsApi api)
{
    switch (api) {
    case QSGRendererInterface::OpenGL:     return QStringLiteral("OpenGL");
    case QSGRendererInterface::Direct3D11: return QStringLiteral("D3D11");
    case QSGRendererInterface::Direct3D12: return QStringLiteral("D3D12");
    case QSGRendererInterface::Vulkan:     return QStringLiteral("Vulkan");
    case QSGRendererInterface::Metal:      return QStringLiteral("Metal");
    case QSGRendererInterface::Software:   return QStringLiteral("Software");
    default:                               return QStringLiteral("Unknown");
    }
}

// 统计图像的「非黑像素占比」与颜色丰富度 —— 用于客观判定是否真的出画
struct FrameStats {
    double nonBlackRatio = 0;
    int distinctColors = 0;
    double meanLuma = 0;
};

FrameStats analyze(const QImage &img)
{
    FrameStats s;
    if (img.isNull())
        return s;

    const QImage rgb = img.convertToFormat(QImage::Format_RGB32);
    QSet<QRgb> colors;
    qint64 nonBlack = 0, total = 0, lumaSum = 0;

    // 抽样即可，无需逐像素
    const int step = qMax(1, qMin(rgb.width(), rgb.height()) / 120);
    for (int y = 0; y < rgb.height(); y += step) {
        for (int x = 0; x < rgb.width(); x += step) {
            const QRgb px = rgb.pixel(x, y);
            const int luma = qGray(px);
            ++total;
            lumaSum += luma;
            if (luma > 16)
                ++nonBlack;
            if (colors.size() < 4096)
                colors.insert(px & 0xF0F0F0);   // 量化后统计
        }
    }

    if (total > 0) {
        s.nonBlackRatio = static_cast<double>(nonBlack) / total;
        s.meanLuma = static_cast<double>(lumaSum) / total;
    }
    s.distinctColors = colors.size();
    return s;
}

} // namespace

int main(int argc, char *argv[])
{
    const QString mediaDir = argc > 1 ? QString::fromLocal8Bit(argv[1])
                                      : QStringLiteral(".");
    // 允许外部指定后端以便对比实验
    const QString forcedBackend = argc > 2 ? QString::fromLocal8Bit(argv[2])
                                           : QString();

    // mpvqt 的 MpvAbstractItem 继承自 QQuickFramebufferObject —— 该类**仅支持
    // OpenGL**。Qt 6 在 Windows 上默认 RHI 后端是 D3D11，因此必须显式切到
    // OpenGL，否则 FBO 节点无法创建（表现为黑屏或断言）。
    if (forcedBackend == QLatin1String("d3d11")) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D11);
    } else {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    }

    QGuiApplication app(argc, argv);

    QFile outFile(QStringLiteral("s1-render-report.txt"));
    outFile.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream ts(&outFile);
    g_out = &ts;

    report(QStringLiteral("=== S1-B: libmpv -> Qt Quick render integration ==="));
    report(QStringLiteral("media dir        : %1").arg(mediaDir));
    report(QStringLiteral("requested backend: %1")
               .arg(forcedBackend.isEmpty() ? QStringLiteral("opengl (default for FBO)")
                                            : forcedBackend));

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(
        QStringLiteral("mediaDir"), mediaDir);

    bool qmlFailed = false;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [&qmlFailed] { qmlFailed = true; QCoreApplication::exit(3); },
                     Qt::QueuedConnection);

    engine.loadFromModule("S1Probe", "RenderProbe");
    if (engine.rootObjects().isEmpty()) {
        check(false, QStringLiteral("QML load"), QStringLiteral("no root object"));
        return 3;
    }

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window) {
        check(false, QStringLiteral("root window"), QStringLiteral("not a QQuickWindow"));
        return 3;
    }

    // 分阶段推进：出画 → 截帧 → CPU 采样 → seek → 截帧 → 叠加层 → 截帧
    int phase = 0;
    FrameStats statsEarly, statsAfterSeek, statsOverlay;
    QString actualBackend;
    double cpuSampleStart = 0, posSampleStart = 0, cpuPercentMeasured = 0;
    int dropSampleStart = 0;

    auto *timer = new QTimer(&app);
    timer->setInterval(1200);

    QObject::connect(timer, &QTimer::timeout, &app, [&]() {
        auto *player = window->findChild<ProbePlayer *>();
        if (!player) {
            check(false, QStringLiteral("player item"), QStringLiteral("not found in QML"));
            QCoreApplication::exit(3);
            return;
        }

        switch (phase) {
        case 0: {
            if (window->rendererInterface()) {
                actualBackend = backendName(window->rendererInterface()->graphicsApi());
                report(QStringLiteral("actual backend   : %1").arg(actualBackend));
            }
            player->loadFile(mediaDir + QStringLiteral("/hevc_1080p.mkv"));
            report(QStringLiteral("\n--- loading hevc_1080p.mkv ---"));
            break;
        }
        case 1: {
            // 播放约 1.2s 后截帧
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s1-frame-early.png"));
            statsEarly = analyze(frame);

            check(statsEarly.nonBlackRatio > 0.5,
                  QStringLiteral("video visible"),
                  QStringLiteral("nonBlack=%1% colors=%2 meanLuma=%3 (no black screen)")
                      .arg(statsEarly.nonBlackRatio * 100, 0, 'f', 1)
                      .arg(statsEarly.distinctColors)
                      .arg(statsEarly.meanLuma, 0, 'f', 1));

            check(player->position() > 0.1,
                  QStringLiteral("playback advancing"),
                  QStringLiteral("time-pos=%1s").arg(player->position(), 0, 'f', 2));

            check(!player->hwdec().isEmpty() && player->hwdec() != QLatin1String("no"),
                  QStringLiteral("hwdec in render path"),
                  QStringLiteral("hwdec-current=%1")
                      .arg(player->hwdec().isEmpty() ? QStringLiteral("(none)")
                                                     : player->hwdec()));
            break;
        }
        case 2: {
            // 开启 CPU 采样窗口：正常速度播放，统计真实渲染路径下的占用
            cpuSampleStart = processCpuSeconds();
            posSampleStart = player->position();
            dropSampleStart = player->getProperty(
                QStringLiteral("frame-drop-count")).toInt();
            report(QStringLiteral("\n--- sampling CPU over playback ---"));
            break;
        }
        case 3: {
            const double cpuUsed = processCpuSeconds() - cpuSampleStart;
            const double played = player->position() - posSampleStart;
            const int drops = player->getProperty(
                QStringLiteral("frame-drop-count")).toInt() - dropSampleStart;
            const double fps = player->getProperty(
                QStringLiteral("estimated-vf-fps")).toDouble();

            // 单核百分比：采样窗口为 1.2s 墙钟
            const double cpuPct = cpuUsed / 1.2 * 100.0;
            cpuPercentMeasured = cpuPct;

            check(played > 0.5,
                  QStringLiteral("realtime playback"),
                  QStringLiteral("advanced %1s in 1.2s wall, vf-fps=%2, drops=%3")
                      .arg(played, 0, 'f', 2).arg(fps, 0, 'f', 1).arg(drops));

            // 1080p HEVC 硬解应远低于单核满载；此处给出实测值供评估
            check(cpuPct < 100.0,
                  QStringLiteral("CPU usage"),
                  QStringLiteral("%1% of one core (cpu=%2s / wall=1.2s)")
                      .arg(cpuPct, 0, 'f', 1).arg(cpuUsed, 0, 'f', 3));

            // 先暂停再 seek：否则下一阶段读取 position 时已自然播放推进 1.2s，
            // 会把「正常播放」误判成「seek 不准」。
            player->setProperty(QStringLiteral("pause"), true);
            player->command({QStringLiteral("seek"), QStringLiteral("20"),
                             QStringLiteral("absolute"), QStringLiteral("exact")});
            report(QStringLiteral("\n--- seek to 20s (paused for exact check) ---"));
            break;
        }
        case 4: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s1-frame-after-seek.png"));
            statsAfterSeek = analyze(frame);

            const double pos = player->position();
            check(std::fabs(pos - 20.0) < 0.2,
                  QStringLiteral("seek landed"),
                  QStringLiteral("time-pos=%1s (target 20s, err %2s)")
                      .arg(pos, 0, 'f', 3).arg(std::fabs(pos - 20.0), 0, 'f', 3));

            check(statsAfterSeek.nonBlackRatio > 0.5,
                  QStringLiteral("frame after seek"),
                  QStringLiteral("nonBlack=%1% colors=%2")
                      .arg(statsAfterSeek.nonBlackRatio * 100, 0, 'f', 1)
                      .arg(statsAfterSeek.distinctColors));
            break;
        }
        case 5: {
            // 显示 QML 叠加层，验证它不被视频遮挡（S2 前置）
            if (auto *overlay = window->findChild<QQuickItem *>(QStringLiteral("overlay")))
                overlay->setProperty("visible", true);
            report(QStringLiteral("\n--- overlay on top of video ---"));
            break;
        }
        case 6: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s1-frame-overlay.png"));
            statsOverlay = analyze(frame);

            // 叠加层是半透明黑底 + 亮色文字块，覆盖区域会显著拉低平均亮度
            const bool overlayVisible =
                std::fabs(statsOverlay.meanLuma - statsAfterSeek.meanLuma) > 3.0;
            check(overlayVisible,
                  QStringLiteral("QML overlay on top"),
                  QStringLiteral("meanLuma %1 -> %2 (overlay changes composite)")
                      .arg(statsAfterSeek.meanLuma, 0, 'f', 1)
                      .arg(statsOverlay.meanLuma, 0, 'f', 1));
            break;
        }
        default:
            report(QStringLiteral("\nbackend used     : %1").arg(actualBackend));
            report(QStringLiteral("CPU (1 core %%)   : %1")
                       .arg(cpuPercentMeasured, 0, 'f', 1));
            report(QStringLiteral("\n%1")
                       .arg(g_allOk ? QStringLiteral("RESULT: S1-B PASSED")
                                    : QStringLiteral("RESULT: S1-B HAS FAILURES")));
            QCoreApplication::exit(g_allOk ? 0 : 1);
            return;
        }
        ++phase;
    });

    timer->start();

    // 兜底超时，避免 CI 卡死
    QTimer::singleShot(45000, &app, [] {
        report(QStringLiteral("TIMEOUT"));
        QCoreApplication::exit(4);
    });

    const int rc = app.exec();
    outFile.close();
    return rc;
}

