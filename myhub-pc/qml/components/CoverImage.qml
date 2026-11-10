import QtQuick
import MyHub

/*
  统一封面（PC-702）—— 浏览页与「正在阅读」共用同一个组件、同一份磁盘缓存。

  纪律：
    · **占位先行**：同步查缓存命中就直接显示，未命中先画类型图标占位，异步结果由信号补上
    · **失败也是占位**：不出现破图/空白，失败后 30s 内不再重试（冷却在 C++ 侧）
    · 封面加载**绝不阻塞**点击进入播放 / 阅读
    · 目录、纯文本等无封面对象直接显示类型图标，不发请求
*/
Item {
    id: root

    property string connectionId: ""
    property string filePath: ""
    property string mediaKind: "file"
    property bool isDir: false
    /// 文件指纹（未知传 -1）：仅用于校验磁盘缓存是否过期
    property real fileSize: -1
    property real fileModSecs: -1
    /// 封面圆角；置 0 表示直角
    property real radius: AppTheme.radiusInput
    /// true = 铺满裁切（网格卡片）/ false = 完整显示（列表缩略图）
    property bool cropFill: true
    property real iconRatio: 0.82

    readonly property bool hasCover: coverImage.status === Image.Ready
    readonly property string _key: (connectionId === "" || filePath === "")
                                     ? "" : CoverService.coverKey(connectionId, filePath)
    property bool _pending: false

    function reload() {
        root._pending = false
        coverImage.source = ""
        if (root.isDir || root._key === "")
            return
        const cached = CoverService.cachedCover(root.connectionId, root.filePath)
        if (cached !== "") {
            coverImage.source = cached
            return
        }
        root._pending = true
        CoverService.requestCover(root.connectionId, root.filePath, root.fileSize, root.fileModSecs)
    }

    onConnectionIdChanged: reload()
    onFilePathChanged: reload()
    Component.onCompleted: reload()

    Connections {
        target: CoverService

        function onCoverReady(key, url) {
            if (root._pending && key === root._key) {
                root._pending = false
                coverImage.source = url
            }
        }

        function onCoverFailed(key) {
            if (root._pending && key === root._key)
                root._pending = false
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: AppTheme.colors.fieldFill
        clip: true

        Image {
            id: coverImage
            anchors.fill: parent
            visible: root.hasCover
            asynchronous: true
            cache: true
            smooth: true
            fillMode: root.cropFill ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        }

        FileTypeIcon {
            anchors.fill: parent
            visible: !root.hasCover
            mediaKind: root.mediaKind
            isDir: root.isDir
            iconRatio: root.iconRatio
        }
    }
}
