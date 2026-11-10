import QtQuick
import MyHub

/*
  「正在阅读」列表行（PC-209）。

  结构：缩略图（类型图标）/ 标题 +（类型徽标 · 相对时间）/ 右侧环形进度 + 百分比。
  纪律：行间无分割线；选中为「浮起抬升」内缩小片。
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

    signal clicked(var mouse)
    signal doubleClicked()
    signal rightClicked(real mouseX, real mouseY)

    implicitHeight: 76

    CellPressHighlight {
        anchors.fill: parent
        hovered: mouse.containsMouse
        selected: root.selected
        pressed: mouse.pressed
        inset: 3
        radius: AppTheme.radiusInput + 2
    }

    Item {
        id: rowContent
        anchors.fill: parent
        anchors.leftMargin: AppTheme.spacingMd
        anchors.rightMargin: AppTheme.spacingMd
        anchors.topMargin: AppTheme.spacingSm
        anchors.bottomMargin: AppTheme.spacingSm

        // ---- 缩略图：统一封面组件（无封面时回退类型图标）----
        CoverImage {
            id: thumb
            width: 52
            height: 52
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            connectionId: root.entryConnectionId
            filePath: root.entryPath
            mediaKind: root.entryMediaKind
            radius: AppTheme.radiusInput
            iconRatio: 0.5
        }

        // ---- 右侧进度 ----
        Item {
            id: progressColumn
            width: 54
            height: 46
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            ProgressRing {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 28
                height: 28
                progress: root.entryPercent
            }

            Text {
                anchors.top: parent.top
                anchors.topMargin: 32
                width: parent.width
                text: root.entryFinished ? root.entryFinishedText : root.entryPercentText
                horizontalAlignment: Text.AlignHCenter
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny - 1
                font.bold: root.entryFinished
                color: root.entryFinished ? AppTheme.colors.primary : AppTheme.colors.textSecondary
            }
        }

        // ---- 标题 + 元信息 ----
        Column {
            anchors.left: thumb.right
            anchors.leftMargin: AppTheme.spacingMd
            anchors.right: progressColumn.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: AppTheme.spacingXs + 1

            Text {
                width: parent.width
                text: root.entryTitle
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.bold: true
                color: AppTheme.colors.textPrimary
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            Row {
                spacing: AppTheme.spacingSm

                Rectangle {
                    width: kindLabel.implicitWidth + 10
                    height: 17
                    radius: 4
                    color: AppTheme.colors.primaryWeak

                    Text {
                        id: kindLabel
                        anchors.centerIn: parent
                        text: root.entryKindText
                        font.family: AppTheme.fontFamily
                        font.pixelSize: 10
                        color: AppTheme.colors.primary
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.entryRelativeTime
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeSmall
                    color: AppTheme.colors.textFaint
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
