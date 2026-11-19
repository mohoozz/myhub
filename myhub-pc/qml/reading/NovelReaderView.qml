pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  小说阅读器（§5.1 / PC-205·206·210）。

  分层：正文分章、解编码、锚点换算全在 C++（`NovelBridge` + `myhub_core/novel`），
  这里只做三件事：把段落画出来、把滚动位置报回去、把排版偏好改掉。

  排版选型：**按段落虚拟化**，一段一个 Text，model 直接是 `Novel.paragraphs`。
    · 相比「整章塞进一个 TextEdit」，长章节不会一次性排完全部文字；
    · 段落下标天然就是锚点单位，滚动上报与恢复定位都不需要字符坐标换算；
    · 段距、行距、字号改了只需重建可见的十几个 item，调字号不会卡住 UI。
*/
Item {
    id: root

    // ---------------- 纸色主题（§5.1 主题：跟随系统 / 日间 / 夜间 / 护眼）----------------
    // 纸色与 AppTheme 的中性色刻意不同源：正文底色是「内容」，不该被外壳主题牵着走，
    // 否则夜间模式下叠加两种深色会出现半透明的脏灰
    readonly property int palette: Novel.theme === 0 ? (AppTheme.dark ? 2 : 1) : Novel.theme
    readonly property color paper: palette === 2 ? "#141517" : palette === 3 ? "#CFE3D0" : "#F6F1E4"
    readonly property color ink: palette === 2 ? "#BFC3CB" : palette === 3 ? "#2C3A2E" : "#2A2721"
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    readonly property color rule: Qt.rgba(ink.r, ink.g, ink.b, 0.12)
    readonly property color hoverFill: Qt.rgba(ink.r, ink.g, ink.b, 0.08)
    readonly property color sheetFill: palette === 2 ? "#1D1E21" : palette === 3 ? "#DCEBDB" : "#FFFDF8"

    /// 正文栏宽：超过约 34 个汉字一行就难以回扫，宽屏下拉满反而难读
    readonly property real columnWidth: Math.min(720, Math.max(280, width - 2 * AppTheme.spacingXl))

    /// 滚动上报节流（C++ 侧还有 1s 落库节流，这里只负责别把每个像素都发过去）
    property bool restoring: false
    property int pendingAnchor: -1

    /**
     * 是否已翻到全书最后（末章 + 列表见底）。
     *
     * 只有滚动视图知道「当前这屏是不是最后一屏」：按字节或段落下标在 C++ 侧猜，
     * 短章、插图、字号变化都会误判。恢复定位期间 contentY 会瞬时跳到末尾，必须排除。
     */
    readonly property bool atBookEnd: Novel.opened && !restoring && Novel.chapterCount > 0
        && Novel.chapterIndex >= Novel.chapterCount - 1 && (Novel.pageMode ? pageAtEnd : listAtEnd)

    /// 滚动模式：当前这屏是不是最后一屏
    readonly property bool listAtEnd: list.contentHeight > 0
        && (list.contentHeight <= list.height + 2
            || list.contentY + list.height >= list.contentHeight - 2)

    /// 翻页模式：最后一页。页数由 C++ 分页给出，这里只比对，不再自己量高度
    readonly property bool pageAtEnd: Novel.pageCount > 0 && Novel.pageIndex >= Novel.pageCount - 1

    onAtBookEndChanged: Novel.setAtBookEnd(atBookEnd)

    visible: Novel.opened || Novel.loading || Novel.errorText.length > 0
    focus: visible

    onVisibleChanged: if (visible) forceActiveFocus()

    Connections {
        target: Novel
        function onChapterChanged() {
            // 换章了：查看层里那张图属于上一章，直接收起
            imageViewer.close()
            if (Novel.pageMode)
                viewportTimer.restart() // 新章的分页已经由 C++ 做好，核对一次视口即可
            else if (Novel.opened)
                root.scheduleAnchor()
        }

        function onFontChanged() {
            // 换字体等于换行宽：滚动模式下每段高度都变了，重新锚回当前段；
            // 翻页模式由 C++ 那边按当前页首行重排，这里不用管
            if (!Novel.pageMode)
                root.scheduleAnchor()
        }

        function onPageModeChanged() {
            if (Novel.pageMode) {
                // 从滚动切过来要接着读：把当前屏首段报上去，页码落到那一段所在的页
                const anchor = list.indexAt(1, list.contentY)
                if (anchor >= 0) {
                    Novel.reportParagraph(anchor)
                    Novel.pageIndex = Novel.pageForParagraph(anchor)
                }
                // 页视图刚可见，尺寸还没结算：等一拍再推视口
                viewportTimer.restart()
            } else {
                // 切回滚动：按翻页时上报的锚点定位（scheduleAnchor 会等布局稳定再落）
                root.scheduleAnchor()
            }
        }
    }

    // ---------------- 定位与上报 ----------------

    /// 恢复锚点。段落 model 是异步换上的，所以「立刻 + 稍后」各定位一次：
    /// 只做一步的话，delegate 还没量出高度，positionViewAtIndex 会按估算高度落偏
    function scheduleAnchor() {
        pendingAnchor = Novel.anchorParagraph
        restoring = true
        restoreTimer.restart()
        Qt.callLater(root.applyAnchor)
        anchorRetry.restart()
    }

    function applyAnchor() {
        // 翻页模式的落点由 C++ 按锚点算出页码，ListView 不参与
        if (!Novel.opened || Novel.pageMode)
            return
        if (pendingAnchor > 0 && pendingAnchor < list.count)
            list.positionViewAtIndex(pendingAnchor, ListView.Beginning)
        else
            list.positionViewAtBeginning()
    }

    function pushProgress() {
        // 翻页模式的进度由「翻到第几页」直接上报（见 NovelBridge::setPageIndex）
        if (!Novel.opened || restoring || Novel.pageMode)
            return
        const first = list.indexAt(1, Math.max(0, list.contentY + 2))
        if (first >= 0)
            Novel.reportParagraph(first)
    }

    /// 翻页：滚动模式下一屏一屏走，翻页模式交给 C++ 分页（跨章也在那边发生）
    function pageBy(direction) {
        if (Novel.pageMode) {
            if (direction > 0)
                Novel.nextPage()
            else
                Novel.prevPage()
            return
        }
        const maxY = Math.max(0, list.contentHeight - list.height)
        list.contentY = Math.max(0, Math.min(maxY, list.contentY + direction * list.height * 0.9))
        pushProgress()
    }

    Timer {
        id: reportTimer
        interval: 350
        onTriggered: root.pushProgress()
    }

    Timer {
        id: restoreTimer
        interval: 400
        onTriggered: root.restoring = false
    }

    Timer {
        id: anchorRetry
        interval: 120
        onTriggered: root.applyAnchor()
    }

    // 顶/底栏收起时正文可视区会连着变几帧：等尺寸稳定再推给 C++ 重排，
    // 否则每帧都要拿整章去折一次行
    Timer {
        id: viewportTimer
        interval: 180
        onTriggered: pageView.pushViewport()
    }

    // ---------------- 快捷键（§5.1）----------------
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            if (imageViewer.opened)
                imageViewer.close()
            else if (settingsPanel.opened)
                settingsPanel.opened = false
            else if (drawer.opened)
                drawer.opened = false
            else
                Novel.close()
            event.accepted = true
            return
        }
        if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_Left) {
                Novel.prevChapter()
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                Novel.nextChapter()
                event.accepted = true
            } else if (event.key === Qt.Key_D) {
                drawer.opened = !drawer.opened
                event.accepted = true
            } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
                Novel.fontSize = Novel.fontSize + 1
                event.accepted = true
            } else if (event.key === Qt.Key_Minus) {
                Novel.fontSize = Novel.fontSize - 1
                event.accepted = true
            }
            return
        }
        if (Novel.pageMode) {
            // 翻页模式：正文没有可滚的东西，上下键也当翻页
            if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp
                    || event.key === Qt.Key_Up) {
                root.pageBy(-1)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown
                    || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
                root.pageBy(1)
                event.accepted = true
                return
            }
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp) {
            root.pageBy(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown
                   || event.key === Qt.Key_Space) {
            root.pageBy(1)
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            list.contentY = Math.max(0, list.contentY - 80)
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            list.contentY = list.contentY + 80
            event.accepted = true
        }
    }

    // ---------------- 纸面 ----------------
    Rectangle {
        anchors.fill: parent
        color: root.paper
    }

    // ---------------- 章内提示（截断 / 未识别到章节）----------------
    // 只在这种「有正文但信息不完整」的场合出现；首次打开的进度文案由全屏覆盖层负责
    Text {
        id: statusBanner

        anchors.top: topBar.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        height: visible ? implicitHeight + AppTheme.spacingSm : 0
        visible: Novel.opened && Novel.statusText.length > 0
        text: Novel.statusText
        color: root.inkSoft
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.Wrap
        font.family: Novel.fontFamilies
        font.pixelSize: AppTheme.fontSizeSmall
    }

    // ---------------- 正文 ----------------
    ListView {
        id: list

        anchors.top: topBar.bottom
        anchors.bottom: bottomBar.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        clip: true
        // 翻页模式由 pageView 接手：两边同时画会出现两份正文叠在一起
        visible: !Novel.pageMode

        model: Novel.paragraphs
        // 段距用「字号的固定倍数」而不是行高的倍数：行距调大时段与段之间不该跟着膨胀
        spacing: Math.round(Novel.fontSize * 0.5)
        // 提示条占住的那几像素由正文让出来，避免第一段被压住
        topMargin: AppTheme.spacingXl + statusBanner.height
        bottomMargin: AppTheme.spacingXl
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 1600
        // 正文区域不抢焦点：空格/方向键要交给根节点做翻页
        focus: false

        header: Item {
            width: list.width
            height: heading.implicitHeight + AppTheme.spacingXl

            Column {
                id: heading
                width: parent.width
                spacing: AppTheme.spacingMd

                Text {
                    width: parent.width
                    text: Novel.chapterTitle
                    color: root.ink
                    wrapMode: Text.Wrap
                    font.family: Novel.fontFamilies
                    // 章名是这一页的「标题」：比正文大一号再加粗，滚到章首一眼能看出来
                    font.pixelSize: Math.round(Novel.fontSize * 1.38)
                    font.weight: Font.Bold
                    lineHeight: 1.25
                    lineHeightMode: Text.ProportionalHeight
                }

                Rectangle {
                    width: 36
                    height: 2
                    color: root.inkSoft
                }
            }
        }

        footer: Item {
            width: list.width
            height: tail.implicitHeight + AppTheme.spacingXl * 2

            Row {
                id: tail
                anchors.centerIn: parent
                spacing: AppTheme.spacingMd

                ReaderButton {
                    label: qsTr("上一章")
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    enabled: Novel.chapterIndex > 0
                    onClicked: Novel.prevChapter()
                }

                ReaderButton {
                    label: qsTr("下一章")
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    enabled: Novel.chapterIndex < Novel.chapterCount - 1
                    onClicked: Novel.nextChapter()
                }
            }
        }

        delegate: Item {
            id: paragraph

            required property string modelData
            required property int index

            /// 插图段落：正文里插图占一格，段落文本是空串
            readonly property bool isImage: Novel.isImageParagraph(index)
            /// 插图快照 URL：空 = 还没取到（或离线且没缓存过）
            readonly property string imageSource: paragraph.currentImageUrl()
            /// 等比缩到栏宽后的尺寸；原图更窄就不放大（放大只会糊）
            readonly property size imageExtent: paragraph.currentExtent()
            readonly property bool showImage: paragraph.imageSource.length > 0
            readonly property real imageHeight: Math.max(paragraph.imageExtent.height, Math.round(
                                                             Novel.fontSize * 1.6))

            /// 章名段：epub 的 <h1> 会落成第 0 段，抬头已经写着章名，正文里不再重复
            readonly property bool isChapterTitle: paragraph.index === Novel.titleParagraph

            width: list.width
            height: paragraph.isChapterTitle ? 0
                  : (paragraph.showImage ? paragraph.imageHeight : textItem.implicitHeight)
            visible: !paragraph.isChapterTitle

            function currentImageUrl() {
                if (!paragraph.isImage)
                    return ""
                // 建立依赖：插图落地后 revision 自增，这里的绑定才会重算
                // （段落 model 不变，不依赖它的话图永远停在「加载中」）
                void Novel.imageRevision
                return Novel.imageUrl(paragraph.index)
            }

            function currentExtent() {
                if (!paragraph.isImage)
                    return Qt.size(0, 0)
                void Novel.imageRevision
                const natural = Novel.imageSize(paragraph.index)
                if (natural.width <= 0 || natural.height <= 0)
                    return Qt.size(0, 0)
                const scale = Math.min(1, list.width / natural.width)
                return Qt.size(Math.round(natural.width * scale), Math.round(natural.height * scale))
            }

            Text {
                id: textItem

                // 插图有字节时由 Image 顶替；没有就留一行占位，别让列表凭空短一截
                visible: !paragraph.showImage
                width: parent.width
                text: paragraph.isImage ? (Novel.offline ? qsTr("［插图未缓存］") : qsTr("［插图加载中…］")) : paragraph.modelData
                color: root.ink
                opacity: paragraph.isImage ? 0.6 : 1
                horizontalAlignment: paragraph.isImage ? Text.AlignHCenter : Text.AlignLeft
                wrapMode: Text.Wrap
                // 与分页器共用同一串族名：换宋体时两边的行宽必须一起变
                font.family: Novel.fontFamilies
                font.pixelSize: Novel.fontSize
                // 行距按字号倍数缩放：字号与行距是两个独立偏好，互不牵连
                lineHeight: Novel.lineSpacing
                lineHeightMode: Text.ProportionalHeight
            }

            Image {
                id: paragraphImage

                visible: paragraph.showImage
                anchors.horizontalCenter: parent.horizontalCenter
                width: paragraph.imageExtent.width
                height: paragraph.imageHeight
                source: paragraph.showImage ? paragraph.imageSource : ""
                // 插图可能不小：异步解码，别让滚动卡住
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                cache: true

                // 能点的东西要给出手型：不然用户不知道图可以放大
                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onTapped: imageViewer.show(paragraph.index)
                }
            }
        }

        onContentYChanged: {
            if (!root.restoring)
                reportTimer.restart()
        }
        onMovementEnded: root.pushProgress()
        onCountChanged: if (root.restoring) Qt.callLater(root.applyAnchor)
    }

    // ---------------- 正文（翻页模式，§5.1）----------------
    // 页内容由 NovelPager 逐行切好：行由 C++ 断开（NoWrap），行距由它给出（FixedHeight），
    // 所以「量到的行」与「画出来的行」是同一批，不需要 QML 再猜高度
    Item {
        id: pageView

        anchors.top: topBar.bottom
        anchors.bottom: bottomBar.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        visible: Novel.pageMode && Novel.opened
        clip: true

        /// 本页若是整页插图，值是该插图段落；-1 = 文字页
        readonly property int imageParagraph: {
            void Novel.paginationRevision // 重排（换章/改字号/改窗口宽度）后必须重取
            return Novel.pageImageParagraph(Novel.pageIndex)
        }
        readonly property bool isImagePage: imageParagraph >= 0
        /// 本章第一个文字页：章名带只出现在这一页（C++ 已为它预留两行高）
        readonly property bool onTitlePage: Novel.titlePage >= 0 && Novel.pageIndex === Novel.titlePage
                                             && !isImagePage
        readonly property string imageSource: {
            void Novel.imageRevision
            return isImagePage ? Novel.imageUrl(imageParagraph) : ""
        }
        /// 整页插图：等比铺满正文区，窄图不放大
        readonly property size imageExtent: {
            void Novel.imageRevision
            if (!isImagePage)
                return Qt.size(0, 0)
            const natural = Novel.imageSize(imageParagraph)
            if (natural.width <= 0 || natural.height <= 0 || pageBody.width <= 0)
                return Qt.size(0, 0)
            const scale = Math.min(1, Math.min(pageBody.width / natural.width,
                                               pageBody.height / natural.height))
            return Qt.size(Math.round(natural.width * scale),
                           Math.round(natural.height * scale))
        }
        readonly property var pageLines: {
            void Novel.paginationRevision
            return Novel.pageLines(Novel.pageIndex)
        }

        /// 正文可视区只有这里知道：推给 C++ 才能按真实宽度折行
        function pushViewport() {
            if (!Novel.pageMode || !Novel.opened || pageBody.width <= 0 || pageBody.height <= 0)
                return
            // 字体不用传：分页器与正文用同一份 `Novel.fontFamilies`
            Novel.setPageViewport(Math.round(pageBody.width), Math.round(pageBody.height))
        }

        onVisibleChanged: if (visible) viewportTimer.restart()

        // 章节标题当书眉：放在排版区外面占固定一行，翻页时页码才不会被标题挤动
        Text {
            id: pageHeading

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            text: Novel.chapterTitle
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
            color: root.inkSoft
            // 章名页上正文里已经有放大加粗的章名：书眉让位（只透明，不隐藏，
            // 否则 pageBody 的高度会跟着变，视口一变就要重排）
            opacity: pageView.onTitlePage ? 0 : 1
            font.family: Novel.fontFamilies
            font.pixelSize: AppTheme.fontSizeSmall
        }

        Item {
            id: pageBody

            anchors.top: pageHeading.bottom
            anchors.topMargin: AppTheme.spacingLg
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: pageFooter.top
            anchors.bottomMargin: AppTheme.spacingMd

            onWidthChanged: viewportTimer.restart()
            onHeightChanged: viewportTimer.restart()

            /// 章名带：本章第一个文字页的顶部，高度就是分页器预留的那两行。
            /// 字号按余量现算（不超过正文的 1.42 倍），保证两行一定塞得进这条带子
            Item {
                id: titleBand

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: pageView.onTitlePage ? Novel.titleReserve : 0
                visible: height > 0

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Math.round(Novel.fontSize * 0.3)
                    text: Novel.chapterTitle
                    color: root.ink
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: Novel.fontFamilies
                    font.pixelSize: Math.max(AppTheme.fontSizeSmall,
                                             Math.min(Math.round(Novel.fontSize * 1.42),
                                                      Math.floor(titleBand.height / 2 / 1.15)))
                    font.weight: Font.Bold
                    lineHeight: 1.15
                    lineHeightMode: Text.ProportionalHeight
                }
            }

            Text {
                anchors.top: parent.top
                anchors.topMargin: titleBand.height
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: !pageView.isImagePage
                text: pageView.pageLines.join("\n")
                color: root.ink
                // 行已经由 C++ 断好，这里再折一次就会和页高对不上
                wrapMode: Text.NoWrap
                lineHeightMode: Text.FixedHeight
                lineHeight: Novel.pageLineHeight
                // 分页器就是按这一串族名折的行：两边一致，页高才对得上
                font.family: Novel.fontFamilies
                font.pixelSize: Novel.fontSize
                clip: true
            }

            Image {
                anchors.centerIn: parent
                visible: pageView.isImagePage && pageView.imageSource.length > 0
                width: pageView.imageExtent.width
                height: pageView.imageExtent.height
                source: pageView.imageSource
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                cache: true

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
            }

            Text {
                anchors.centerIn: parent
                visible: pageView.isImagePage && pageView.imageSource.length === 0
                text: Novel.offline ? qsTr("［插图未缓存］") : qsTr("［插图加载中…］")
                color: root.inkSoft
                font.family: Novel.fontFamilies
                font.pixelSize: AppTheme.fontSizeBody
            }

            TapHandler {
                onTapped: function(eventPoint) {
                    if (pageView.isImagePage) {
                        imageViewer.show(pageView.imageParagraph)
                        return
                    }
                    // 桌面端不必去够键盘：右侧 60% 往后翻，左侧 40% 往前
                    if (eventPoint.position.x > pageBody.width * 0.4)
                        Novel.nextPage()
                    else
                        Novel.prevPage()
                }
            }
        }

        Text {
            id: pageFooter

            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            text: (Novel.pageIndex + 1) + " / " + Math.max(1, Novel.pageCount)
            color: root.inkSoft
            font.family: Novel.fontFamilies
            font.pixelSize: AppTheme.fontSizeSmall
        }
    }

    // ---------------- 顶栏 ----------------
    Rectangle {
        id: topBar

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: AppTheme.toolbarHeight
        color: root.paper

        ReaderButton {
            id: backButton
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-left"
            fg: root.ink
            hoverFill: root.hoverFill
            onClicked: Novel.close()
        }

        Column {
            anchors.centerIn: parent
            // 窄窗口（竖屏 / 分屏）下让位给左右两组按钮，别让标题压到图标上
            width: Math.max(0, Math.min(parent.width - 260, 560))
            spacing: 0

            Text {
                width: parent.width
                text: Novel.title
                color: root.ink
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.weight: Font.DemiBold
            }

            Text {
                width: parent.width
                text: Novel.chapterTitle
                color: root.inkSoft
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ReaderButton {
                icon: "list"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: drawer.opened = !drawer.opened
            }

            ReaderButton {
                icon: "settings"
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: settingsPanel.opened = !settingsPanel.opened
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.rule
        }
    }

    // ---------------- 底栏 ----------------
    Rectangle {
        id: bottomBar

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: AppTheme.toolbarHeight + 4
        color: root.paper

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 2
            color: root.rule

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, Novel.percent))
                height: parent.height
                color: AppTheme.colors.primary
            }
        }

        ReaderButton {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-left"
            label: qsTr("上一章")
            fg: root.ink
            hoverFill: root.hoverFill
            enabled: Novel.chapterIndex > 0
            onClicked: Novel.prevChapter()
        }

        Text {
            anchors.centerIn: parent
            width: Math.max(0, parent.width - 300)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: Novel.chapterCount > 0
                ? qsTr("%1 / %2 章 · %3%").arg(Novel.chapterIndex + 1).arg(Novel.chapterCount).arg(Math.round(Novel.percent * 100))
                : ""
            color: root.inkSoft
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
        }

        ReaderButton {
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            icon: "chevron-right"
            label: qsTr("下一章")
            fg: root.ink
            hoverFill: root.hoverFill
            enabled: Novel.chapterIndex < Novel.chapterCount - 1
            onClicked: Novel.nextChapter()
        }
    }

    // ---------------- 读完推荐「下一本」（§4.6 阅读侧）----------------
    // 与播放器同一条纪律：**无倒计时、不自动切换**，点才走，点叉就不再打扰
    Rectangle {
        id: nextBanner

        readonly property var suggestion: Novel.nextSuggestion || ({})
        readonly property bool hasSuggestion: suggestion.path !== undefined && suggestion.path !== ""

        visible: hasSuggestion
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: bottomBar.top
        anchors.bottomMargin: AppTheme.spacingLg
        width: Math.min(root.columnWidth, 480)
        height: 68
        radius: AppTheme.radiusCard
        // 用纸面色而不是固定深色：阅读器有自己的日间/夜间/护眼三套底色
        color: root.sheetFill
        border.width: AppTheme.borderWidth
        border.color: root.rule

        Column {
            anchors.left: parent.left
            anchors.leftMargin: AppTheme.spacingLg
            anchors.right: actions.left
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: qsTr("读完了 · 下一本")
                color: root.inkSoft
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
            }

            Text {
                width: parent.width
                text: nextBanner.suggestion.title || ""
                color: root.ink
                elide: Text.ElideRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.weight: Font.DemiBold
            }
        }

        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: AppTheme.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs

            ReaderButton {
                label: qsTr("开始读")
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: Novel.openNextSuggestion()
            }

            ReaderButton {
                icon: "x"
                fg: root.inkSoft
                hoverFill: root.hoverFill
                onClicked: Novel.dismissNextSuggestion()
            }
        }
    }

    // ---------------- 目录抽屉（PC-205）----------------
    Item {
        id: drawer

        property bool opened: false
        property int panelWidth: Math.min(340, Math.round(root.width * 0.72))

        anchors.fill: parent
        z: 40
        // 收起后不该拦住正文的鼠标事件
        visible: opened || panel.x < root.width

        // 抽屉里的 ListView 会抢焦点，收起时把键盘交还给根节点，否则 Esc/翻页失灵
        onOpenedChanged: if (!opened) root.forceActiveFocus()

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: drawer.opened ? 0.24 : 0
            enabled: drawer.opened

            Behavior on opacity {
                NumberAnimation { duration: Motion.normal }
            }

            TapHandler {
                onTapped: drawer.opened = false
            }
        }

        Rectangle {
            id: panel

            width: drawer.panelWidth
            height: parent.height
            x: drawer.opened ? parent.width - width : parent.width
            color: root.sheetFill

            Behavior on x {
                NumberAnimation {
                    duration: Motion.normal
                    easing.type: Motion.easeOut
                }
            }

            Item {
                id: panelHeader

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: AppTheme.toolbarHeight

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: AppTheme.spacingLg
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("目录 · %1 章").arg(Novel.chapterCount)
                    color: root.ink
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeHeading
                    font.weight: Font.DemiBold
                }

                ReaderButton {
                    anchors.right: parent.right
                    anchors.rightMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "x"
                    fg: root.inkSoft
                    hoverFill: root.hoverFill
                    onClicked: drawer.opened = false
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.rule
                }
            }

            ListView {
                id: tocList

                anchors.top: panelHeader.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                clip: true
                model: Novel.chapters
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: tocRow

                    required property var modelData
                    required property int index

                    width: tocList.width
                    height: 44
                    color: index === Novel.chapterIndex ? root.hoverFill
                           : tocHover.hovered ? root.hoverFill : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: AppTheme.spacingLg
                        anchors.right: parent.right
                        anchors.rightMargin: AppTheme.spacingLg
                        anchors.verticalCenter: parent.verticalCenter
                        text: tocRow.modelData.title
                        elide: Text.ElideRight
                        color: tocRow.index === Novel.chapterIndex ? AppTheme.colors.primary : root.ink
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        font.weight: tocRow.index === Novel.chapterIndex ? Font.DemiBold : Font.Normal
                    }

                    HoverHandler {
                        id: tocHover
                    }

                    TapHandler {
                        onTapped: {
                            Novel.goToChapter(tocRow.index)
                            drawer.opened = false
                        }
                    }
                }
            }

            onXChanged: if (drawer.opened && Novel.chapterIndex >= 0) tocList.positionViewAtIndex(
                            Novel.chapterIndex, ListView.Contain)
        }
    }

    // ---------------- 设置面板（字号/行距/主题/亮度）----------------
    Item {
        id: settingsPanel

        property bool opened: false
        readonly property int sheetHeight: 328

        anchors.fill: parent
        z: 50
        visible: opened || sheetBody.y < root.height

        // 亮度滑杆是 Controls 控件，点过之后会持有 activeFocus
        onOpenedChanged: if (!opened) root.forceActiveFocus()

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: settingsPanel.opened ? 0.24 : 0
            enabled: settingsPanel.opened

            Behavior on opacity {
                NumberAnimation { duration: Motion.normal }
            }

            TapHandler {
                onTapped: settingsPanel.opened = false
            }
        }

        Rectangle {
            id: sheetBody

            anchors.left: parent.left
            anchors.right: parent.right
            height: settingsPanel.sheetHeight
            y: settingsPanel.opened ? root.height - height : root.height
            color: root.sheetFill
            radius: AppTheme.radiusCard

            Behavior on y {
                NumberAnimation {
                    duration: Motion.normal
                    easing.type: Motion.easeOut
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: AppTheme.spacingXl
                spacing: AppTheme.spacingMd

                // ---- 排版模式 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("排版")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    // 滚动 / 翻页两段式：选中的那段用正文色填充
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 132
                        height: 32
                        radius: height / 2
                        color: root.hoverFill

                        Row {
                            anchors.fill: parent
                            anchors.margins: 3

                            Repeater {
                                model: [QT_TR_NOOP("滚动"), QT_TR_NOOP("翻页")]

                                delegate: Rectangle {
                                    id: modeCell

                                    required property int index
                                    required property string modelData

                                    readonly property bool active: Novel.pageMode === (index === 1)

                                    width: 63
                                    height: parent.height
                                    radius: height / 2
                                    color: active ? root.ink : "transparent"

                                    Text {
                                        anchors.centerIn: parent
                                        text: modeCell.modelData
                                        color: modeCell.active ? root.sheetFill : root.inkSoft
                                        font.family: AppTheme.fontFamily
                                        font.pixelSize: AppTheme.fontSizeSmall
                                    }

                                    TapHandler {
                                        onTapped: Novel.pageMode = modeCell.index === 1
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- 字号 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("字号")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        ReaderButton {
                            icon: "chevron-left"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.fontSize > 12
                            onClicked: Novel.fontSize = Novel.fontSize - 1
                        }

                        Text {
                            width: 40
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignHCenter
                            text: Novel.fontSize
                            color: root.ink
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                        }

                        ReaderButton {
                            icon: "chevron-right"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.fontSize < 32
                            onClicked: Novel.fontSize = Novel.fontSize + 1
                        }
                    }
                }

                // ---- 字体 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("字体")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    // 黑体 / 宋体：只换正文与页内文字，界面文案不动
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 132
                        height: 32
                        radius: height / 2
                        color: root.hoverFill

                        Row {
                            anchors.fill: parent
                            anchors.margins: 3

                            Repeater {
                                model: [QT_TR_NOOP("黑体"), QT_TR_NOOP("宋体")]

                                delegate: Rectangle {
                                    id: styleCell

                                    required property int index
                                    required property string modelData

                                    readonly property bool active: Novel.fontStyle === index

                                    width: 63
                                    height: parent.height
                                    radius: height / 2
                                    color: active ? root.ink : "transparent"

                                    Text {
                                        anchors.centerIn: parent
                                        // 标签自己就用那种字体：没点之前先看得出差别
                                        text: styleCell.modelData
                                        color: styleCell.active ? root.sheetFill : root.inkSoft
                                        font.family: styleCell.index === 1
                                                     ? Novel.fontFamilies : AppTheme.fontFamily
                                        font.pixelSize: AppTheme.fontSizeSmall
                                    }

                                    TapHandler {
                                        onTapped: Novel.fontStyle = styleCell.index
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- 行距 ----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("行距")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        ReaderButton {
                            icon: "chevron-left"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.lineSpacing > 1.25
                            onClicked: Novel.lineSpacing = Math.max(1.2, Math.round((Novel.lineSpacing - 0.2) * 10) / 10)
                        }

                        Text {
                            width: 40
                            horizontalAlignment: Text.AlignHCenter
                            text: Novel.lineSpacing.toFixed(1)
                            color: root.ink
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                        }

                        ReaderButton {
                            icon: "chevron-right"
                            fg: root.ink
                            hoverFill: root.hoverFill
                            enabled: Novel.lineSpacing < 2.35
                            onClicked: Novel.lineSpacing = Math.min(2.4, Math.round((Novel.lineSpacing + 0.2) * 10) / 10)
                        }
                    }
                }

                // ---- 主题 ----
                Item {
                    width: parent.width
                    height: 40

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("主题")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: AppTheme.spacingSm

                        Repeater {
                            // 0=跟随系统 1=日间 2=夜间 3=护眼：色块即预览，避免文字标签再来一层抽象
                            model: ["auto", "day", "night", "eye"]

                            delegate: Rectangle {
                                id: swatch

                                required property int index

                                width: 34
                                height: 30
                                radius: AppTheme.radiusSmall
                                color: index === 0 ? root.sheetFill
                                       : index === 1 ? "#F6F1E4"
                                       : index === 2 ? "#141517" : "#CFE3D0"
                                border.width: Novel.theme === index ? 2 : 1
                                border.color: Novel.theme === index ? AppTheme.colors.primary : root.rule

                                Text {
                                    anchors.centerIn: parent
                                    visible: swatch.index === 0
                                    text: qsTr("自动")
                                    color: root.ink
                                    font.family: AppTheme.fontFamily
                                    font.pixelSize: AppTheme.fontSizeTiny
                                }

                                TapHandler {
                                    onTapped: Novel.theme = swatch.index
                                }
                            }
                        }
                    }
                }

                // ---- 亮度（窗口蒙层，与播放器共用偏好）----
                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("亮度")
                        color: root.inkSoft
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                    }

                    C.Slider {
                        id: brightnessSlider

                        anchors.left: parent.left
                        anchors.leftMargin: 64
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0.35
                        to: 1.0
                        // -1 是「不叠加蒙层」的哨兵值，视觉上等同最亮
                        value: Novel.brightness < 0 ? 1.0 : Novel.brightness

                        onMoved: Novel.brightness = Math.round(value * 100) / 100
                    }
                }
            }
        }
    }

    // ---------------- 插图查看（点图放大）----------------
    // 正文里插图只有栏宽那么大，细看不够；这里给一层铺满窗口的查看层：
    // 滚轮缩放、拖动平移、单击 / Esc / 右上角关闭
    Item {
        id: imageViewer

        anchors.fill: parent
        z: 80
        visible: opacity > 0
        opacity: opened ? 1 : 0

        property bool opened: false
        property url sourceUrl
        property size naturalSize
        /// 1 = 刚好铺满可视区；上限 4 倍，再往上只有马赛克
        property real zoom: 1

        readonly property real maxZoom: 4
        readonly property int zoomPercent: Math.round(zoom * 100)
        readonly property size displaySize: extentAt(zoom)
        /// 「铺满可视区」相对原图的比例：小图保持 1:1，放大只会糊
        readonly property real fitScale: (naturalSize.width > 0 && naturalSize.height > 0)
            ? Math.min(1, Math.min((width - 2 * AppTheme.spacingXl) / naturalSize.width,
                                   (height - 2 * AppTheme.spacingXl) / naturalSize.height))
            : 1

        Behavior on opacity {
            NumberAnimation { duration: Motion.normal }
        }

        function extentAt(level) {
            const scale = fitScale * level
            return Qt.size(Math.round(naturalSize.width * scale),
                           Math.round(naturalSize.height * scale))
        }

        function show(index) {
            const url = Novel.imageUrl(index)
            const size = Novel.imageSize(index)
            // 占位段落没有字节：点了不弹空黑屏，安静地什么都不做
            if (String(url).length === 0 || size.width <= 0 || size.height <= 0)
                return
            sourceUrl = url
            naturalSize = size
            zoom = 1
            opened = true
        }

        function close() {
            opened = false
        }

        function zoomBy(step) {
            const next = Math.max(1, Math.min(maxZoom, Math.round((zoom + step) * 100) / 100))
            if (next === zoom)
                return
            // 先按旧尺寸记下视口中心对着的内容位置，缩放后把同一处拉回中心，
            // 否则每放大一次画面都往左上角跑
            const before = extentAt(zoom)
            const after = extentAt(next)
            const oldW = Math.max(panner.width, before.width)
            const oldH = Math.max(panner.height, before.height)
            const newW = Math.max(panner.width, after.width)
            const newH = Math.max(panner.height, after.height)
            const cx = (panner.contentX + panner.width / 2) / Math.max(1, oldW)
            const cy = (panner.contentY + panner.height / 2) / Math.max(1, oldH)
            zoom = next
            panner.contentX = Math.max(0, Math.min(newW - panner.width, cx * newW - panner.width / 2))
            panner.contentY = Math.max(0,
                                       Math.min(newH - panner.height, cy * newH - panner.height / 2))
        }

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: 0.92
        }

        Flickable {
            id: panner

            anchors.fill: parent
            contentWidth: Math.max(width, imageViewer.displaySize.width)
            contentHeight: Math.max(height, imageViewer.displaySize.height)
            // 只有放大到超出可视区才需要平移；1:1 时拖着不该动
            interactive: contentWidth > width + 1 || contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Image {
                x: (panner.contentWidth - width) / 2
                y: (panner.contentHeight - height) / 2
                width: imageViewer.displaySize.width
                height: imageViewer.displaySize.height
                source: imageViewer.sourceUrl
                asynchronous: true
                cache: true
                smooth: true
                fillMode: Image.PreserveAspectFit

                HoverHandler {
                    cursorShape: panner.interactive ? Qt.OpenHandCursor : Qt.ArrowCursor
                }
            }

            TapHandler {
                onTapped: imageViewer.close()
            }

            // 桌面端以滚轮为准（触控板双指滑动同样走 angleDelta）
            WheelHandler {
                onWheel: function(event) {
                    imageViewer.zoomBy(event.angleDelta.y > 0 ? 0.25 : -0.25)
                    event.accepted = true
                }
            }
        }

        // 放大后看不出自己在哪一层，给个刻度 + 操作提示
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: AppTheme.spacingLg
            anchors.horizontalCenter: parent.horizontalCenter
            text: imageViewer.zoomPercent + "%" + qsTr(" · 滚轮缩放 · 拖动平移 · 点击关闭")
            color: "#FFFFFF"
            opacity: 0.7
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
        }

        ReaderButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: AppTheme.spacingMd
            icon: "x"
            fg: "#FFFFFF"
            hoverFill: Qt.rgba(1, 1, 1, 0.14)
            onClicked: imageViewer.close()
        }
    }

    // ---------------- 加载 / 错误 ----------------
    Rectangle {
        id: stateOverlay

        anchors.fill: parent
        z: 60
        color: root.paper
        // 只有「首次打开」和「出错」才全屏遮挡；换章时正文还在，不该闪一层白
        visible: Novel.errorText.length > 0 || (Novel.loading && Novel.paragraphs.length === 0)

        Column {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 64)
            spacing: AppTheme.spacingLg

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: root.ink
                text: Novel.errorText.length > 0 ? Novel.errorText : Novel.statusText
                font.family: Novel.fontFamilies
                font.pixelSize: AppTheme.fontSizeBody
            }

            ReaderButton {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: Novel.errorText.length > 0
                label: qsTr("返回")
                fg: root.ink
                hoverFill: root.hoverFill
                onClicked: Novel.close()
            }
        }
    }

    // ---------------- 亮度蒙层（§5.1「窗口蒙层」，只压这一层）----------------
    Rectangle {
        anchors.fill: parent
        z: 70
        color: "#000000"
        opacity: Novel.brightness < 0 ? 0 : (1 - Novel.brightness) * 0.6
        visible: opacity > 0.001
    }
}
