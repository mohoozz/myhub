import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  确认框（§2.10 / §14.4）。

  纪律：一律**居中 + 完全圆角矩形**，
  不得使用带尖角的锚点气泡。删除确认等全部统一走这里。
*/
C.Dialog {
    id: control

    property string message: ""
    property string confirmText: qsTr("确定")
    property string cancelText: qsTr("取消")
    property bool destructive: false
    /// 只有一个按钮的场景（如「操作失败」→ 知道了）关掉取消按钮
    property bool showCancel: true

    modal: true
    anchors.centerIn: C.Overlay.overlay      // 居中
    width: Math.min(420, (parent ? parent.width : 420) - 64)
    padding: AppTheme.spacingXl
    closePolicy: C.Popup.CloseOnEscape
    /// 标题由 contentItem 统一按主题字号渲染，关掉默认 header 避免重复出现一行小号标题
    header: null

    // 完全圆角矩形
    background: Rectangle {
        radius: AppTheme.radiusCard
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    C.Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.42)
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.fast }
            NumberAnimation { property: "scale"; from: 0.96; to: 1
                              duration: Motion.normal; easing.type: Motion.easeOut }
        }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Motion.fast }
    }

    contentItem: Column {
        spacing: AppTheme.spacingMd

        Text {
            width: parent.width
            visible: control.title !== ""
            text: control.title
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeHeading
            font.bold: true
            color: AppTheme.colors.textPrimary
            wrapMode: Text.Wrap
        }

        Text {
            width: parent.width
            visible: control.message !== ""
            text: control.message
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
            color: AppTheme.colors.textSecondary
            wrapMode: Text.Wrap
            lineHeight: 1.4
        }

        Item { width: 1; height: AppTheme.spacingXs }

        Row {
            anchors.right: parent.right
            spacing: AppTheme.spacingSm

            PrimaryButton {
                text: control.cancelText
                variant: PrimaryButton.Text
                visible: control.showCancel
                width: visible ? implicitWidth : 0
                onClicked: control.reject()
            }
            PrimaryButton {
                text: control.confirmText
                variant: PrimaryButton.Primary
                destructive: control.destructive
                onClicked: control.accept()
            }
        }
    }
}
