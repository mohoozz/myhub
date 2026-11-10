import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  统一菜单体系（§1.2 / §14.4）。

  纪律：
    - 圆角 + 弹出动画
    - **在鼠标位置精确定位**（不得偏移到上方）
    - 菜单底部与窗口边缘保持足够间距
*/
C.Menu {
    id: control

    /// 在指定的全局坐标处弹出，自动避让窗口边缘
    function popupAt(mouseX, mouseY) {
        const win = control.parent ? control.parent.Window.window : null
        const margin = AppTheme.spacingMd

        let x = mouseX
        let y = mouseY

        if (win) {
            // 右侧放不下则向左翻转
            if (x + control.implicitWidth > win.width - margin)
                x = Math.max(margin, mouseX - control.implicitWidth)
            // 底部放不下则向上翻转，保证底部留白
            if (y + control.implicitHeight > win.height - margin)
                y = Math.max(margin, mouseY - control.implicitHeight)
        }
        control.popup(x, y)
    }

    implicitWidth: 196
    padding: AppTheme.spacingXs
    closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside

    background: Rectangle {
        radius: AppTheme.radiusInput + 2
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.fast }
            NumberAnimation { property: "scale"; from: 0.94; to: 1
                              duration: Motion.normal; easing.type: Motion.easeOut }
        }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Motion.fast }
    }

    delegate: C.MenuItem {
        id: item
        implicitHeight: 34
        leftPadding: 10
        rightPadding: 10
        font.family: AppTheme.fontFamily
        font.pixelSize: AppTheme.fontSizeBody

        contentItem: Row {
            spacing: AppTheme.spacingSm

            AppIcon {
                name: item.icon.name
                visible: item.icon.name !== ""
                width: 16
                height: 16
                anchors.verticalCenter: parent.verticalCenter
                color: item.enabled ? AppTheme.colors.textSecondary
                                    : AppTheme.colors.textFaint
            }
            Text {
                text: item.text
                anchors.verticalCenter: parent.verticalCenter
                font: item.font
                color: item.enabled ? AppTheme.colors.textPrimary
                                    : AppTheme.colors.textFaint
            }
        }

        background: Rectangle {
            radius: AppTheme.radiusSmall
            color: item.highlighted ? AppTheme.colors.hoverFill : "transparent"
        }
    }
}
