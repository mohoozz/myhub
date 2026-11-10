import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  输入框（§2.10）：圆角 8，填充 fieldFill，聚焦时主色描边。
*/
C.TextField {
    id: control

    property string label: ""
    property bool invalid: false

    implicitHeight: 36
    leftPadding: 10
    rightPadding: 10
    font.family: AppTheme.fontFamily
    font.pixelSize: AppTheme.fontSizeBody
    color: AppTheme.colors.textPrimary
    placeholderTextColor: AppTheme.colors.textFaint
    selectionColor: AppTheme.colors.primary
    selectedTextColor: AppTheme.colors.textOnPrimary

    background: Rectangle {
        radius: AppTheme.radiusInput
        color: AppTheme.colors.fieldFill
        border.width: control.activeFocus || control.invalid ? AppTheme.borderWidth : 0
        border.color: control.invalid ? AppTheme.colors.danger : AppTheme.colors.primary

        Behavior on border.color { ColorAnimation { duration: Motion.fast } }
    }
}
