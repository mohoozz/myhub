import QtQuick
import QtQuick.Shapes
import MyHub

/*
  线形图标渲染器。

  用 Qt Quick Shapes 渲染 Icons.qml 中的 SVG path，
  颜色可动态绑定（等价于原型中的 currentColor）。

  实现要点：多段 path 拼接为单个 PathSvg（SVG 的 M 指令天然支持多子路径），
  整体通过 Scale 变换从 24x24 视图框映射到控件尺寸，
  描边宽度随之等比缩放，与 SVG 行为一致。
*/
Item {
    id: root

    property string name: ""
    property color color: AppTheme.colors.textPrimary
    property real strokeWidth: 1.8
    /// 实心图标（如 play）只填充不描边
    property bool filled: false

    implicitWidth: 20
    implicitHeight: 20

    readonly property real _scale: width / Icons.viewBox

    readonly property string _pathData: {
        const segments = Icons.paths[name]
        if (segments === undefined)
            return ""
        return segments.join(" ")
    }

    Shape {
        id: shape
        anchors.fill: parent
        visible: root._pathData !== ""
        preferredRendererType: Shape.CurveRenderer

        transform: Scale {
            xScale: root._scale
            yScale: root._scale
        }

        ShapePath {
            strokeColor: root.filled ? "transparent" : root.color
            fillColor: root.filled ? root.color : "transparent"
            strokeWidth: root.strokeWidth
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            fillRule: ShapePath.WindingFill

            PathSvg { path: root._pathData }
        }
    }
}
