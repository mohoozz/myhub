import QtQuick
import MyHub

/*
  阅读器专用按钮。

  为什么不复用 `ToolbarButton`：阅读器的配色由**纸色主题**决定（日间/夜间/护眼），
  跟 AppTheme 的中性色不是同一套；把前景色/悬停底色做成属性传入，
  按钮就能落在任何阅读底色上而不用为每种主题写一遍。
*/
Rectangle {
    id: btn

    property string icon: ""
    property string label: ""
    /// 图标与文字的颜色（由调用方按纸色主题给）
    property color fg: "#000000"
    property color hoverFill: Qt.rgba(0, 0, 0, 0.06)

    signal clicked()

    implicitWidth: label.length > 0 ? Math.max(content.implicitWidth + 24, 40) : 36
    implicitHeight: 36

    radius: AppTheme.radiusSmall
    color: btn.enabled && (hover.hovered || tap.pressed) ? btn.hoverFill : "transparent"
    opacity: btn.enabled ? 1 : 0.32

    Behavior on color {
        ColorAnimation { duration: Motion.fast }
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: AppTheme.spacingSm

        AppIcon {
            visible: btn.icon.length > 0
            width: 18
            height: 18
            name: btn.icon
            color: btn.fg
        }

        Text {
            visible: btn.label.length > 0
            text: btn.label
            color: btn.fg
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeBody
        }
    }

    HoverHandler {
        id: hover
        enabled: btn.enabled
    }

    TapHandler {
        id: tap
        enabled: btn.enabled
        onTapped: btn.clicked()
    }
}
