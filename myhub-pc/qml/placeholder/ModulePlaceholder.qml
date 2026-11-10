import QtQuick
import MyHub

/*
  尚未实现模块的占位页。
  明确标注所属里程碑，避免被误认为功能缺陷。
*/
Item {
    id: root

    property string iconName: "inbox"
    property string title: ""
    property string description: ""

    Rectangle {
        anchors.fill: parent
        color: AppTheme.colors.pageBg
    }

    EmptyState {
        anchors.fill: parent
        iconName: root.iconName
        title: root.title
        description: root.description
    }
}
