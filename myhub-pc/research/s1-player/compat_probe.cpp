// S1-C：OpenGL 后端下 libmpv 视频与 QtWebEngine 的共存验证
//
// 背景（本预研的关键发现）：
//   mpvqt 的 MpvAbstractItem 继承自 QQuickFramebufferObject，该类仅支持 OpenGL。
//   实测 D3D11 后端下视频 100% 黑屏。因此若采用 mpvqt，**整个应用被迫使用
//   OpenGL 后端**，而 MyHub 同时需要 QtWebEngine（内置浏览器，§2.6）。
//
// 本探针回答：OpenGL 后端下，视频与 WebEngine 能否在同一进程/同一窗口共存且都出画。
//   —— 若否，则 mpvqt 方案不可用，必须自写 QQuickRhiItem（RHI 原生，支持 D3D11）。
//
// 输出：s1-compat-report.txt + 截帧

#include "ProbePlayer.h"

#include <QGuiApplication>
#include <QFile>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QTextStream>
#include <QTimer>
#include <QtWebEngineQuick>

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

// 统计指定区域的非黑像素占比与颜色数
struct RegionStats { double nonBlackRatio = 0; int colors = 0; };

RegionStats analyzeRegion(const QImage &img, const QRect &r)
{
    RegionStats s;
    if (img.isNull() || r.isEmpty()) return s;

    const QImage rgb = img.copy(r).convertToFormat(QImage::Format_RGB32);
    QSet<QRgb> colors;
    qint64 nonBlack = 0, total = 0;
    const int step = qMax(1, qMin(rgb.width(), rgb.height()) / 80);
    for (int y = 0; y < rgb.height(); y += step) {
        for (int x = 0; x < rgb.width(); x += step) {
            const QRgb px = rgb.pixel(x, y);
            ++total;
            if (qGray(px) > 16) ++nonBlack;
            if (colors.size() < 2048) colors.insert(px & 0xF0F0F0);
        }
    }
    if (total > 0) s.nonBlackRatio = static_cast<double>(nonBlack) / total;
    s.colors = colors.size();
    return s;
}

} // namespace

int main(int argc, char *argv[])
{
    const QString mediaDir = argc > 1 ? QString::fromLocal8Bit(argv[1])
                                      : QStringLiteral(".");

    // WebEngine 必须在 QGuiApplication 之前初始化
    QtWebEngineQuick::initialize();

    // mpvqt(FBO) 的硬性要求
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);

    QFile outFile(QStringLiteral("s1-compat-report.txt"));
    outFile.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream ts(&outFile);
    g_out = &ts;

    report(QStringLiteral("=== S1-C: libmpv + QtWebEngine coexistence (OpenGL backend) ==="));

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(3); }, Qt::QueuedConnection);
    engine.loadFromModule("S1Compat", "CompatProbe");

    if (engine.rootObjects().isEmpty()) {
        check(false, QStringLiteral("QML load"), QStringLiteral("no root object"));
        return 3;
    }
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window) return 3;

    int phase = 0;
    auto *timer = new QTimer(&app);
    timer->setInterval(1500);

    QObject::connect(timer, &QTimer::timeout, &app, [&]() {
        auto *player = window->findChild<ProbePlayer *>();
        switch (phase) {
        case 0:
            if (window->rendererInterface()) {
                report(QStringLiteral("backend          : %1")
                           .arg(window->rendererInterface()->graphicsApi()
                                == QSGRendererInterface::OpenGL
                                    ? QStringLiteral("OpenGL") : QStringLiteral("other")));
            }
            if (player)
                player->loadFile(mediaDir + QStringLiteral("/hevc_1080p.mkv"));
            report(QStringLiteral("\n--- loading video + web page ---"));
            break;

        case 1: break;   // 给 WebEngine 与视频各自渲染的时间

        case 2: {
            const QImage frame = window->grabWindow();
            frame.save(QStringLiteral("s1-compat-frame.png"));

            // 左半为视频，右半为网页（见 CompatProbe.qml）
            const int w = frame.width(), h = frame.height();
            const RegionStats video = analyzeRegion(frame, QRect(0, 0, w / 2, h));
            const RegionStats web   = analyzeRegion(frame, QRect(w / 2, 0, w / 2, h));

            check(video.nonBlackRatio > 0.5,
                  QStringLiteral("video renders"),
                  QStringLiteral("left half nonBlack=%1% colors=%2")
                      .arg(video.nonBlackRatio * 100, 0, 'f', 1).arg(video.colors));

            check(web.nonBlackRatio > 0.5 && web.colors > 2,
                  QStringLiteral("web page renders"),
                  QStringLiteral("right half nonBlack=%1% colors=%2")
                      .arg(web.nonBlackRatio * 100, 0, 'f', 1).arg(web.colors));

            if (player) {
                check(!player->hwdec().isEmpty()
                          && player->hwdec() != QLatin1String("no"),
                      QStringLiteral("hwdec with WebEngine"),
                      QStringLiteral("hwdec-current=%1 (hw decode survives coexistence)")
                          .arg(player->hwdec().isEmpty() ? QStringLiteral("(none)")
                                                         : player->hwdec()));
                check(player->position() > 0.5,
                      QStringLiteral("playback advancing"),
                      QStringLiteral("time-pos=%1s").arg(player->position(), 0, 'f', 2));
            }
            break;
        }
        default:
            report(QStringLiteral("\n%1")
                       .arg(g_allOk ? QStringLiteral("RESULT: S1-C PASSED")
                                    : QStringLiteral("RESULT: S1-C HAS FAILURES")));
            QCoreApplication::exit(g_allOk ? 0 : 1);
            return;
        }
        ++phase;
    });
    timer->start();

    QTimer::singleShot(40000, &app, [] {
        report(QStringLiteral("TIMEOUT"));
        QCoreApplication::exit(4);
    });

    const int rc = app.exec();
    outFile.close();
    return rc;
}
