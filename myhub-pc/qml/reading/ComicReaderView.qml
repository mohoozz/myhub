pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  漫画阅读器（§6 / PC-207）。

  分层：页序、解包、缓存全在 C++（`ComicBridge` + `myhub_core/comic`），
  这里只做「把图铺满窗口 + 翻页 + 报进度」。

  三种模式（单页 / 双页 / 条漫）由 `Comic.mode` 决定并持久化：
    - 单页：一次一页，可缩放（`Ctrl+滚轮` / 双击 / 拖拽平移）；
    - 双页：一屏两页，方向 RTL/LTR 可切（日漫默认从右向左），翻页按整屏走两页；
    - 条漫：纵向连续滚动，滚动位置就是页码，图按视口宽度下采样解码。

  多页从哪来：`ComicBook` 只有一个在途解压槽位，所以桥接层里有一支队列
  （`ensurePage`）；`pageUrlAt()` 只查盘、不触发解压，QML 靠 `pageCached`
  信号（这里折成 `cacheRevision`）知道「这一页能画了」。

  交互：点右侧三分之一下一页、左侧三分之一上一页、中间切换上下栏；滚轮翻页
  （条漫里交给列表自己滚）；双页 RTL 时 `←/→` 自动反向；`D` 循环切模式。
  上下栏：顶栏裸显示（只有一层淡渐变）+ 底栏毛玻璃胶囊；进度轨拖动中只改本地值，
  松手才跳页，页码气泡跟着拇指走。
*/
Item {
    id: root

    /// 与 `Comic.mode` 同一套编号
    readonly property int modeSingle: 0
    readonly property int modeDouble: 1
    readonly property int modeStrip: 2

    readonly property bool stripMode: Comic.mode === modeStrip
    readonly property bool doubleMode: Comic.mode === modeDouble

    /// 双页的「这一屏」从哪一页开始：按偶数对齐，避免半屏错位
    readonly property int spreadStart: doubleMode
        ? Math.floor(Math.max(0, Comic.pageIndex) / 2) * 2
        : Math.max(0, Comic.pageIndex)

    /// 上下栏是否显示（点中间切换；翻页时自动露出，方便随时知道进度）
    property bool chromeVisible: true
    /// 滚轮节流：触控板一次滑动会连发几十个 wheel 事件
    property bool wheelLocked: false

    /// 缩放与平移（只在单页模式有效：双页/条漫是「铺满看」的场景）
    property real zoom: 1.0
    property real panX: 0
    property real panY: 0

    readonly property real maxZoom: 4
    readonly property bool zoomed: zoom > 1.001
    /// 底栏胶囊高度；图片铺满整窗，胶囊浮在上面（沉浸式）
    readonly property int capsuleHeight: 56

    /// 缓存里又有一页可用了：让 `pageUrlAt()` 的绑定重算
    property int cacheRevision: 0

    /// 缩略图面板（底栏「目录」）是否展开：展开时独占点击与滚轮，上下栏让位
    property bool shelfOpen: false

    visible: Comic.opened || Comic.loading || Comic.errorText.length > 0
    focus: visible

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus();
            primePages();
        }
    }

    onShelfOpenChanged: {
        if (shelfOpen) {
            chromeVisible = false;
            // 不用 positionViewAtIndex：它的对齐模式会落在半行上（首行被视口顶部切掉一半，
            // 卡片看着像矮了一格）。改成等布局稳定后按行算 contentY，行顶永远对齐
            Qt.callLater(function () {
                shelfGrid.currentIndex = Math.max(0, Comic.pageIndex);
            });
            shelfRecenter.restart();
        } else {
            chromeVisible = true;
            primePages();
            forceActiveFocus();
        }
    }

    readonly property bool hasPage: Comic.pageUrl.length > 0 && pageImage.status === Image.Ready

    function clampPan() {
        const limitX = width * (zoom - 1) / 2;
        const limitY = height * (zoom - 1) / 2;
        panX = Math.max(-limitX, Math.min(limitX, panX));
        panY = Math.max(-limitY, Math.min(limitY, panY));
    }

    function setZoom(value) {
        zoom = Math.max(1, Math.min(maxZoom, value));
        if (!zoomed) {
            panX = 0;
            panY = 0;
        } else {
            clampPan();
        }
    }

    function resetView() {
        zoom = 1;
        panX = 0;
        panY = 0;
    }

    /// 把当前模式要看的那几页排进解压队列
    function primePages() {
        if (!Comic.opened)
            return;

        if (doubleMode) {
            Comic.ensurePage(spreadStart);
            Comic.ensurePage(spreadStart + 1);
        } else if (stripMode) {
            Comic.ensurePage(Math.max(0, Comic.pageIndex - 1));
            Comic.ensurePage(Comic.pageIndex);
            Comic.ensurePage(Comic.pageIndex + 1);
        } else {
            Comic.ensurePage(Comic.pageIndex);
        }
    }

    /// 条漫恢复位置：模型是「页数」，只能按索引定位，图片加载完高度会再微调
    function syncStrip() {
        if (!stripMode || !Comic.opened || Comic.pageIndex < 0)
            return;
        strip.positionViewAtIndex(Comic.pageIndex, ListView.Beginning);
    }

    function goNext() {
        if (stripMode) {
            const target = Math.min(Comic.pageIndex + 1, Comic.pageCount - 1);
            strip.positionViewAtIndex(target, ListView.Beginning);
            Comic.trackPage(target);
            return;
        }
        Comic.goToPage(doubleMode ? spreadStart + 2 : Comic.pageIndex + 1);
        chromeVisible = true;
    }

    function goPrev() {
        if (stripMode) {
            const target = Math.max(Comic.pageIndex - 1, 0);
            strip.positionViewAtIndex(target, ListView.Beginning);
            Comic.trackPage(target);
            return;
        }
        Comic.goToPage(doubleMode ? Math.max(0, spreadStart - 2) : Comic.pageIndex - 1);
        chromeVisible = true;
    }

    function goToPage(index) {
        if (stripMode) {
            const target = Math.max(0, Math.min(Comic.pageCount - 1, index));
            strip.positionViewAtIndex(target, ListView.Beginning);
            Comic.trackPage(target);
            return;
        }
        Comic.goToPage(index);
    }

    /// 缩略图点一下就跳过去并收起面板：用户要的是「回到那一页」，不是「在目录里逗留」
    function jumpFromShelf(index) {
        if (index < 0 || index >= Comic.pageCount)
            return;
        goToPage(index);
        shelfOpen = false;
        forceActiveFocus();
    }

    /// RTL 双页时「左边」才是后一页：方向键跟着阅读方向走，与原型一致
    function flipLeft() {
        if (Comic.rightToLeft && doubleMode)
            goNext();
        else
            goPrev();
    }

    function flipRight() {
        if (Comic.rightToLeft && doubleMode)
            goPrev();
        else
            goNext();
    }

    /// 三分区点击：左右翻页、中间收放上下栏（放大后不翻页，只收放）
    function handleZoneClick(x) {
        const third = width / 3;
        if (x < third)
            flipLeft();
        else if (x > width - third)
            flipRight();
        else
            chromeVisible = !chromeVisible;
        forceActiveFocus();
    }

    Connections {
        target: Comic

        function onPageCached(index) {
            root.cacheRevision++;
        }

        function onModeChanged() {
            root.resetView();
            root.primePages();
            if (root.stripMode)
                Qt.callLater(root.syncStrip);
        }

        function onOpenedChanged() {
            if (Comic.opened) {
                root.primePages();
                if (root.stripMode)
                    Qt.callLater(root.syncStrip);
            }
        }

        function onRightToLeftChanged() {
            root.primePages();
        }

        function onPageChanged() {
            root.clampPan();
            if (root.doubleMode)
                root.primePages();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#0E0F11"
    }

    // ---------------- 单页 ----------------

    // 裁剪视口：放大后画面超出窗口的部分不越界画到别的页面上
    Item {
        id: singleView

        anchors.fill: parent
        clip: true
        visible: !root.doubleMode && !root.stripMode

        // 缩放层：x/y 是父坐标（不受自身 scale 影响），平移就是「屏幕上多少像素」
        Item {
            id: canvas

            anchors.fill: parent
            scale: root.zoom
            x: root.panX
            y: root.panY

            Image {
                id: pageImage

                anchors.fill: parent
                source: singleView.visible ? Comic.pageUrl : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // 每页 URL 都不同（页码 + 指纹进文件名），开着缓存只会白占内存
                cache: false
                smooth: true
                mipmap: true
                visible: root.hasPage

                // 解出来的字节其实不是图片（例如 cbz 里混了 pdf）：让 C++ 重解一次
                onStatusChanged: {
                    if (status === Image.Error && Comic.pageUrl.length > 0)
                        Comic.retryPage();
                }
            }
        }
    }

    // ---------------- 双页 ----------------

    Item {
        id: doubleView

        anchors.fill: parent
        visible: root.doubleMode

        // RTL 用 layoutDirection 翻转顺序：第一张（当前页）在右，符合日漫阅读方向
        Row {
            anchors.fill: parent
            layoutDirection: Comic.rightToLeft ? Qt.RightToLeft : Qt.LeftToRight

            Image {
                id: spreadLead

                width: parent.width / 2
                height: parent.height
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                mipmap: true
                smooth: true
                // 注意：`cacheRevision` 必须参与表达式（不能只写成一条语句），否则
                // qmlcachegen 会判定它没有副作用而把这条依赖优化掉，绑定就再也不重算了
                source: root.cacheRevision >= 0 && doubleView.visible
                        ? Comic.pageUrlAt(root.spreadStart)
                        : ""
            }

            // 配对页：末尾的奇数页只有一张，空着就空着
            Item {
                width: parent.width / 2
                height: parent.height

                Image {
                    id: spreadMate

                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: false
                    mipmap: true
                    smooth: true
                    // 同上：`cacheRevision` 要参与表达式，否则依赖会被优化掉
                    source: root.cacheRevision >= 0 && doubleView.visible
                            ? Comic.pageUrlAt(root.spreadStart + 1)
                            : ""
                }

                Text {
                    anchors.centerIn: parent
                    visible: doubleView.visible && Comic.pageCount > 0
                             && root.spreadStart + 1 >= Comic.pageCount
                    text: qsTr("末页")
                    color: AppTheme.colors.textSecondary
                    font.pixelSize: AppTheme.fontSizeSmall
                }
            }
        }
    }

    // ---------------- 条漫 ----------------

    ListView {
        id: strip

        anchors.fill: parent
        visible: root.stripMode
        model: Comic.pageCount
        spacing: 0
        boundsBehavior: Flickable.StopAtBounds
        // 上下各留一屏余量：滚到哪都有下一张在路上
        cacheBuffer: 1200
        flickableDirection: Flickable.VerticalFlick

        // 滚动即翻页：只更新页码，解压交给各自的 delegate
        onContentYChanged: {
            if (!root.stripMode || !Comic.opened)
                return;
            const index = strip.indexAt(1, contentY + height / 3);
            if (index >= 0)
                Comic.trackPage(index);
        }

        delegate: Item {
            id: stripPage

            required property int index

            width: strip.width
            height: root.cacheRevision >= 0 && image.status === Image.Ready
                    ? image.paintedHeight
                    : Math.round(width * 1.4)

            Image {
                id: image

                width: parent.width
                // 大图下采样：条漫一屏挂着几页，按原尺寸解码会把内存吃满
                sourceSize.width: parent.width
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                smooth: true
                // 同上：`cacheRevision` 要参与表达式，否则依赖会被优化掉
                source: root.cacheRevision >= 0
                        ? Comic.pageUrlAt(stripPage.index)
                        : ""
            }

            Component.onCompleted: Comic.ensurePage(stripPage.index)
        }

        // 条漫里没有「左右三分区」：点一下就是收放上下栏
        TapHandler {
            onTapped: root.chromeVisible = !root.chromeVisible
        }
    }

    Text {
        anchors.centerIn: parent
        visible: Comic.pageLoading && !root.hasPage && !root.stripMode
        text: Comic.statusText.length > 0 ? Comic.statusText : qsTr("正在加载…")
        color: AppTheme.colors.textSecondary
        font.pixelSize: AppTheme.fontSizeBody
    }

    C.BusyIndicator {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: Comic.statusText.length > 0 ? 28 : 0
        width: 26
        height: 26
        running: visible
        visible: Comic.pageLoading && !root.hasPage && !root.stripMode
    }

    // 远程 rar 必须整包落地（没有尾部署引），这段等待可能几十秒：
    // 给一条实打实的进度轨，别让用户以为点坏了
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.verticalCenter
        anchors.topMargin: 62
        width: Math.min(240, parent.width * 0.5)
        height: 4
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.12)
        visible: root.visible && Comic.downloadProgress >= 0

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, Comic.downloadProgress))
            height: parent.height
            radius: parent.radius
            color: AppTheme.colors.primary
        }
    }

    // ---------------- 手势（单页 / 双页）----------------

    // 单击延迟 150ms 再生效：双击的第一下不能立刻翻页，否则「双击放大」会连带翻两页
    Timer {
        id: clickTimer

        interval: 150
        onTriggered: root.handleZoneClick(pendingClick.x)
    }

    QtObject {
        id: pendingClick

        property real x: 0
    }

    MouseArea {
        id: gesture

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        // 条漫里滚动要交给列表，别被点击区吃掉；缩略图面板展开时也不能在背后翻页
        enabled: !root.stripMode && !root.shelfOpen

        property real pressX: 0
        property real pressY: 0
        property real originX: 0
        property real originY: 0
        property bool panning: false

        onPressed: function (mouse) {
            pressX = mouse.x;
            pressY = mouse.y;
            originX = root.panX;
            originY = root.panY;
            panning = false;
        }

        onPositionChanged: function (mouse) {
            if (!root.zoomed || !pressed)
                return;
            const dx = mouse.x - pressX;
            const dy = mouse.y - pressY;
            // 小抖动不算拖拽，否则单击会被吃掉
            if (!panning && Math.abs(dx) < 4 && Math.abs(dy) < 4)
                return;
            panning = true;
            root.panX = originX + dx;
            root.panY = originY + dy;
            root.clampPan();
        }

        onReleased: panning = false

        onClicked: function (mouse) {
            if (panning) {
                panning = false;
                return;
            }
            // 放大状态下单击不翻页（那是「看细节」的场景），只用来收放上下栏
            if (root.zoomed) {
                root.chromeVisible = !root.chromeVisible;
                return;
            }
            pendingClick.x = mouse.x;
            clickTimer.restart();
        }

        onDoubleClicked: function () {
            clickTimer.stop();
            // 双页是「一屏两页」，放大一张会把配对页挤没，所以只认单页
            if (root.doubleMode) {
                root.chromeVisible = !root.chromeVisible;
                return;
            }
            if (root.zoomed)
                root.resetView();
            else
                root.setZoom(2);
            root.forceActiveFocus();
        }
    }

    WheelHandler {
        // 面板展开时滚轮归网格自己滚，别在这里翻页
        enabled: !root.stripMode && !root.shelfOpen

        onWheel: function (event) {
            // Ctrl+滚轮 = 缩放（与图片查看器同一套肌肉记忆），否则翻页
            if (event.modifiers & Qt.ControlModifier) {
                const factor = event.angleDelta.y > 0 ? 1.15 : 1 / 1.15;
                root.setZoom(root.zoom * factor);
                return;
            }
            if (root.wheelLocked)
                return;
            const delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y;
            if (Math.abs(delta) < 1)
                return;
            root.wheelLocked = true;
            wheelTimer.restart();
            if (delta < 0)
                root.goNext();
            else
                root.goPrev();
        }
    }

    Timer {
        id: wheelTimer

        interval: 160
        onTriggered: root.wheelLocked = false
    }

    // ---------------- 键盘 ----------------

    Keys.onPressed: function (event) {
        // 菜单开着时先让菜单接管（Esc 关菜单而不是退出阅读器）
        if (moreMenu.opened) {
            event.accepted = false;
            return;
        }

        // 目录展开时键盘归网格：方向键挪一格、回车跳过去、Esc 收起
        if (root.shelfOpen) {
            switch (event.key) {
            case Qt.Key_Escape:
                root.shelfOpen = false;
                break;
            case Qt.Key_Left:
                shelfGrid.moveCurrentIndexLeft();
                break;
            case Qt.Key_Right:
                shelfGrid.moveCurrentIndexRight();
                break;
            case Qt.Key_Up:
                shelfGrid.moveCurrentIndexUp();
                break;
            case Qt.Key_Down:
                shelfGrid.moveCurrentIndexDown();
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                root.jumpFromShelf(shelfGrid.currentIndex);
                break;
            default:
                event.accepted = false;
                return;
            }
            event.accepted = true;
            return;
        }

        switch (event.key) {
        case Qt.Key_Escape:
            Comic.close();
            break;
        case Qt.Key_Left:
            root.flipLeft();
            break;
        case Qt.Key_Right:
            root.flipRight();
            break;
        case Qt.Key_Up:
            if (root.stripMode)
                strip.contentY = Math.max(0, strip.contentY - 160);
            else
                root.goPrev();
            break;
        case Qt.Key_Down:
            if (root.stripMode)
                strip.contentY = Math.min(strip.contentHeight - strip.height,
                                          strip.contentY + 160);
            else
                root.goNext();
            break;
        case Qt.Key_PageUp:
            root.goPrev();
            break;
        case Qt.Key_PageDown:
        case Qt.Key_Space:
            root.goNext();
            break;
        case Qt.Key_Home:
            root.goToPage(0);
            break;
        case Qt.Key_End:
            root.goToPage(Comic.pageCount - 1);
            break;
        case Qt.Key_Plus:
        case Qt.Key_Equal:
            root.setZoom(root.zoom * 1.2);
            break;
        case Qt.Key_Minus:
            root.setZoom(root.zoom / 1.2);
            break;
        case Qt.Key_0:
            root.resetView();
            break;
        case Qt.Key_D:
            // 单页 → 双页 → 条漫 → 单页（与原型快捷键表一致）
            Comic.mode = (Comic.mode + 1) % 3;
            break;
        case Qt.Key_T:
            // 目录 / 缩略图
            root.shelfOpen = true;
            break;
        default:
            event.accepted = false;
            return;
        }
        event.accepted = true;
    }

    // ---------------- 亮度蒙层 ----------------

    // 负值 = 跟随系统（不压蒙层）；只压画面，控制层保持清晰
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: Comic.brightness < 0 ? 0 : (1 - Comic.brightness) * 0.6
        visible: opacity > 0
        enabled: false
    }

    // ---------------- 顶栏（裸显示）----------------

    // 不铺面板，只在最上面压一层很淡的渐变，保证白底漫画上标题也读得清
    Rectangle {
        id: topBar

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: AppTheme.toolbarHeight
        visible: opacity > 0
        opacity: root.chromeVisible ? 1 : 0

        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Qt.rgba(0, 0, 0, 0.52)
            }
            GradientStop {
                position: 1.0
                color: "transparent"
            }
        }

        Behavior on opacity {
            NumberAnimation { duration: Motion.fast }
        }

        ReaderButton {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            icon: "arrow-left"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            onClicked: Comic.close()
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 52
            anchors.right: moreButton.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            text: Comic.title
            color: "#FFFFFF"
            elide: Text.ElideMiddle
            font.pixelSize: AppTheme.fontSizeBody
            font.weight: Font.DemiBold
        }

        // 放大时明示当前倍数，否则用户会以为自己把画面弄坏了
        Text {
            anchors.right: moreButton.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            visible: root.zoomed
            text: root.zoom.toFixed(1) + "x"
            color: Qt.rgba(1, 1, 1, 0.72)
            font.pixelSize: AppTheme.fontSizeSmall
        }

        // ⋯ 承载「模式 / 双页方向 / 亮度」：底栏不放设置按钮（原型 §3）
        ReaderButton {
            id: moreButton

            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            icon: "more-horizontal"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            onClicked: {
                if (moreMenu.opened)
                    moreMenu.close();
                else
                    moreMenu.open();
            }
        }
    }

    // ---------------- ⋯ 菜单 ----------------

    component Pill: Rectangle {
        id: pill

        property string text: ""
        property bool checked: false

        signal clicked()

        implicitWidth: Math.max(58, pillLabel.implicitWidth + AppTheme.spacingLg)
        implicitHeight: 28
        radius: height / 2
        color: pill.checked ? AppTheme.colors.primary : Qt.rgba(1, 1, 1, 0.08)

        Behavior on color {
            ColorAnimation { duration: Motion.fast }
        }

        Text {
            id: pillLabel

            anchors.centerIn: parent
            text: pill.text
            color: pill.checked ? "#FFFFFF" : Qt.rgba(1, 1, 1, 0.72)
            font.pixelSize: AppTheme.fontSizeSmall
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.clicked()
        }
    }

    C.Popup {
        id: moreMenu

        parent: root
        width: 264
        padding: AppTheme.spacingLg
        modal: false
        closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
        x: Math.max(AppTheme.spacingMd, root.width - width - AppTheme.spacingSm)
        y: AppTheme.toolbarHeight

        background: Rectangle {
            radius: AppTheme.radiusCard
            color: Qt.rgba(18 / 255, 19 / 255, 23 / 255, 0.97)
            border.width: AppTheme.borderWidth
            border.color: Qt.rgba(1, 1, 1, 0.12)
        }

        contentItem: Column {
            spacing: AppTheme.spacingLg

            Column {
                spacing: AppTheme.spacingSm
                width: parent.width

                Text {
                    text: qsTr("阅读模式")
                    color: Qt.rgba(1, 1, 1, 0.56)
                    font.pixelSize: AppTheme.fontSizeSmall
                }

                Row {
                    spacing: AppTheme.spacingSm

                    Pill {
                        text: qsTr("单页")
                        checked: Comic.mode === root.modeSingle
                        onClicked: Comic.mode = root.modeSingle
                    }

                    Pill {
                        text: qsTr("双页")
                        checked: Comic.mode === root.modeDouble
                        onClicked: Comic.mode = root.modeDouble
                    }

                    Pill {
                        text: qsTr("条漫")
                        checked: Comic.mode === root.modeStrip
                        onClicked: Comic.mode = root.modeStrip
                    }
                }
            }

            // 方向只对双页有意义：别的模式里藏起来，免得用户以为切了没用
            Column {
                spacing: AppTheme.spacingSm
                width: parent.width
                visible: Comic.mode === root.modeDouble

                Text {
                    text: qsTr("双页方向")
                    color: Qt.rgba(1, 1, 1, 0.56)
                    font.pixelSize: AppTheme.fontSizeSmall
                }

                Row {
                    spacing: AppTheme.spacingSm

                    Pill {
                        text: qsTr("从右向左")
                        checked: Comic.rightToLeft
                        onClicked: Comic.rightToLeft = true
                    }

                    Pill {
                        text: qsTr("从左向右")
                        checked: !Comic.rightToLeft
                        onClicked: Comic.rightToLeft = false
                    }
                }
            }

            Column {
                spacing: AppTheme.spacingSm
                width: parent.width

                Text {
                    width: parent.width
                    text: Comic.brightness < 0
                          ? qsTr("亮度 · 跟随系统")
                          : qsTr("亮度 · %1%").arg(Math.round(Comic.brightness * 100))
                    color: Qt.rgba(1, 1, 1, 0.56)
                    font.pixelSize: AppTheme.fontSizeSmall
                }

                C.Slider {
                    id: brightnessSlider

                    width: parent.width
                    from: 0.2
                    to: 1.0
                    stepSize: 0.02
                    value: Comic.brightness < 0 ? 1.0 : Comic.brightness
                    onMoved: Comic.brightness = Math.round(value * 100) / 100

                    background: Rectangle {
                        x: brightnessSlider.leftPadding
                        y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
                        width: brightnessSlider.availableWidth
                        height: 4
                        radius: 2
                        color: Qt.rgba(1, 1, 1, 0.18)

                        Rectangle {
                            width: brightnessSlider.visualPosition * parent.width
                            height: parent.height
                            radius: 2
                            color: AppTheme.colors.primary
                        }
                    }

                    handle: Rectangle {
                        x: brightnessSlider.leftPadding
                           + brightnessSlider.visualPosition * (brightnessSlider.availableWidth - width)
                        y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
                        width: 14
                        height: 14
                        radius: 7
                        color: "#FFFFFF"
                    }
                }

                Text {
                    text: qsTr("恢复跟随系统")
                    color: Qt.rgba(1, 1, 1, 0.42)
                    font.pixelSize: AppTheme.fontSizeSmall

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Comic.brightness = -1
                    }
                }
            }
        }
    }

    // ---------------- 底栏（毛玻璃胶囊）----------------

    GlassPanel {
        id: bottomBar

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: AppTheme.spacingLg
        width: Math.min(parent.width - 2 * AppTheme.spacingXl, 620)
        height: root.capsuleHeight
        radius: height / 2
        visible: opacity > 0
        opacity: root.chromeVisible ? 1 : 0

        // 阅读器是纯黑沉浸场景，胶囊压一层更深的底，避免亮色卡纸感
        color: Qt.rgba(10 / 255, 11 / 255, 14 / 255, 0.78)
        border.color: Qt.rgba(1, 1, 1, 0.12)

        Behavior on opacity {
            NumberAnimation { duration: Motion.fast }
        }

        ReaderButton {
            id: prevButton

            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-left"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            enabled: Comic.pageIndex > 0
            onClicked: root.goPrev()
        }

        ReaderButton {
            id: nextButton

            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-right"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            enabled: Comic.pageIndex < Comic.pageCount - 1
            onClicked: root.goNext()
        }

        // 「目录」：缩略图面板入口。放在翻页键内侧 —— 翻页仍是第一操作
        ReaderButton {
            id: shelfButton

            anchors.right: nextButton.left
            anchors.rightMargin: AppTheme.spacingXs
            anchors.verticalCenter: parent.verticalCenter
            icon: "grid"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            onClicked: root.shelfOpen = !root.shelfOpen
        }

        // 进度轨：拖动中只改本地值（ratio / dragging），松手才跳页
        Item {
            id: track

            anchors.left: prevButton.right
            anchors.leftMargin: AppTheme.spacingSm
            anchors.right: shelfButton.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height

            property bool dragging: false
            property real dragRatio: 0
            readonly property real ratio: dragging
                ? dragRatio
                : Math.max(0, Math.min(1, Comic.percent))

            function applyX(px) {
                dragRatio = Math.max(0, Math.min(1, px / Math.max(1, width)));
            }

            function pendingIndex() {
                if (Comic.pageCount <= 0)
                    return -1;
                return Math.round(dragRatio * (Comic.pageCount - 1));
            }

            // 松手时把本地比例换成页码：书只有一本，页码才是唯一真值
            function commit() {
                if (!dragging)
                    return;
                const target = pendingIndex();
                dragging = false;
                if (target >= 0)
                    root.goToPage(target);
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                height: 4
                radius: 2
                color: Qt.rgba(1, 1, 1, 0.18)
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: Math.max(0, track.width * track.ratio)
                height: 4
                radius: 2
                color: AppTheme.colors.primary
            }

            Rectangle {
                width: 12
                height: 12
                radius: 6
                color: "#FFFFFF"
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min(track.width - width, track.width * track.ratio - width / 2))
            }

            MouseArea {
                // 命中区比 4px 的轨道大得多，否则根本抓不住
                anchors.fill: parent
                anchors.topMargin: -10
                anchors.bottomMargin: -10
                cursorShape: Qt.PointingHandCursor

                onPressed: function (mouse) {
                    track.dragging = true;
                    track.applyX(mouse.x);
                }

                onPositionChanged: function (mouse) {
                    if (track.dragging)
                        track.applyX(mouse.x);
                }

                onReleased: track.commit()
                onCanceled: track.dragging = false
            }
        }
    }

    // 胶囊上方的细字：页码 / 百分比（拖动进度轨时让位给气泡）
    Text {
        id: caption

        anchors.horizontalCenter: bottomBar.horizontalCenter
        anchors.bottom: bottomBar.top
        anchors.bottomMargin: AppTheme.spacingSm
        visible: root.chromeVisible && !track.dragging && Comic.pageCount > 0
        text: qsTr("第 %1 / %2 页 · %3%").arg(Comic.pageIndex + 1).arg(Comic.pageCount)
              .arg(Math.round(Comic.percent * 100))
        color: Qt.rgba(1, 1, 1, 0.66)
        font.pixelSize: AppTheme.fontSizeSmall
    }

    // 拖动进度轨时的页码气泡：跟着拇指走，出界夹在窗口内
    Rectangle {
        id: bubble

        readonly property int targetPage: track.pendingIndex()

        width: bubbleLabel.implicitWidth + AppTheme.spacingLg
        height: 26
        radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.82)
        border.width: AppTheme.borderWidth
        border.color: Qt.rgba(1, 1, 1, 0.18)
        visible: track.dragging && targetPage >= 0
        anchors.bottom: bottomBar.top
        anchors.bottomMargin: AppTheme.spacingSm
        x: Math.max(0, Math.min(root.width - width,
                                bottomBar.x + track.x + track.width * track.ratio - width / 2))

        Text {
            id: bubbleLabel

            anchors.centerIn: parent
            text: (bubble.targetPage + 1) + " / " + Comic.pageCount
            color: "#FFFFFF"
            font.pixelSize: AppTheme.fontSizeSmall
        }
    }

    // ---------------- 缩略图面板（目录）----------------

    // 一页一格：图走同一条解压缓存（`pageUrlAt` 只查盘），按格子尺寸 `sourceSize`
    // 小尺寸解码；delegate 建出来才 `ensurePage`，薄本秒出、厚本滚到哪解到哪。
    // 声明在亮度蒙层之后：面板是控制层，不该跟着画面被压暗。
    Rectangle {
        id: shelf

        anchors.fill: parent
        // 不透明：半透明会让底下的页图文字透出来，跟缩略图糊成一片
        color: "#0C0D10"
        visible: opacity > 0
        enabled: root.shelfOpen
        opacity: root.shelfOpen ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Motion.fast }
        }

        // 面板上的点击不穿透到翻页手势
        MouseArea {
            anchors.fill: parent
        }

        Item {
            id: shelfHeader

            anchors.top: parent.top
            anchors.topMargin: AppTheme.spacingLg
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingLg
            height: 36

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("目录 · 共 %1 页").arg(Comic.pageCount)
                color: Qt.rgba(1, 1, 1, 0.88)
                font.pixelSize: AppTheme.fontSizeBody
                font.weight: Font.DemiBold
            }

            Text {
                anchors.right: shelfClose.left
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("第 %1 页").arg(Comic.pageIndex + 1)
                color: Qt.rgba(1, 1, 1, 0.56)
                font.pixelSize: AppTheme.fontSizeSmall
            }

            ReaderButton {
                id: shelfClose

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon: "x"
                fg: "#FFFFFF"
                hoverFill: Qt.rgba(1, 1, 1, 0.14)
                onClicked: root.shelfOpen = false
            }
        }

        // 展开瞬间格子的 cellHeight 还是过渡值（按它算 contentY 会停在半行），
        // 等布局稳定后再按行对齐一次
        Timer {
            id: shelfRecenter

            interval: 50
            repeat: false
            onTriggered: {
                const i = Math.max(0, Comic.pageIndex);
                const row = Math.floor(i / shelfGrid.columns);
                shelfGrid.currentIndex = i;
                // 只按整行滚：滚到半行上首行会被视口顶部切掉一块，看着像矮了一格的卡片
                shelfGrid.contentY = Math.max(0, Math.min(row * shelfGrid.cellHeight,
                                                         shelfGrid.contentHeight - shelfGrid.height));
            }
        }

        GridView {
            id: shelfGrid

            // 窄窗口少排几列，别把缩略图压成一条线
            readonly property int columns: Math.max(3, Math.min(8, Math.floor(width / 150)))

            anchors.top: shelfHeader.bottom
            anchors.topMargin: AppTheme.spacingMd
            anchors.left: shelfHeader.left
            anchors.right: shelfHeader.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: AppTheme.spacingLg

            cellWidth: width / columns
            // 漫画页是竖的，但格子再高也别超过视口一半：否则一屏放不下两整行，
            // 滚到当前页时首行会被视口顶部切掉一块
            cellHeight: Math.min(Math.round(cellWidth * 1.4) + 22,
                                 Math.max(Math.round(cellWidth), Math.floor(height / 2)))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 600
            model: Comic.pageCount

            delegate: Item {
                id: shelfCell

                required property int index

                width: shelfGrid.cellWidth
                height: shelfGrid.cellHeight

                readonly property bool current: index === Comic.pageIndex

                Rectangle {
                    id: thumbBox

                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 4
                    width: shelfCell.width - AppTheme.spacingMd
                    height: shelfCell.height - 24
                    radius: AppTheme.radiusSmall
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border.width: shelfCell.current ? 2 : AppTheme.borderWidth
                    border.color: shelfCell.current ? AppTheme.colors.primary : Qt.rgba(1, 1, 1, 0.10)

                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        // 缩略图按格子尺寸解码：整页大图进内存只为了画 100px 不划算
                        sourceSize.width: Math.round(width)
                        sourceSize.height: Math.round(height)
                        // 同上：`cacheRevision` 要参与表达式，否则依赖会被优化掉
                        source: root.cacheRevision >= 0
                                ? Comic.pageUrlAt(shelfCell.index)
                                : ""
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    text: shelfCell.index + 1
                    color: shelfCell.current ? AppTheme.colors.primary : Qt.rgba(1, 1, 1, 0.56)
                    font.pixelSize: AppTheme.fontSizeSmall
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.jumpFromShelf(shelfCell.index)
                }

                Component.onCompleted: Comic.ensurePage(shelfCell.index)
            }
        }
    }

    // ---------------- 错误 ----------------

    Rectangle {
        anchors.fill: parent
        visible: Comic.errorText.length > 0
        color: Qt.rgba(0, 0, 0, 0.72)

        Column {
            anchors.centerIn: parent
            spacing: AppTheme.spacingLg
            width: Math.min(420, parent.width - 2 * AppTheme.spacingXl)

            Text {
                width: parent.width
                text: Comic.errorText
                color: AppTheme.colors.textPrimary
                font.pixelSize: AppTheme.fontSizeBody
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: AppTheme.spacingMd

                PrimaryButton {
                    text: qsTr("重试")
                    variant: PrimaryButton.Primary
                    enabled: !Comic.pageLoading && Comic.pageIndex >= 0
                    onClicked: Comic.retryPage()
                }

                PrimaryButton {
                    text: qsTr("关闭")
                    variant: PrimaryButton.Secondary
                    onClicked: Comic.close()
                }
            }
        }
    }

}
