import QtQuick
import MyHub

/*
  「浮起抬升」选中 / hover 效果（§1.2 / §14.3）。

  纪律：选中态必须是「内缩圆角高亮 + 轻微放大 + 主色软阴影 + 1pt 细描边」，
  填充 ≤ 8%，**不得出现贴边直角色块**。

  用法：作为列表行 / 网格卡片的背景层，由统一组件渲染，
  各页面不得各写一套（§14.3）。
*/
Item {
    id: root

    property bool hovered: false
    property bool selected: false
    property bool pressed: false
    /// 列表行内缩成悬浮片；网格卡片沿自身圆角
    property real inset: 4
    property real radius: AppTheme.radiusCard

    // 选中时轻微放大（配合阴影形成「抬升」观感）
    scale: pressed ? AppTheme.pressScale : (selected ? 1.012 : 1.0)
    Behavior on scale {
        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut }
    }

    // 主色软阴影（抬升感来源）
    Rectangle {
        id: shadow
        anchors.fill: highlight
        anchors.topMargin: 2
        radius: highlight.radius
        color: "transparent"
        border.width: 0
        opacity: root.selected ? 1.0 : 0.0
        visible: opacity > 0

        // 用多层半透明矩形模拟软阴影，避免引入 GraphicalEffects 依赖
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: parent.radius + 3
            color: "transparent"
            border.color: Qt.rgba(AppTheme.colors.shadowLift.r,
                                  AppTheme.colors.shadowLift.g,
                                  AppTheme.colors.shadowLift.b, 0.10)
            border.width: 3
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            radius: parent.radius + 1
            color: "transparent"
            border.color: Qt.rgba(AppTheme.colors.shadowLift.r,
                                  AppTheme.colors.shadowLift.g,
                                  AppTheme.colors.shadowLift.b, 0.16)
            border.width: 2
        }

        Behavior on opacity {
            NumberAnimation { duration: Motion.fast }
        }
    }

    // 高亮层：内缩圆角，填充不超过 8%
    Rectangle {
        id: highlight
        anchors.fill: parent
        anchors.margins: root.inset
        radius: root.radius

        color: {
            if (root.selected)
                return AppTheme.colors.primaryWeak          // 8%
            if (root.hovered)
                return AppTheme.colors.hoverFill
            return "transparent"
        }

        // 选中时 1pt 细描边
        border.width: root.selected ? AppTheme.borderWidth : 0
        border.color: AppTheme.colors.primary

        Behavior on color {
            ColorAnimation { duration: Motion.fast }
        }
    }
}
