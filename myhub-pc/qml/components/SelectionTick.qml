import QtQuick
import MyHub

/*
  多选勾选标记（§3.1 / §14.3）。

  纪律：
    · 18px 圆形，未选中是空心描边，选中是主色实心 + 白色对勾
    · **只在多选态出现**（selectionMode 由页面给），且不得压掉同位置的状态角标
    · 网格里叠在封面上：未选中用半透明深底，保证任何封面上都看得清
*/
Item {
    id: root

    property bool checked: false
    /// 叠在图片/封面上时用半透明深底，放在纯背景上时可置 false 用白底
    property bool onMedia: true
    property color accentColor: AppTheme.colors.primary

    implicitWidth: 18
    implicitHeight: 18

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.checked
            ? root.accentColor
            : (root.onMedia ? Qt.rgba(0, 0, 0, 0.35) : AppTheme.colors.cardBg)
        border.width: 1.5
        border.color: root.checked ? root.accentColor : Qt.rgba(1, 1, 1, 0.9)

        AppIcon {
            anchors.centerIn: parent
            width: 11
            height: 11
            name: "check"
            color: AppTheme.colors.textOnPrimary
            strokeWidth: 2.6
            visible: root.checked
        }
    }
}
