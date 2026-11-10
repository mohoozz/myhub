import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  目录内搜索框（§3.1 / §14.5）。

  关键纪律（iOS 实战经验）：
    - **仅当内容滚动在顶部时显示**，向下滚动超过搜索框高度才隐藏
    - **迟滞判定防抖动**：显示与隐藏使用不同阈值，避免临界处反复横跳
    - **上下无分割线**
*/
Item {
    id: root

    property alias text: input.text
    property string placeholderText: qsTr("搜索当前目录")
    /// 绑定到列表的 contentY
    property real contentY: 0
    property bool forceVisible: false

    readonly property int fieldHeight: AppTheme.searchHeight

    // 迟滞判定：超过 fieldHeight 才隐藏，回到 8px 以内才重新显示。
    // 两个阈值拉开距离，避免在单一阈值附近抖动。
    property bool _revealed: true
    onContentYChanged: {
        if (_revealed) {
            if (contentY > fieldHeight)
                _revealed = false
        } else {
            if (contentY < 8)
                _revealed = true
        }
    }

    readonly property bool shown: forceVisible || _revealed || input.activeFocus

    implicitHeight: shown ? fieldHeight + AppTheme.spacingSm : 0
    clip: true

    Behavior on implicitHeight {
        NumberAnimation { duration: Motion.reveal; easing.type: Motion.easeOut }
    }

    opacity: shown ? 1.0 : 0.0
    Behavior on opacity {
        NumberAnimation { duration: Motion.reveal }
    }

    C.TextField {
        id: input
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.fieldHeight

        leftPadding: 34
        rightPadding: clearButton.visible ? 34 : 10
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeBody
        color: AppTheme.colors.textPrimary
        placeholderText: root.placeholderText
        placeholderTextColor: AppTheme.colors.textFaint
        selectionColor: AppTheme.colors.primary
        selectedTextColor: AppTheme.colors.textOnPrimary

        // 上下无分割线：仅填充 + 圆角，不加 border-bottom
        background: Rectangle {
            radius: AppTheme.radiusInput
            color: AppTheme.colors.fieldFill
            border.width: input.activeFocus ? AppTheme.borderWidth : 0
            border.color: AppTheme.colors.primary
        }

        AppIcon {
            name: "search"
            width: 16
            height: 16
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            color: AppTheme.colors.textFaint
        }

        MouseArea {
            id: clearButton
            visible: input.text !== ""
            width: 24
            height: 24
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            cursorShape: Qt.ArrowCursor
            onClicked: {
                input.clear()
                input.forceActiveFocus()
            }

            AppIcon {
                anchors.centerIn: parent
                name: "x"
                width: 14
                height: 14
                color: AppTheme.colors.textSecondary
            }
        }

        Keys.onEscapePressed: {
            if (input.text !== "")
                input.clear()
            else
                input.focus = false
        }
    }

    function focusInput() {
        root.forceVisible = true
        input.forceActiveFocus()
    }
}
