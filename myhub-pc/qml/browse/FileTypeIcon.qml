import QtQuick
import MyHub

/*
  文件 / 目录类型图标（§14.3）。

  纪律：类型图标与目录图标**去白底、放大**，仅用图标展示
  （网格与列表均调整）。故这里不加任何背景容器。
*/
Item {
    id: root

    property string mediaKind: "file"
    property bool isDir: false
    /// 图标相对控件尺寸的占比（「放大」要求：占满而非缩在角落）
    property real iconRatio: 0.82

    readonly property string _iconName: {
        if (isDir)
            return "folder"
        switch (mediaKind) {
        case "video":  return "film"
        case "audio":  return "music"
        case "novel":  return "book-open"
        case "comic":  return "comic"
        case "image":  return "image"
        case "text":   return "file-text"
        case "folder": return "folder"
        default:       return "file-text"
        }
    }

    readonly property color _iconColor: {
        if (isDir)
            return AppTheme.colors.primary
        switch (mediaKind) {
        case "video":
        case "audio":
            return AppTheme.colors.primary
        default:
            return AppTheme.colors.textSecondary
        }
    }

    AppIcon {
        anchors.centerIn: parent
        name: root._iconName
        width: Math.round(Math.min(root.width, root.height) * root.iconRatio)
        height: width
        color: root._iconColor
        strokeWidth: 1.5
    }
}
