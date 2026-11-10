import QtQuick
import MyHub

/*
  网格视图单元（§3.1 / §14.3）。

  纪律：
    - 标题**居中**
    - 视频时长在**标题下方**（不挤占封面、不换行）
    - 目录**不显示子项数**
    - 文件名行数由设置控制（1~5），即时生效
    - 选中为「浮起抬升」，不得贴边直角色块
*/
Item {
    id: root

    property string name: ""
    property bool isDir: false
    property string mediaKind: "file"
    property string sizeText: ""
    property string durationText: ""
    property string badge: ""
    property bool selected: false
    /// 已收藏（PC-107）：与收藏页同一份数据，切换后即刻反映
    property bool favorite: false
    property int nameLines: 3
    /// 阅读进度 0~1；< 0 表示没有记录（角标不出现）
    property real progress: -1
    /// 已看完（角标文案由调用方决定，这里只保证画满环时语义正确）
    property bool progressFinished: false
    /// 这个条目就是当前播放/阅读的文件
    property bool playing: false
    /// 多选态（只有多选时才显示勾选标记）
    property bool selectionMode: false
    // 封面数据源（PC-702）
    property string connectionId: ""
    property string filePath: ""
    property real fileSize: -1
    property real fileModSecs: -1
    /// 页面内拖拽时的落点高亮（目标文件夹）
    property bool dropTarget: false
    /// 「定位到原路径」呼吸灯（PC-109）
    property bool revealHighlight: false
    /// 拖拽时承接 `MouseArea.drag.target` 的占位项：
    /// 只为让 MouseArea 拿到 keepMouseGrab，避免 GridView/ListView 抢走鼠标去滚动
    property Item dragProxy: null

    /// 状态角标优先级：正在播放 > 进度环 > 无标识（§3.1）
    readonly property bool showRing: !root.playing && !root.isDir && root.progress >= 0

    signal clicked(var mouse)
    /// 窗口坐标：不支持预览时按「鼠标位置」弹菜单用（§3.4）
    signal doubleClicked(real windowX, real windowY)
    signal rightClicked(real mouseX, real mouseY)
    // 页面内拖拽（PC-104）：坐标一律用窗口坐标，由页面做命中判定
    signal dragStarted()
    signal dragMoved(real globalX, real globalY, int modifiers)
    signal dragDropped(real globalX, real globalY, int modifiers)
    signal dragCanceled()

    // 统一的浮起抬升高亮
    CellPressHighlight {
        anchors.fill: parent
        hovered: mouse.containsMouse
        selected: root.selected
        pressed: mouse.pressed
        inset: 2
        radius: AppTheme.radiusCard
    }

    // 定位到原路径（PC-109）：呼吸环，放在内容之上但不吃鼠标（无 MouseArea）
    RevealHalo {
        anchors.fill: parent
        anchors.margins: 2
        active: root.revealHighlight
        cornerRadius: AppTheme.radiusCard
    }

    // 落点反馈：主色细环 + 极淡填充（与选中「浮起抬升」区分，不重复着色块）
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        visible: root.dropTarget
        radius: AppTheme.radiusCard
        color: AppTheme.colors.primaryWeak
        border.width: 2
        border.color: AppTheme.colors.primary
    }

    Column {
        anchors.fill: parent
        anchors.margins: AppTheme.spacingSm
        spacing: AppTheme.spacingSm

        // 封面区：统一封面组件（无封面时回退类型图标）
        Item {
            width: parent.width
            height: width * 0.72

            CoverImage {
                anchors.fill: parent
                connectionId: root.connectionId
                filePath: root.filePath
                mediaKind: root.mediaKind
                isDir: root.isDir
                fileSize: root.fileSize
                fileModSecs: root.fileModSecs
                radius: AppTheme.radiusInput
                iconRatio: 0.6
            }

            // 收藏星标（左上；右上留给类型徽标）
            AppIcon {
                visible: root.favorite
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 3
                width: 15
                height: 15
                name: "star"
                color: AppTheme.colors.star
                filled: true
            }

            // 漫画徽标（多选态让位给勾选标记，勾选标记必须永远可见）
            Rectangle {
                visible: root.badge === "comic" && !root.selectionMode
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 2
                width: badgeText.implicitWidth + 10
                height: 18
                radius: 4
                color: AppTheme.colors.primary

                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: qsTr("漫画")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeTiny
                    color: AppTheme.colors.textOnPrimary
                }
            }

            // 阅读进度环（右下角；左上留给收藏星标、右上留给类型徽标）
            Rectangle {
                visible: root.showRing
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 3
                width: 24
                height: 24
                radius: width / 2
                color: Qt.rgba(1, 1, 1, 0.92)
            }

            ProgressRing {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6
                width: 18
                height: 18
                visible: root.showRing
                progress: root.progress
                strokeWidth: 2.6
            }

            // 正在播放：三竖条均衡器（左下角）
            PlayingBars {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 5
                width: 12
                height: 12
                barWidth: 2.6
                barGap: 1.6
                visible: root.playing && !root.isDir
                active: root.playing
            }

            // 多选勾选标记（右上角，与进度环/均衡器并列可见）
            SelectionTick {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 3
                width: 18
                height: 18
                visible: root.selectionMode
                checked: root.selected
            }
        }

        // 标题：居中，行数可配；正在播放的那一条主色加粗（§3.1）
        Text {
            width: parent.width
            text: root.name
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            font.weight: root.playing ? Font.DemiBold : Font.Normal
            color: root.playing ? AppTheme.colors.primary : AppTheme.colors.textPrimary
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: root.nameLines
            elide: Text.ElideRight
            lineHeight: 1.2
        }

        // 时长在标题下方，单行不换行；目录不显示任何附加信息
        Text {
            width: parent.width
            visible: !root.isDir && root.durationText !== ""
            text: root.durationText
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            color: AppTheme.colors.textSecondary
            maximumLineCount: 1
            elide: Text.ElideRight
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        // 用 drag.target 接管拖拽手势：MouseArea 一旦进入 drag 就会保住鼠标抓取，
        // 外层 GridView 不会把它当成滚动手势抢走（否则页内拖拽会被滚动打断）
        drag.target: root.dragProxy
        drag.threshold: 8
        drag.axis: Drag.XAndYAxis

        /// 已越过拖拽阈值：本次按下不再算点击（释放后只做落点处理）
        property bool dragging: false
        property real pressX: 0
        property real pressY: 0

        onPressed: function(mouseEvent) {
            pressX = mouseEvent.x
            pressY = mouseEvent.y
            dragging = false
        }
        onPositionChanged: function(mouseEvent) {
            if (!mouse.pressed)
                return
            if (!dragging) {
                // 阈值 8px：小于阈值仍视为点击（避免手抖误判成拖拽）
                if (Math.abs(mouseEvent.x - pressX) + Math.abs(mouseEvent.y - pressY) < 8)
                    return
                dragging = true
                root.dragStarted()
            }
            const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
            root.dragMoved(global.x, global.y, mouseEvent.modifiers)
        }
        onReleased: function(mouseEvent) {
            if (!dragging)
                return
            const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
            root.dragDropped(global.x, global.y, mouseEvent.modifiers)
        }
        onCanceled: {
            if (dragging)
                root.dragCanceled()
            dragging = false
        }

        onClicked: function(mouseEvent) {
            if (dragging) {
                // 拖拽结束的那次释放不触发选中/打开
                dragging = false
                return
            }
            if (mouseEvent.button === Qt.RightButton) {
                // 右键菜单在鼠标位置精确弹出（§14.4）
                const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
                root.rightClicked(global.x, global.y)
            } else {
                root.clicked(mouseEvent)
            }
        }
        onDoubleClicked: function(mouseEvent) {
            if (dragging)
                return
            // 带上窗口坐标：不支持预览时菜单要落在鼠标位置（§3.4）
            const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
            root.doubleClicked(global.x, global.y)
        }
    }
}
