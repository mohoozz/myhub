import QtQuick
import MyHub

// 委托/子组件访问外层 id 需要 Bound 上下文（见 §14 的 qmllint 约定）
pragma ComponentBehavior: Bound

/*
  浏览模块容器（§3.1）。

  两个层级：连接源选择页 ↔ 目录页。
  **重复点击「浏览」导航回连接源选择页**（§14.5）。
*/
Item {
    id: root

    // 连接源选择页
    Item {
        id: connectionPage
        anchors.fill: parent
        visible: !BrowseController.inDirectory

        Text {
            id: pageTitle
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: AppTheme.spacingXl
            text: qsTr("选择连接源")
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTitle
            font.bold: true
            color: AppTheme.colors.textPrimary
        }

        ConnectionListModel {
            id: enabledConnections
            enabledOnly: true
        }

        ListView {
            id: connectionList
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: pageTitle.bottom
            anchors.bottom: parent.bottom
            anchors.leftMargin: AppTheme.spacingXl
            anchors.rightMargin: AppTheme.spacingXl
            anchors.topMargin: AppTheme.spacingLg
            anchors.bottomMargin: AppTheme.spacingXl
            spacing: AppTheme.spacingMd
            clip: true
            model: enabledConnections

            // 卡片自有属性与模型角色同名，委托根用中间 Item 接收角色，再显式转发（避免自绑定成环）
            delegate: Item {
                id: cardCell
                required property int index
                required property string connectionId
                required property string name
                required property string type
                required property string typeDisplay
                required property string mountPoint
                required property string summary
                required property var reachable
                required property bool testing
                required property string statusText

                width: connectionList.width
                height: card.implicitHeight

                ConnectionCard {
                    id: card
                    anchors.fill: parent
                    name: cardCell.name
                    typeName: cardCell.type
                    typeDisplay: cardCell.typeDisplay
                    mountPoint: cardCell.mountPoint
                    summary: cardCell.summary
                    reachable: cardCell.reachable
                    testing: cardCell.testing
                    statusText: cardCell.statusText

                    onClicked: BrowseController.openConnection(cardCell.connectionId)
                }
            }

            // 空态：引导去设置添加连接源
            EmptyState {
                anchors.fill: parent
                visible: enabledConnections.count === 0
                iconName: "database"
                title: qsTr("还没有连接源")
                description: qsTr("添加 WebDAV、SMB 或本地目录后即可开始浏览文件。")
                actionText: qsTr("去添加")
                onActionTriggered: AppRouter.select(AppRouter.Settings)
            }
        }
    }

    // 目录页
    BrowseDirectory {
        id: directoryPage
        anchors.fill: parent
        visible: BrowseController.inDirectory
        connectionId: BrowseController.connectionId
    }

    // 重复点击「浏览」→ 回连接源选择页
    Connections {
        target: AppRouter
        function onReselected(module) {
            if (module === AppRouter.Browse)
                BrowseController.backToConnections()
        }
    }

    // 控制器请求导航（进入连接源时恢复上次路径）
    Connections {
        target: BrowseController
        function onNavigationRequested(connectionId, path) {
            directoryPage.navigateTo(connectionId, path)
        }
    }
}
