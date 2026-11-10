import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  单行输入对话框（新建文件夹 / 重命名，§3.2）。

  视觉与 ConfirmDialog 完全一致（居中 + 完全圆角），只在内容里多一个输入框。
  纪律：**就地校验**——非法名称不关闭对话框、保留用户已输入的内容，
  只在输入框下方给出原因，用户改完即可再提交。
*/
C.Dialog {
    id: control

    property string message: ""
    property string placeholderText: ""
    property string initialText: ""
    property string confirmText: qsTr("确定")
    property string cancelText: qsTr("取消")
    /// 校验失败原因（由调用方在提交时设置）
    property string errorText: ""

    /// 提交事件。是否关闭由调用方决定（校验通过才 close）
    signal submitted(string text)

    modal: true
    anchors.centerIn: C.Overlay.overlay
    width: Math.min(420, (parent ? parent.width : 420) - 64)
    padding: AppTheme.spacingXl
    closePolicy: C.Popup.CloseOnEscape
    /// 与 ConfirmDialog 一致：标题由 contentItem 渲染，关掉默认 header
    header: null

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

    function openFor(titleText, messageText, initial) {
        title = titleText
        message = messageText
        initialText = initial || ""
        errorText = ""
        open()
    }

    onOpened: {
        input.text = control.initialText
        input.forceActiveFocus()
        input.selectAll()
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

        TextField {
            id: input
            width: parent.width
            placeholderText: control.placeholderText
            invalid: control.errorText !== ""
            onTextEdited: control.errorText = ""
            Keys.onReturnPressed: control.submitted(text)
            Keys.onEnterPressed: control.submitted(text)
        }

        Text {
            width: parent.width
            visible: control.errorText !== ""
            text: control.errorText
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            color: AppTheme.colors.danger
            wrapMode: Text.Wrap
        }

        Item { width: 1; height: AppTheme.spacingXs }

        Row {
            anchors.right: parent.right
            spacing: AppTheme.spacingSm

            PrimaryButton {
                text: control.cancelText
                variant: PrimaryButton.Text
                onClicked: control.reject()
            }
            PrimaryButton {
                text: control.confirmText
                variant: PrimaryButton.Primary
                onClicked: control.submitted(input.text)
            }
        }
    }
}
