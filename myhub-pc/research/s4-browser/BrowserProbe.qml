import QtQuick
import QtQuick.Window
import QtWebEngine

/*
  S4 浏览器能力探针

  布局：
    左侧 1000x700 —— 三个标签页叠放在同一容器内，仅激活者可见
                      （「隐藏」是靠 visible 实现的，等价于真实切标签）
    右侧  320x700 —— 无痕（off-the-record）profile 的独立视图

  所有页面由本地 TestServer 提供（probeBaseUrl 由 C++ 注入），不依赖外网。
*/
Window {
    id: root
    width: 1320
    height: 700
    visible: true
    color: "#000000"
    title: "S4 Browser Probe"

    property string baseUrl: probeBaseUrl
    property string dlDir: probeDownloadDir

    // ==== 由 C++ 写入 ====
    property int activeTab: 0

    // ==== 由本文件采样，供 C++ 读取 ====
    property int tab1Ticks: -1
    property int tab2Ticks: -1
    property int tab3Ticks: -1
    property int otrTicks: -1

    property int tab1Loads: 0
    property int tab2Loads: 0
    property int tab3Loads: 0
    property int otrLoads: 0

    property int tab1Progress: 0
    property int tab2Progress: 0
    property int tab3Progress: 0

    property bool tab1Loading: true
    property bool tab2Loading: true
    property bool tab3Loading: true

    property string tab1Icon: ""
    property string tab2Icon: ""
    property string tab3Icon: ""

    property int tab1Pid: 0
    property int tab2Pid: 0
    property int tab3Pid: 0

    property int tab1Lifecycle: -1
    property int tab1Recommended: -1

    property string normalCookie: ""
    property string otrCookie: ""
    property string otrProfileIsOtr: ""
    property string normalProfileIsOtr: ""
    // 落盘位置：无痕 profile 应为空串（== 不写磁盘，也就不会留下历史/缓存）
    property string otrPersistPath: ""
    property string normalPersistPath: ""

    property string uaTitle: ""
    property string uaFromJs: ""
    property int uaProgress: 0

    // 历史栈（切标签后应保持）
    property bool tab3CanGoBack: false
    property int tab3HistoryLen: -1
    // C++ 通过属性传值再调用无参函数，避免依赖 QML 函数的 QVariantList 签名
    property string pendingUa: ""

    // ==== 下载 ====
    property int downloadRequests: 0
    property int downloadState: -1
    property string downloadInterrupt: ""
    property string downloadSavedPath: ""
    property int downloadReceived: 0
    property int downloadTotal: -1

    // ---- profile ----
    // 普通 profile：可改 UA、可下载
    WebEngineProfile {
        id: normalProfile
        storageName: "MyHubS4Probe"
        // 坑：QML 里声明的 WebEngineProfile **默认就是 off-the-record**，
        // 只设 storageName 不会翻转该标志。不显式写 false 的话，
        // cookie / HTTP 缓存全都只存在内存里，用户每次重启都会掉登录态。
        offTheRecord: false
        httpUserAgent: "MyHubS4Probe/1.0"
        downloadPath: root.dlDir

        onDownloadRequested: function(download) {
            root.downloadRequests++
            // 接管：不弹系统对话框，直接指定落盘位置后 accept()
            download.downloadDirectory = root.dlDir
            download.downloadFileName = "s4-download.bin"
            root.downloadSavedPath = download.downloadDirectory + "/s4-download.bin"
            root.downloadTotal = download.totalBytes
            root.downloadInterrupt = ""
            download.accept()
            root.downloadState = download.state

            download.stateChanged.connect(function() {
                root.downloadState = download.state
                root.downloadReceived = download.receivedBytes
                root.downloadTotal = download.totalBytes
                root.downloadInterrupt = download.interruptReasonString
            })
        }
    }

    // 无痕 profile：默认构造即 off-the-record，不落盘、不与其他 profile 共享 cookie
    WebEngineProfile {
        id: incognitoProfile
        offTheRecord: true
    }

    // ================= 左侧：三标签 =================
    Item {
        id: tabArea
        width: 1000
        height: parent.height

        WebEngineView {
            id: tab1
            objectName: "tab1"
            anchors.fill: parent
            profile: normalProfile
            visible: root.activeTab === 0
            url: root.baseUrl + "/tab1"

            onLoadingChanged: function(req) {
                if (req.status === WebEngineView.LoadStartedStatus)
                    root.tab1Loads++
                else
                    root.tab1Loading = false
            }
            onLoadProgressChanged: if (loadProgress > root.tab1Progress)
                                       root.tab1Progress = loadProgress
            onIconChanged: root.tab1Icon = icon.toString()
            onLifecycleStateChanged: root.tab1Lifecycle = lifecycleState
            onRecommendedStateChanged: root.tab1Recommended = recommendedState
            onRenderProcessPidChanged: root.tab1Pid = renderProcessPid
            Component.onCompleted: {
                root.tab1Lifecycle = lifecycleState
                root.tab1Recommended = recommendedState
                root.tab1Icon = icon.toString()
            }
        }

        WebEngineView {
            id: tab2
            objectName: "tab2"
            anchors.fill: parent
            profile: normalProfile
            visible: root.activeTab === 1
            url: root.baseUrl + "/tab2"

            onLoadingChanged: function(req) {
                if (req.status === WebEngineView.LoadStartedStatus)
                    root.tab2Loads++
                else
                    root.tab2Loading = false
            }
            onLoadProgressChanged: if (loadProgress > root.tab2Progress)
                                       root.tab2Progress = loadProgress
            onIconChanged: root.tab2Icon = icon.toString()
            onRenderProcessPidChanged: root.tab2Pid = renderProcessPid
        }

        WebEngineView {
            id: tab3
            objectName: "tab3"
            anchors.fill: parent
            profile: normalProfile
            visible: root.activeTab === 2
            url: root.baseUrl + "/tab3"

            onLoadingChanged: function(req) {
                if (req.status === WebEngineView.LoadStartedStatus)
                    root.tab3Loads++
                else
                    root.tab3Loading = false
            }
            onLoadProgressChanged: if (loadProgress > root.tab3Progress)
                                       root.tab3Progress = loadProgress
            onIconChanged: root.tab3Icon = icon.toString()
            onRenderProcessPidChanged: root.tab3Pid = renderProcessPid
            // /ua 页把 navigator.userAgent 写进 title，这里转存给 C++ 读取
            onTitleChanged: root.uaTitle = title
        }
    }

    // ================= 右侧：无痕视图 =================
    Rectangle {
        x: 1000
        width: 320
        height: parent.height
        color: "#202020"

        WebEngineView {
            id: otrView
            objectName: "otr"
            anchors.fill: parent
            profile: incognitoProfile
            url: root.baseUrl + "/tab3"

            onLoadingChanged: function(req) {
                if (req.status === WebEngineView.LoadStartedStatus)
                    root.otrLoads++
            }
        }
    }

    // ================= 供 C++ 调用的采样函数 =================
    // 说明：刻意**不做**周期性轮询。周期性 runJavaScript 会唤醒被冻结的页面，
    // 从而掩盖「隐藏标签是否被冻结」这一待测行为。故只在 C++ 指定的时刻采样。

    function sampleTicks() {
        tab1.runJavaScript("(window.__ticks===undefined)?-1:window.__ticks",
                           function(r) { root.tab1Ticks = r })
        tab2.runJavaScript("(window.__ticks===undefined)?-1:window.__ticks",
                           function(r) { root.tab2Ticks = r })
        tab3.runJavaScript("(window.__ticks===undefined)?-1:window.__ticks",
                           function(r) { root.tab3Ticks = r })
        otrView.runJavaScript("(window.__ticks===undefined)?-1:window.__ticks",
                              function(r) { root.otrTicks = r })
    }

    function refreshEngineState() {
        root.tab1Lifecycle = tab1.lifecycleState
        root.tab1Recommended = tab1.recommendedState
        root.tab1Pid = tab1.renderProcessPid
        root.tab2Pid = tab2.renderProcessPid
        root.tab3Pid = tab3.renderProcessPid
        root.normalProfileIsOtr = normalProfile.offTheRecord
        root.otrProfileIsOtr = incognitoProfile.offTheRecord
        root.normalPersistPath = normalProfile.persistentStoragePath
        root.otrPersistPath = incognitoProfile.persistentStoragePath
    }

    // 在普通 profile 的页面里写 cookie
    function setNormalCookie() {
        tab1.runJavaScript(
            "document.cookie='mh_s4=1; path=/'; document.cookie",
            function(r) { root.normalCookie = r })
    }

    function readNormalCookie() {
        tab1.runJavaScript("document.cookie", function(r) { root.normalCookie = r })
    }

    // 在无痕 profile 的页面里读 cookie（应为空 —— 与普通 profile 隔离）
    function readOtrCookie() {
        otrView.runJavaScript("document.cookie", function(r) { root.otrCookie = r })
    }

    function readUaFromJs() {
        tab1.runJavaScript("navigator.userAgent", function(r) { root.uaFromJs = r })
    }

    // 历史栈：tab3 已被导航过两次（/tab3 -> /ua），切标签回来后应仍可后退
    function readHistory() {
        root.tab3CanGoBack = tab3.canGoBack
        tab3.runJavaScript("history.length", function(r) { root.tab3HistoryLen = r })
    }

    // 无参函数 + 属性传值：QML 函数的元方法签名是 QVariant(QVariantList)，
    // 用 Q_ARG(QVariant) 调用容易匹配不上，属性传值最稳。
    function applyPendingUa() {
        normalProfile.httpUserAgent = root.pendingUa
    }

    function loadUaInTab3() {
        root.uaTitle = ""
        root.uaProgress = 0
        tab3.url = root.baseUrl + "/ua"
    }

    function startDownload() {
        root.downloadState = -1
        tab3.url = root.baseUrl + "/download"
    }
}
