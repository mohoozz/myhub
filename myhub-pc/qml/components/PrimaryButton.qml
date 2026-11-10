import QtQuick
import QtQuick.Controls.Basic
import MyHub

/*
  按钮（§2.10）：
    主按钮  实心蓝
    次按钮  浅蓝底 + 蓝字
    文本按钮 透明底
    破坏性  语义红
  按压反馈：缩放 0.975 + 淡填充
*/
Button {
    id: control

    property int variant: PrimaryButton.Primary
    property string iconName: ""
    property bool destructive: false

    enum Variant { Primary, Secondary, Text }

    implicitHeight: 36
    leftPadding: iconName !== "" ? 12 : 16
    rightPadding: 16
    font.family: AppTheme.fontFamily
    font.pixelSize: AppTheme.fontSizeBody

    readonly property color _accent: destructive ? AppTheme.colors.danger
                                                 : AppTheme.colors.primary

    scale: pressed ? AppTheme.pressScale : 1.0
    Behavior on scale {
        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut }
    }

    background: Rectangle {
        radius: AppTheme.radiusButton
        color: {
            if (!control.enabled)
                return control.variant === PrimaryButton.Primary
                    ? AppTheme.colors.textFaint : "transparent"
            switch (control.variant) {
            case PrimaryButton.Primary:
                return control.hovered
                    ? Qt.darker(control._accent, 1.08) : control._accent
            case PrimaryButton.Secondary:
                return control.hovered
                    ? Qt.rgba(control._accent.r, control._accent.g, control._accent.b, 0.16)
                    : Qt.rgba(control._accent.r, control._accent.g, control._accent.b, 0.10)
            default:
                return control.hovered ? AppTheme.colors.hoverFill : "transparent"
            }
        }
        border.width: control.variant === PrimaryButton.Secondary ? AppTheme.borderWidth : 0
        border.color: Qt.rgba(control._accent.r, control._accent.g, control._accent.b, 0.25)

        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    contentItem: Row {
        spacing: 6

        AppIcon {
            name: control.iconName
            visible: control.iconName !== ""
            width: 16
            height: 16
            anchors.verticalCenter: parent.verticalCenter
            color: control.variant === PrimaryButton.Primary
                ? AppTheme.colors.textOnPrimary : control._accent
        }

        Text {
            text: control.text
            visible: control.text !== ""
            anchors.verticalCenter: parent.verticalCenter
            font: control.font
            color: {
                if (!control.enabled)
                    return AppTheme.colors.textFaint
                return control.variant === PrimaryButton.Primary
                    ? AppTheme.colors.textOnPrimary : control._accent
            }
        }
    }
}
