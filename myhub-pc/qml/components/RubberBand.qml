import QtQuick
import MyHub

/*
  框选（rubber band，§3.1 多选）。

  为什么挂在 contentItem 里、而且 z 比委托低：
    · 做在视图上层的遮罩会吃掉委托的单击/双击/右键 —— 那才是首页最常用的操作
    · 放在视图外面（同级 Item）根本收不到按下事件：Flickable 自己就把左键吃掉用于拖动
    · 挂在 contentItem、置于委托下方，则「点在卡片上」归委托，「点在空白处」才开始框选；
      代价是空白处拖拽不再滚列表（滚轮照常），这是桌面文件管理器的通行取舍

  纪律：
    · 拖动小于阈值不算框选（当作「点了空白」→ 清空选择），避免手抖清掉选择
    · 命中判定用 `view.itemAtIndex()`，只算已创建的可见委托，不猜网格几何
    · 行号集合有变化才发信号，拖动时不会每帧刷一遍所有委托
*/
Item {
    id: root

    /// 目标视图（GridView / ListView）；用 var 是因为 Flickable 基类没有 itemAtIndex/count
    required property var view
    /// 边框与填充用的强调色
    property color accentColor: AppTheme.colors.primary
    /// 拖动阈值（px）
    property int dragThreshold: 4

    /// 拖动过程中命中行号有变化（rows 为空表示没框到任何条目）
    signal bandChanged(var rows)
    /// 松开鼠标：rows 为最终命中行号（空数组 = 点了空白，调用方应清空选择）
    signal bandFinished(var rows)

    parent: root.view ? root.view.contentItem : null
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    z: -1
    visible: root.view !== null && root.view !== undefined

    Rectangle {
        id: band
        visible: false
        color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.12)
        border.width: AppTheme.borderWidth
        border.color: root.accentColor
        radius: AppTheme.radiusSmall
        antialiasing: true
    }

    MouseArea {
        id: area
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton

        property point origin
        property point current
        property bool dragging: false
        /// 上一次发出去的命中集合，用于「变了才发」
        property string emitted: ""

        function hitRows(x, y, w, h) {
            const rows = []
            const view = root.view
            if (!view || typeof view.itemAtIndex !== "function")
                return rows
            const count = view.count
            for (let i = 0; i < count; ++i) {
                const item = view.itemAtIndex(i)
                if (!item || !item.visible)
                    continue
                if (item.x < x + w && item.x + item.width > x
                        && item.y < y + h && item.y + item.height > y)
                    rows.push(i)
            }
            return rows
        }

        function updateBand(force) {
            const x = Math.min(origin.x, current.x)
            const y = Math.min(origin.y, current.y)
            const w = Math.abs(current.x - origin.x)
            const h = Math.abs(current.y - origin.y)
            band.x = x
            band.y = y
            band.width = w
            band.height = h
            band.visible = dragging

            const rows = dragging ? hitRows(x, y, w, h) : []
            const key = rows.join(",")
            if (force || key !== emitted) {
                emitted = key
                root.bandChanged(rows)
            }
        }

        onPressed: function(mouse) {
            origin = Qt.point(mouse.x, mouse.y)
            current = origin
            dragging = false
            emitted = ""
            mouse.accepted = true
        }

        onPositionChanged: function(mouse) {
            if (!pressed)
                return
            current = Qt.point(mouse.x, mouse.y)
            if (!dragging) {
                if (Math.max(Math.abs(current.x - origin.x), Math.abs(current.y - origin.y))
                        < root.dragThreshold)
                    return
                dragging = true
                updateBand(true) // 跨过阈值立刻反馈，不用等下一个 move
                return
            }
            updateBand(false)
        }

        onReleased: {
            const rows = dragging
                ? hitRows(band.x, band.y, band.width, band.height) : []
            dragging = false
            band.visible = false
            emitted = ""
            root.bandFinished(rows)
        }

        onCanceled: {
            dragging = false
            band.visible = false
            emitted = ""
        }
    }
}
