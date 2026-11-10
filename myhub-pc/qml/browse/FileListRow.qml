import QtQuick
import MyHub

/*
  列表视图行（§3.1 / §14.3）。

  纪律：
    - **行间无分割线**
    - 行高较紧凑模式 +1/4
    - 目录不显示大小与子项数
    - 选中为「浮起抬升」（内缩成悬浮片）
*/
Item {
    id: root

    property string name: ""
    property bool isDir: false
    property string mediaKind: "file"
    property string sizeText: ""
    property string typeText: ""
    property string durationText: ""
    property bool selected: false
    /// 已收藏（PC-107）
    property bool favorite: false
    property int nameLines: 1
    /// 阅读进度 0~1；< 0 表示没有记录（行尾不画进度环）
    property real progress: -1
    /// 已看完
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
    /// 只为让 MouseArea 拿到 keepMouseGrab，避免 ListView 抢走鼠标去滚动
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

    // 紧凑行高 36 的 1.25 倍 = 45
    implicitHeight: Math.max(45, nameText.implicitHeight + AppTheme.spacingMd * 2)

    CellPressHighlight {
        anchors.fill: parent
        hovered: mouse.containsMouse
        selected: root.selected
        pressed: mouse.pressed
        // 列表行内缩成悬浮片
        inset: 3
        radius: AppTheme.radiusInput + 2
    }

    // 定位到原路径（PC-109）：呼吸环
    RevealHalo {
        anchors.fill: parent
        anchors.margins: 3
        active: root.revealHighlight
        cornerRadius: AppTheme.radiusInput + 2
    }

    // 落点反馈：主色细环 + 极淡填充
    Rectangle {
        anchors.fill: parent
        anchors.margins: 3
        visible: root.dropTarget
        radius: AppTheme.radiusInput + 2
        color: AppTheme.colors.primaryWeak
        border.width: 2
        border.color: AppTheme.colors.primary
    }

    Item {
        anchors.fill: parent
        anchors.leftMargin: AppTheme.spacingMd
        anchors.rightMargin: AppTheme.spacingMd

        CoverImage {
            id: typeIcon
            width: 26
            height: 26
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            connectionId: root.connectionId
            filePath: root.filePath
            mediaKind: root.mediaKind
            isDir: root.isDir
            fileSize: root.fileSize
            fileModSecs: root.fileModSecs
            radius: AppTheme.radiusSmall
            cropFill: false
            iconRatio: 0.9
        }

        Text {
            id: nameText
            anchors.left: typeIcon.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.right: metaRow.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            text: root.name
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            // 正在播放：主色加粗（§3.1）
            font.weight: root.playing ? Font.DemiBold : Font.Normal
            color: root.playing ? AppTheme.colors.primary : AppTheme.colors.textPrimary
            wrapMode: root.nameLines > 1 ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
            maximumLineCount: root.nameLines
            elide: Text.ElideRight
        }

        Row {
            id: metaRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingLg

            // 收藏星标（PC-107）
            AppIcon {
                visible: root.favorite
                width: 14
                height: 14
                anchors.verticalCenter: parent.verticalCenter
                name: "star"
                color: AppTheme.colors.star
                filled: true
            }

            Text {
                text: root.durationText
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
            }

            Text {
                text: root.typeText
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: 56
                horizontalAlignment: Text.AlignRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textFaint
            }

            // 目录不显示大小
            Text {
                text: root.sizeText
                visible: !root.isDir && text !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: 76
                horizontalAlignment: Text.AlignRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
            }

            // 行尾角标：正在播放画均衡器，否则画进度环；勾选标记紧随其后。
            // 三者同处一个紧凑 Row，避免被 metaRow 的 spacingLg 拉开成三簇
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: AppTheme.spacingXs

                PlayingBars {
                    width: 12
                    height: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.playing && !root.isDir
                    active: root.playing
                }

                ProgressRing {
                    width: 18
                    height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.showRing
                    progress: root.progress
                    strokeWidth: 2.6
                }

                SelectionTick {
                    width: 18
                    height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.selectionMode
                    checked: root.selected
                    onMedia: false
                }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        // 用 drag.target 接管拖拽手势：保住鼠标抓取，ListView 不会把它当成滚动抢走
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
                dragging = false
                return
            }
            if (mouseEvent.button === Qt.RightButton) {
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
