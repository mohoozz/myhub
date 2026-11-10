import QtQuick
import QtQuick.Shapes
import MyHub

/*
  环形进度（PC-209）。

  纪律：饼状图 + 下方百分比文案，两者间距适中；
  轨道用统一描边色，进度用主色，**不得引入其它色相**（§2.10）。
  已读完时 progress = 1，文案由调用方换成「已看完 / 已听完 / 已读完」。
*/
Item {
    id: root

    /// 0~1
    property real progress: 0
    property color trackColor: AppTheme.colors.separator
    property color indicatorColor: AppTheme.colors.primary
    property real strokeWidth: 3.2

    implicitWidth: 30
    implicitHeight: 30

    readonly property real _clamped: Math.max(0, Math.min(1, progress))

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: root.width > 0 && root.height > 0

        // 轨道
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.trackColor
            strokeWidth: root.strokeWidth

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.width / 2 - root.strokeWidth / 2
                radiusY: root.height / 2 - root.strokeWidth / 2
                startAngle: -90
                sweepAngle: 360
            }
        }

        // 进度弧（0 时隐藏，避免出现一个圆点）
        ShapePath {
            fillColor: "transparent"
            strokeColor: root._clamped > 0.002 ? root.indicatorColor : "transparent"
            strokeWidth: root.strokeWidth
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.width / 2 - root.strokeWidth / 2
                radiusY: root.height / 2 - root.strokeWidth / 2
                startAngle: -90
                sweepAngle: 360 * root._clamped
            }
        }
    }
}
