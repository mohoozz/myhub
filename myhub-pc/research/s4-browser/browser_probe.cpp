// S4：QtWebEngine 浏览器能力验证
//
// 需求 §2.6 / §4.2 要求内置浏览器具备：
//   多标签保活（切标签不销毁、历史栈不丢）、off-the-record 无痕 profile、
//   下载接管、UA 覆盖、favicon、loadProgress。
//
// 本探针逐项验证，全部页面由本地 TestServer 提供（不依赖外网），
// 判定尽量落到可量化证据上：
//   「保活」  = 隐藏期间页面内 JS 计数器仍在增长（允许 Chromium 后台节流）
//               + 各标签 loadStarted 次数恒为 1（未销毁未重载）
//               + 隐藏期间历史栈仍可后退
//   「无痕」  = OTR profile 的 offTheRecord 为真 + 读不到普通 profile 写的 cookie
//   「下载」  = downloadRequested 被接管后落盘文件字节级校验（SHA-256）
//   「UA」    = 服务端 HTTP 头 + 页面内 navigator.userAgent 双向一致
//   「favicon」= WebEngineView.icon 指向本地 fav.png
//
// 输出：s4-browser-report.txt + 截帧

#include "TestServer.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSet>
#include <QTextStream>
#include <QTimer>
#include <QtWebEngineQuick>

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
                    label.leftJustified(28), detail));
}

struct RegionStats {
    double nonBlackRatio = 0;
    int colors = 0;
    int avgR = 0, avgG = 0, avgB = 0;
};

RegionStats analyzeRegion(const QImage &img, const QRect &r)
{
    RegionStats s;
    if (img.isNull() || r.isEmpty()) return s;

    const QImage rgb = img.copy(r).convertToFormat(QImage::Format_RGB32);
    QSet<QRgb> colors;
    qint64 nonBlack = 0, total = 0, sumR = 0, sumG = 0, sumB = 0;
    const int step = qMax(1, qMin(rgb.width(), rgb.height()) / 100);
    for (int y = 0; y < rgb.height(); y += step) {
        for (int x = 0; x < rgb.width(); x += step) {
            const QRgb px = rgb.pixel(x, y);
            ++total;
            if (qGray(px) > 16) ++nonBlack;
            sumR += qRed(px); sumG += qGreen(px); sumB += qBlue(px);
            if (colors.size() < 4096) colors.insert(px & 0xF0F0F0);
        }
    }
    if (total > 0) {
        s.nonBlackRatio = static_cast<double>(nonBlack) / total;
        s.avgR = static_cast<int>(sumR / total);
        s.avgG = static_cast<int>(sumG / total);
        s.avgB = static_cast<int>(sumB / total);
    }
    s.colors = colors.size();
    return s;
}

QString lifecycleName(int v)
{
    switch (v) {
    case 0: return QStringLiteral("Active");
    case 1: return QStringLiteral("Frozen");
    case 2: return QStringLiteral("Discarded");
    default: return QStringLiteral("(unknown=%1)").arg(v);
    }
}

QString fileSha256(const QString &path, qint64 *size = nullptr)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return QString();
    if (size) *size = f.size();
    QCryptographicHash h(QCryptographicHash::Sha256);
    h.addData(&f);
    return QString::fromLatin1(h.result().toHex());
}

// 无痕判定的落盘侧证据：这些是 Chromium profile 目录里代表性的隐私文件
QStringList privacyFilesIn(const QString &dir)
{
    QStringList hits;
    const QDir d(dir);
    if (!d.exists()) return hits;
    for (const QString &name : {QStringLiteral("History"), QStringLiteral("Cookies"),
                                QStringLiteral("Visited Links"),
                                QStringLiteral("Favicons"),
                                QStringLiteral("Login Data")}) {
        if (QFile::exists(d.filePath(name))) hits << name;
    }
    return hits;
}

} // namespace

int main(int argc, char *argv[])
{
    // WebEngine 必须在 QGuiApplication 之前初始化
    QtWebEngineQuick::initialize();

    // 与生产一致：mpvqt(FBO) 要求 OpenGL 后端，故浏览器也在 OpenGL 下验证（§4.3.1）
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    QGuiApplication app(argc, argv);

    QFile outFile(QStringLiteral("s4-browser-report.txt"));
    outFile.open(QIODevice::WriteOnly | QIODevice::Text);
    QTextStream ts(&outFile);
    g_out = &ts;

    report(QStringLiteral("=== S4: QtWebEngine browser capabilities ==="));

    // ---- 本地测试服务 ----
    TestServer server;
    if (!server.listen(QHostAddress::LocalHost, 0)) {
        report(QStringLiteral("FATAL: cannot listen on loopback"));
        return 2;
    }
    const QString baseUrl =
        QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
    report(QStringLiteral("test server      : %1").arg(baseUrl));

    // ---- 下载目录 ----
    const QString dlDir = QDir::tempPath() + QStringLiteral("/myhub-s4-download");
    QDir(dlDir).removeRecursively();
    QDir().mkpath(dlDir);
    report(QStringLiteral("download dir     : %1").arg(dlDir));

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("probeBaseUrl"), baseUrl);
    engine.rootContext()->setContextProperty(QStringLiteral("probeDownloadDir"), dlDir);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(3); }, Qt::QueuedConnection);
    engine.loadFromModule("S4Browser", "BrowserProbe");

    if (engine.rootObjects().isEmpty()) {
        check(false, QStringLiteral("QML load"), QStringLiteral("no root object"));
        return 3;
    }
    auto *root = engine.rootObjects().first();
    auto *window = qobject_cast<QQuickWindow *>(root);
    if (!window) return 3;

    const QByteArray expectedSha =
        QCryptographicHash::hash(TestServer::makeDownloadBody(),
                                 QCryptographicHash::Sha256).toHex();

    int phase = 0;
    int waitTicks = 0;
    int ticksBeforeHide = -1;
    int ticksWhileHidden = -1;
    int loadsBeforeHide = 0;

    auto invoke = [root](const char *fn) {
        QMetaObject::invokeMethod(root, fn, Qt::DirectConnection);
    };
    auto propInt = [root](const char *name) { return root->property(name).toInt(); };
    auto propStr = [root](const char *name) { return root->property(name).toString(); };

    auto *timer = new QTimer(&app);
    timer->setInterval(400);

    QObject::connect(timer, &QTimer::timeout, &app, [&]() {
        ++waitTicks;

        switch (phase) {
        case 0: {
            if (window->rendererInterface()) {
                report(QStringLiteral("render backend   : %1")
                           .arg(window->rendererInterface()->graphicsApi()
                                == QSGRendererInterface::OpenGL
                                    ? QStringLiteral("OpenGL (matches production)")
                                    : QStringLiteral("other")));
            }
            report(QStringLiteral("\n--- phase 1: load 3 tabs + incognito view ---"));
            break;
        }

        // ---- 等三个标签全部加载完成 ----
        case 1: {
            const bool loaded = propInt("tab1Loads") >= 1
                                && propInt("tab2Loads") >= 1
                                && propInt("tab3Loads") >= 1;
            const bool idle = !root->property("tab1Loading").toBool()
                              && !root->property("tab2Loading").toBool()
                              && !root->property("tab3Loading").toBool();
            if (!(loaded && idle) && waitTicks < 40)
                return;      // 留在本阶段继续等

            if (!(loaded && idle)) {
                check(false, QStringLiteral("tabs loaded"),
                      QStringLiteral("timeout: loads=%1/%2/%3 idle=%4")
                          .arg(propInt("tab1Loads")).arg(propInt("tab2Loads"))
                          .arg(propInt("tab3Loads")).arg(idle));
                break;
            }

            report(QStringLiteral("   3 tabs loaded (waited %1 ms)")
                       .arg(waitTicks * 400));

            check(propInt("tab1Progress") == 100 && propInt("tab2Progress") == 100
                      && propInt("tab3Progress") == 100,
                  QStringLiteral("loadProgress reaches 100"),
                  QStringLiteral("tab1=%1 tab2=%2 tab3=%3")
                      .arg(propInt("tab1Progress"))
                      .arg(propInt("tab2Progress"))
                      .arg(propInt("tab3Progress")));

            // favicon
            const QString i1 = propStr("tab1Icon");
            const QString i2 = propStr("tab2Icon");
            const QString i3 = propStr("tab3Icon");
            check(i1.endsWith(QLatin1String("/fav.png"))
                      && i2.endsWith(QLatin1String("/fav.png"))
                      && i3.endsWith(QLatin1String("/fav.png")),
                  QStringLiteral("favicon from page"),
                  QStringLiteral("tab1=%1 serverReqs=%2")
                      .arg(i1.isEmpty() ? QStringLiteral("(none)") : i1)
                      .arg(server.requestCount(QStringLiteral("/fav.png"))));

            // 渲染进程 pid：仅作信息记录，不是 §2.6 的要求。
            // 实测该 QML 属性在当前 Qt 6.8 下取不到值（恒为 0），
            // 故不参与判定，避免用无关指标制造假失败。
            report(QStringLiteral("   renderProcessPid (informational) : %1/%2/%3")
                       .arg(propInt("tab1Pid")).arg(propInt("tab2Pid"))
                       .arg(propInt("tab3Pid")));

            // 首屏截帧（tab1 可见）
            {
                const QImage frame = window->grabWindow();
                frame.save(QStringLiteral("s4-frame-tab1.png"));
                const qreal dpr = frame.width() / qreal(window->width());
                const RegionStats st = analyzeRegion(
                    frame, QRect(0, 0, int(1000 * dpr), int(700 * dpr)));
                check(st.nonBlackRatio > 0.5,
                      QStringLiteral("tab renders"),
                      QStringLiteral("nonBlack=%1% colors=%2 avgRGB=(%3,%4,%5)")
                          .arg(st.nonBlackRatio * 100, 0, 'f', 1).arg(st.colors)
                          .arg(st.avgR).arg(st.avgG).arg(st.avgB));
                check(st.avgB > st.avgR && st.avgB > st.avgG,
                      QStringLiteral("tab1 shows blue page"),
                      QStringLiteral("avgRGB=(%1,%2,%3) expected dominant blue")
                          .arg(st.avgR).arg(st.avgG).arg(st.avgB));
            }

            invoke("refreshEngineState");
            invoke("sampleTicks");
            break;
        }

        // ---- 取基线，然后隐藏 tab1 ----
        case 2: {
            ticksBeforeHide = propInt("tab1Ticks");
            loadsBeforeHide = propInt("tab1Loads");
            report(QStringLiteral("\n--- phase 2: keep-alive (hide tab1, show tab2) ---"));
            report(QStringLiteral("   tab1 ticks before hide = %1, loads = %2")
                       .arg(ticksBeforeHide).arg(loadsBeforeHide));

            root->setProperty("activeTab", 1);   // tab1 变为不可见
            waitTicks = 0;
            break;
        }

        // ---- 隐藏期间等待约 2.4s ----
        case 3: {
            if (waitTicks < 6)
                return;
            invoke("refreshEngineState");
            invoke("sampleTicks");
            break;
        }

        case 4: {
            ticksWhileHidden = propInt("tab1Ticks");
            const int delta = ticksWhileHidden - ticksBeforeHide;

            // 页面内 setInterval 每 100ms 自增一次。后台标签会被 Chromium
            // 节流到约 2Hz（实测 2.4s 只涨 5 次），这是浏览器正常行为，
            // 不能拿「前台 10Hz」当阈值。真正的「保活」判据是：
            //   计数器仍在推进（delta > 0）+ 页面未被重载（loadStarted 不变）。
            // 若标签被 Discarded/销毁，delta 会是 0 甚至读不到 window.__ticks。
            check(delta > 0,
                  QStringLiteral("hidden tab keeps running"),
                  QStringLiteral("tab1 ticks %1 -> %2 (delta=%3 over ~2.4s hidden, "
                                 "~2Hz throttled); lifecycle=%4 recommended=%5")
                      .arg(ticksBeforeHide).arg(ticksWhileHidden).arg(delta)
                      .arg(lifecycleName(propInt("tab1Lifecycle")),
                           lifecycleName(propInt("tab1Recommended"))));

            check(propInt("tab1Loads") == loadsBeforeHide,
                  QStringLiteral("hidden tab not reloaded"),
                  QStringLiteral("tab1 loadStarted count stayed %1")
                      .arg(propInt("tab1Loads")));

            // 隐藏期间 tab2 是可见的，其计数器应正常增长
            check(propInt("tab2Ticks") > 0,
                  QStringLiteral("visible tab2 runs"),
                  QStringLiteral("tab2 ticks=%1").arg(propInt("tab2Ticks")));

            // 截帧确认当前显示的是 tab2（绿色）而非 tab1（蓝色）
            {
                const QImage frame = window->grabWindow();
                frame.save(QStringLiteral("s4-frame-tab2.png"));
                const qreal dpr = frame.width() / qreal(window->width());
                const RegionStats st = analyzeRegion(
                    frame, QRect(0, 0, int(1000 * dpr), int(700 * dpr)));
                check(st.avgG > st.avgR && st.avgG > st.avgB,
                      QStringLiteral("switched to tab2"),
                      QStringLiteral("avgRGB=(%1,%2,%3) expected dominant green")
                          .arg(st.avgR).arg(st.avgG).arg(st.avgB));
            }

            report(QStringLiteral("\n--- phase 3: switch back to tab1 ---"));
            root->setProperty("activeTab", 0);
            invoke("sampleTicks");
            break;
        }

        case 5: {
            // 关键：case 4 末尾那次采样是在「刚切回前台」的瞬间发出的，
            // 直接读属性拿到的还是旧值（delta 恒为 0 的假失败）。
            // 这里持续采样，并给前台解除节流留 ~1.6s 观察窗口。
            invoke("sampleTicks");
            if (waitTicks < 4)
                return;

            const int after = propInt("tab1Ticks");
            check(after > ticksWhileHidden,
                  QStringLiteral("tab1 alive after return"),
                  QStringLiteral("ticks %1 -> %2 (no reset => page was kept alive)")
                      .arg(ticksWhileHidden).arg(after));

            check(propInt("tab1Loads") == loadsBeforeHide,
                  QStringLiteral("no reload on switch back"),
                  QStringLiteral("tab1 loadStarted count still %1")
                      .arg(propInt("tab1Loads")));

            report(QStringLiteral("\n--- phase 4: UA override (dynamic change) ---"));
            // 动态改 UA：模拟用户在设置里改 UA 后立即生效
            root->setProperty("pendingUa", QStringLiteral("MyHubS4Probe/2.0 (dynamic)"));
            invoke("applyPendingUa");
            // 让 tab3 可见再加载，避免隐藏页被节流导致 title 更新延迟
            root->setProperty("activeTab", 2);
            invoke("loadUaInTab3");
            waitTicks = 0;
            break;
        }

        // ---- 等 /ua 页加载 ----
        case 6: {
            const QString title = propStr("uaTitle");
            if (!title.startsWith(QLatin1String("UA:")) && waitTicks < 30)
                return;
            invoke("readUaFromJs");
            waitTicks = 0;
            break;
        }

        case 7: {
            const QString uaJs = propStr("uaFromJs");
            const QString uaSrv = server.userAgentFor(QStringLiteral("/ua"));

            check(uaJs.contains(QLatin1String("MyHubS4Probe/2.0")),
                  QStringLiteral("UA override (in page)"),
                  QStringLiteral("navigator.userAgent=%1")
                      .arg(uaJs.isEmpty() ? QStringLiteral("(empty)") : uaJs));

            check(uaSrv.contains(QLatin1String("MyHubS4Probe/2.0")),
                  QStringLiteral("UA override (on wire)"),
                  QStringLiteral("server saw User-Agent=%1")
                      .arg(uaSrv.isEmpty() ? QStringLiteral("(none)") : uaSrv));

            // tab3 已从 /tab3 导航到 /ua（两次加载），历史栈里应有 2 条。
            // 把它切到后台，稍后在隐藏状态下读历史，验证「切标签历史栈不丢」。
            root->setProperty("activeTab", 0);   // tab3 进后台，tab1 可见

            report(QStringLiteral("\n--- phase 5: incognito isolation ---"));
            invoke("setNormalCookie");
            break;
        }

        case 8: {
            report(QStringLiteral("   normal profile cookie = '%1'")
                       .arg(propStr("normalCookie")));
            // tab3 此刻处于隐藏状态，读它的历史栈
            invoke("readHistory");
            invoke("readOtrCookie");
            break;
        }

        case 9: {
            invoke("refreshEngineState");

            check(propStr("normalCookie").contains(QLatin1String("mh_s4=1")),
                  QStringLiteral("cookie set in normal profile"),
                  QStringLiteral("document.cookie='%1'").arg(propStr("normalCookie")));

            check(propStr("otrCookie").isEmpty(),
                  QStringLiteral("incognito isolated"),
                  QStringLiteral("OTR document.cookie='%1' (same origin, must be empty)")
                      .arg(propStr("otrCookie")));

            check(root->property("otrProfileIsOtr").toBool()
                      && !root->property("normalProfileIsOtr").toBool(),
                  QStringLiteral("offTheRecord flags"),
                  QStringLiteral("incognitoProfile.offTheRecord=%1, normal=%2")
                      .arg(root->property("otrProfileIsOtr").toBool())
                      .arg(root->property("normalProfileIsOtr").toBool()));

            // 切标签后历史栈不丢：tab3 已从 /tab3 导航到 /ua 再被切到后台
            check(root->property("tab3CanGoBack").toBool()
                      && propInt("tab3HistoryLen") >= 2,
                  QStringLiteral("hidden tab keeps history"),
                  QStringLiteral("tab3 canGoBack=%1 history.length=%2 while hidden "
                                 "(/tab3 -> /ua)")
                      .arg(root->property("tab3CanGoBack").toBool() ? QStringLiteral("true")
                                                                    : QStringLiteral("false"))
                      .arg(propInt("tab3HistoryLen")));

            report(QStringLiteral("\n--- phase 6: download takeover ---"));
            root->setProperty("activeTab", 2);   // tab3 回到前台再触发下载
            invoke("startDownload");
            waitTicks = 0;
            break;
        }

        // ---- 等下载完成（state: 0=requested 1=inprogress 2=completed）----
        case 10: {
            const int st = propInt("downloadState");
            if (st != 2 && st >= 0 && st != 3 && st != 4 && waitTicks < 40)
                return;
            waitTicks = 0;
            break;
        }

        case 11: {
            const int st = propInt("downloadState");
            const int reqs = propInt("downloadRequests");

            check(reqs == 1,
                  QStringLiteral("downloadRequested fired"),
                  QStringLiteral("%1 request(s) intercepted").arg(reqs));

            check(st == 2,
                  QStringLiteral("download accepted+completed"),
                  QStringLiteral("state=%1 interrupt='%2' bytes=%3/%4")
                      .arg(st).arg(propStr("downloadInterrupt"))
                      .arg(propInt("downloadReceived")).arg(propInt("downloadTotal")));

            QString path = propStr("downloadSavedPath");
            if (path.isEmpty())
                path = dlDir + QStringLiteral("/s4-download.bin");

            qint64 size = 0;
            const QString sha = fileSha256(path, &size);
            const qint64 expectSize = TestServer::makeDownloadBody().size();

            check(size == expectSize,
                  QStringLiteral("downloaded file size"),
                  QStringLiteral("%1 bytes (expected %2)").arg(size).arg(expectSize));

            check(sha == QString::fromLatin1(expectedSha),
                  QStringLiteral("downloaded bytes intact"),
                  QStringLiteral("sha256=%1...%2")
                      .arg(sha.left(16))
                      .arg(sha == QString::fromLatin1(expectedSha)
                               ? QStringLiteral(" matches")
                               : QStringLiteral(" MISMATCH expected ")
                                     + QString::fromLatin1(expectedSha.left(16))));

            report(QStringLiteral("   saved to: %1").arg(path));

            // ---- 无痕的落盘侧证据 ----
            // 说明：OTR profile 的 persistentStoragePath 属性并不为空（Qt 返回默认
            // 路径下的 /OffTheRecord 子目录），所以不能拿「路径为空」当判据。
            // 真正该验的是磁盘上有没有隐私文件；普通 profile 必须有，无痕必须没有。
            {
                const QString otrPath = propStr("otrPersistPath");
                const QString normalPath = propStr("normalPersistPath");
                const QStringList otrHits = privacyFilesIn(otrPath);
                const QStringList normalHits = privacyFilesIn(normalPath);

                check(otrHits.isEmpty() && normalHits.contains(QStringLiteral("History")),
                      QStringLiteral("incognito leaves no disk trace"),
                      QStringLiteral("otr dir exists=%1 privacy files=[%2] | "
                                     "normal privacy files=[%3]")
                          .arg(QDir(otrPath).exists() ? QStringLiteral("yes")
                                                      : QStringLiteral("no"),
                               otrHits.join(QLatin1String(",")),
                               normalHits.join(QLatin1String(","))));
                report(QStringLiteral("   otr storage    : %1").arg(otrPath));
                report(QStringLiteral("   normal storage : %1").arg(normalPath));
            }

            report(QStringLiteral("\n--- summary ---"));
            report(QStringLiteral("tab loadStarted counts : %1 / %2 / %3 "
                                  "(tab1/tab2 stay 1 => kept alive; tab3 grows by "
                                  "its 2 intentional navigations)")
                       .arg(propInt("tab1Loads")).arg(propInt("tab2Loads"))
                       .arg(propInt("tab3Loads")));
            report(QStringLiteral("tab3 history          : canGoBack=%1 length=%2")
                       .arg(root->property("tab3CanGoBack").toBool() ? QStringLiteral("true")
                                                                     : QStringLiteral("false"))
                       .arg(propInt("tab3HistoryLen")));
            report(QStringLiteral("http requests served  : /tab1=%1 /tab2=%2 /tab3=%3 "
                                  "/fav.png=%4 /ua=%5 /download=%6")
                       .arg(server.requestCount(QStringLiteral("/tab1")))
                       .arg(server.requestCount(QStringLiteral("/tab2")))
                       .arg(server.requestCount(QStringLiteral("/tab3")))
                       .arg(server.requestCount(QStringLiteral("/fav.png")))
                       .arg(server.requestCount(QStringLiteral("/ua")))
                       .arg(server.requestCount(QStringLiteral("/download"))));
            break;
        }

        default:
            report(QStringLiteral("\n%1")
                       .arg(g_allOk ? QStringLiteral("RESULT: S4 PASSED")
                                    : QStringLiteral("RESULT: S4 HAS FAILURES")));
            QCoreApplication::exit(g_allOk ? 0 : 1);
            return;
        }

        ++phase;
        waitTicks = 0;
    });
    timer->start();

    QTimer::singleShot(90000, &app, [] {
        report(QStringLiteral("TIMEOUT"));
        QCoreApplication::exit(4);
    });

    const int rc = app.exec();
    outFile.close();
    return rc;
}
