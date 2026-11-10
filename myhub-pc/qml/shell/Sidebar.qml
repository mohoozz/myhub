import QtQuick
import MyHub

// 导航项委托访问外层 id，绑定组件上下文（qmllint 约定）
pragma ComponentBehavior: Bound

/*
  左侧侧边栏（§2.2.1）。

  导航项：阅读 / 收藏 / 动态 / 浏览 / 浏览器 / 设置
  底部常驻：头像入口（点击直达个人主页，§14.4）
*/
Rectangle {
    id: root

    property bool collapsed: false

    signal avatarClicked()

    color: AppTheme.colors.sidebarBg

    // 右侧统一描边分隔（不用分割线元素，保持描边色统一）
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: AppTheme.borderWidth
        color: AppTheme.colors.cardBorder
    }

    Column {
        id: navColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: AppTheme.spacingMd
        spacing: 2

        Repeater {
            model: [
                { icon: "book",     label: qsTr("阅读"),   module: AppRouter.Reading },
                { icon: "star",     label: qsTr("收藏"),   module: AppRouter.Favorites },
                { icon: "zap",      label: qsTr("动态"),   module: AppRouter.Feed },
                { icon: "folder",   label: qsTr("浏览"),   module: AppRouter.Browse },
                { icon: "globe",    label: qsTr("浏览器"), module: AppRouter.Browser },
                { icon: "settings", label: qsTr("设置"),   module: AppRouter.Settings }
            ]

            delegate: SidebarItem {
                required property var modelData

                width: navColumn.width
                iconName: modelData.icon
                label: modelData.label
                collapsed: root.collapsed
                selected: AppRouter.currentModule === modelData.module

                // select() 内部处理「重复点击回起始页」
                onClicked: AppRouter.select(modelData.module)
            }
        }
    }

    // 底部头像入口
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: AppTheme.spacingSm
        height: 48

        Rectangle {
            anchors.fill: parent
            radius: AppTheme.radiusInput + 2
            color: avatarMouse.containsMouse ? AppTheme.colors.hoverFill : "transparent"
            Behavior on color { ColorAnimation { duration: Motion.fast } }

            Rectangle {
                id: avatar
                width: 28
                height: 28
                radius: width / 2
                color: AppTheme.colors.primary
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: root.collapsed
                    ? (parent.width - width) / 2
                    : AppTheme.spacingSm

                Behavior on anchors.leftMargin {
                    NumberAnimation { duration: Motion.normal }
                }

                AppIcon {
                    anchors.centerIn: parent
                    name: "user"
                    width: 15
                    height: 15
                    color: AppTheme.colors.textOnPrimary
                }
            }

            Text {
                anchors.left: avatar.right
                anchors.leftMargin: AppTheme.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.collapsed
                text: qsTr("我的")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: AppTheme.colors.textPrimary
            }
        }

        MouseArea {
            id: avatarMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.avatarClicked()
        }
    }
}
