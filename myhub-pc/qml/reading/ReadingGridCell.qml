import QtQuick
import MyHub

/*
  「正在阅读」网格卡片（PC-209）。

  结构：封面区（类型图标 + 类型徽标）/ 标题 / 环形进度 + 百分比 / 相对时间。
  纪律：
    - 选中为「浮起抬升」，与浏览页共用 CellPressHighlight，不得各写一套
    - 已读完的记录保留在列表里（直到手动删除），文案按类型区分
*/
Item {
    id: root

    property string entryTitle: ""
    property string entryMediaKind: "video"
    property string entryKindText: ""
    property real entryPercent: 0
    property string entryPercentText: ""
    property bool entryFinished: false
    property string entryFinishedText: ""
    property string entryRelativeTime: ""
    property string entryConnectionId: ""
    property string entryPath: ""
    property bool selected: false
    property int nameLines: 3

    signal clicked(var mouse)
    signal doubleClicked()
    signal rightClicked(real mouseX, real mouseY)

    /// 封面区高度：宽高比 1.3（与原型 .rcard .cv 一致）
    readonly property real coverHeight: (width - AppTheme.spacingSm * 2) / 1.3

    // 卡片底色：阅读首页的卡片是「有描边的白卡片」，区别于浏览页的无底色网格
    Rectangle {
        anchors.fill: parent
        radius: AppTheme.radiusCard
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    CellPressHighlight {
        anchors.fill: parent
        hovered: mouse.containsMouse
        selected: root.selected
        pressed: mouse.pressed
        inset: 2
        radius: AppTheme.radiusCard
    }

    Column {
        anchors.fill: parent
        anchors.margins: AppTheme.spacingSm
        spacing: 0

        // ---- 封面区：统一封面组件（无封面时回退类型图标）----
        Item {
            width: parent.width
            height: root.coverHeight

            CoverImage {
                anchors.fill: parent
                connectionId: root.entryConnectionId
                filePath: root.entryPath
                mediaKind: root.entryMediaKind
                radius: AppTheme.radiusInput + 1
                iconRatio: 0.42
            }

            // 类型徽标
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: AppTheme.spacingXs + 1
                width: badgeText.implicitWidth + 10
                height: 17
                radius: 4
                color: AppTheme.colors.primaryWeak

                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: root.entryKindText
                    font.family: AppTheme.fontFamily
                    font.pixelSize: 10
                    color: AppTheme.colors.primary
                }
            }
        }

        Item { width: 1; height: AppTheme.spacingSm }

        // ---- 标题：居中等宽，最多 nameLines 行 ----
        Text {
            width: parent.width
            height: root.nameLines * 14
            text: root.entryTitle
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            font.bold: true
            color: AppTheme.colors.textPrimary
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: root.nameLines
            elide: Text.ElideRight
            lineHeight: 1.2
        }

        Item { width: 1; height: 7 }

        // ---- 环形进度 + 下方百分比 ----
        ProgressRing {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 30
            height: 30
            progress: root.entryPercent
        }

        Item { width: 1; height: 5 }

        Text {
            width: parent.width
            text: root.entryFinished ? root.entryFinishedText : root.entryPercentText
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny - 1
            font.bold: root.entryFinished
            color: root.entryFinished ? AppTheme.colors.primary : AppTheme.colors.textSecondary
        }

        Item { width: 1; height: 3 }

        Text {
            width: parent.width
            text: root.entryRelativeTime
            horizontalAlignment: Text.AlignHCenter
            font.family: AppTheme.fontFamily
            font.pixelSize: 10
            color: AppTheme.colors.textFaint
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: function(mouseEvent) {
            if (mouseEvent.button === Qt.RightButton) {
                const global = mapToGlobal(mouseEvent.x, mouseEvent.y)
                root.rightClicked(global.x, global.y)
            } else {
                root.clicked(mouseEvent)
            }
        }
        onDoubleClicked: root.doubleClicked()
    }
}
