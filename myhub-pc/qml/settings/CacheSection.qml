pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  缓存与存储（§10 / PC-504 / PC-605）。

  纪律：
    - 分区表与配额只在 `CachePartitions` 定义，这里只展示，不写死目录名
    - 占用统计与清空都在后台线程（`CacheBridge`），UI 不阻塞、不假死
    - 清理**必须二次确认**；正在播放的分片 / 正在下载的 `.part` 由保护集兜住，
      点「清理」不会把正在看的视频删掉，提示里要说清楚
    - 改上限即时生效：`AppSettings.cacheTotalLimitMB` → `CacheCleaner` 换配额并收口
*/
Item {
    id: root

    /// 由设置页驱动：切到本分区时才扫盘（避免每次进设置都读一遍缓存目录）
    property bool active: false

    /// 待清理的分区（空串 = 全部）
    property string pendingDir: ""
    property string pendingLabel: ""
    property string notice: ""

    function formatSize(bytes) {
        if (!bytes || bytes <= 0)
            return qsTr("0 B")
        const units = ["B", "KB", "MB", "GB", "TB"]
        let value = bytes
        let unit = 0
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024
            ++unit
        }
        const digits = unit === 0 ? 0 : (value >= 100 ? 0 : (value >= 10 ? 1 : 2))
        return value.toFixed(digits) + " " + units[unit]
    }

    onActiveChanged: {
        if (active) {
            notice = ""
            Cache.refresh()
        }
    }

    Connections {
        target: Cache

        function onCleared(label, removedFiles, removedBytes) {
            root.notice = qsTr("已清理%1：删除 %2 个文件，释放 %3")
                    .arg(label).arg(removedFiles).arg(root.formatSize(removedBytes))
        }
    }

    C.ScrollView {
        anchors.fill: parent
        anchors.margins: AppTheme.spacingXl
        clip: true
        contentWidth: availableWidth

        Column {
            width: parent.width
            spacing: AppTheme.spacingLg

            // ---------------- 标题 ----------------
            Item {
                width: parent.width
                height: 40

                Text {
                    id: title
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("缓存与存储")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeHeading
                    font.bold: true
                    color: AppTheme.colors.textPrimary
                }

                Text {
                    anchors.left: title.right
                    anchors.leftMargin: AppTheme.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    text: Cache.loading ? qsTr("正在统计…") : root.notice
                    visible: text !== ""
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeSmall
                    color: AppTheme.colors.textFaint
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: AppTheme.spacingSm

                    PrimaryButton {
                        text: qsTr("刷新")
                        iconName: "refresh"
                        variant: PrimaryButton.Secondary
                        enabled: !Cache.loading && !Cache.clearing
                        onClicked: {
                            root.notice = ""
                            Cache.refresh()
                        }
                    }

                    PrimaryButton {
                        text: qsTr("全部清理")
                        iconName: "trash"
                        variant: PrimaryButton.Secondary
                        destructive: true
                        enabled: Cache.totalFiles > 0 && !Cache.clearing
                        onClicked: {
                            root.pendingDir = ""
                            root.pendingLabel = qsTr("全部")
                            clearDialog.open()
                        }
                    }
                }
            }

            // ---------------- 总览 ----------------
            Rectangle {
                width: parent.width
                height: overview.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Column {
                    id: overview
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingSm

                    Text {
                        width: parent.width
                        text: qsTr("已用 %1 / 上限 %2")
                                .arg(root.formatSize(Cache.totalBytes))
                                .arg(root.formatSize(Cache.totalLimitBytes))
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }

                    // 占用条：统一主色，超 90% 转警示色（不按分区配色）
                    Rectangle {
                        id: totalTrack
                        width: parent.width
                        height: 8
                        radius: 4
                        color: AppTheme.colors.hoverFill

                        Rectangle {
                            width: totalTrack.width
                                   * (Cache.totalLimitBytes > 0
                                      ? Math.min(1.0, Cache.totalBytes / Cache.totalLimitBytes)
                                      : 0)
                            height: parent.height
                            radius: parent.radius
                            color: Cache.totalLimitBytes > 0
                                   && Cache.totalBytes > Cache.totalLimitBytes * 0.9
                                   ? AppTheme.colors.danger : AppTheme.colors.primary
                        }
                    }

                    Text {
                        width: parent.width
                        text: qsTr("超出上限时按 mtime 做 LRU 淘汰（先分区配额、再全局兜底）；"
                                   + "正在播放的分片与正在下载的文件不会被删。")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }

                    Item { width: 1; height: AppTheme.spacingXs }

                    Text {
                        text: qsTr("缓存总容量上限：%1 MB").arg(AppSettings.cacheTotalLimitMB)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }

                    C.Slider {
                        width: Math.min(parent.width, 320)
                        from: 128
                        to: 8192
                        stepSize: 128
                        snapMode: C.Slider.SnapAlways
                        value: AppSettings.cacheTotalLimitMB
                        onMoved: AppSettings.cacheTotalLimitMB = value
                    }
                }
            }

            // ---------------- 内容缓存本地化 ----------------
            Rectangle {
                width: parent.width
                height: localization.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Column {
                    id: localization
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("内容缓存本地化")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        color: AppTheme.colors.textPrimary
                    }

                    Text {
                        width: parent.width
                        text: qsTr("关闭后不再预缓存漫画页与目录列表（纯加速用途）；"
                                   + "正在阅读/播放所需的页与分片仍会写入，以保证功能可用。")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }

                    Row {
                        spacing: AppTheme.spacingSm

                        PrimaryButton {
                            text: qsTr("关闭")
                            variant: !AppSettings.contentCachingEnabled
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.contentCachingEnabled = false
                        }
                        PrimaryButton {
                            text: qsTr("开启")
                            variant: AppSettings.contentCachingEnabled
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: AppSettings.contentCachingEnabled = true
                        }
                    }
                }
            }

            // ---------------- 分区占用 ----------------
            Text {
                text: qsTr("分区占用")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                font.bold: true
                color: AppTheme.colors.textPrimary
            }

            Column {
                id: partitionList
                width: parent.width
                spacing: AppTheme.spacingSm

                Repeater {
                    model: Cache.partitions

                    delegate: Rectangle {
                        id: row

                        required property var modelData

                        width: partitionList.width
                        height: 64
                        radius: AppTheme.radiusInput
                        color: AppTheme.colors.cardBg
                        border.width: AppTheme.borderWidth
                        border.color: AppTheme.colors.cardBorder

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: AppTheme.spacingMd
                            anchors.verticalCenter: parent.verticalCenter
                            width: 170
                            spacing: 3

                            Text {
                                width: parent.width
                                text: row.modelData.label
                                elide: Text.ElideRight
                                font.family: AppTheme.fontFamily
                                font.pixelSize: AppTheme.fontSizeBody
                                color: AppTheme.colors.textPrimary
                            }

                            Text {
                                width: parent.width
                                text: row.modelData.dir
                                elide: Text.ElideMiddle
                                font.family: AppTheme.fontFamily
                                font.pixelSize: AppTheme.fontSizeTiny
                                color: AppTheme.colors.textFaint
                            }
                        }

                        Item {
                            id: barArea
                            anchors.left: parent.left
                            anchors.leftMargin: 170 + AppTheme.spacingMd * 2
                            anchors.right: info.left
                            anchors.rightMargin: AppTheme.spacingMd
                            anchors.verticalCenter: parent.verticalCenter
                            height: 8

                            Rectangle {
                                id: track
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                height: 6
                                radius: 3
                                color: AppTheme.colors.hoverFill

                                Rectangle {
                                    width: track.width * row.modelData.ratio
                                    height: parent.height
                                    radius: parent.radius
                                    // 占用越大越不透明：单色 + 透明度梯度，不搞多色区分
                                    color: AppTheme.colors.primary
                                    opacity: 0.45 + 0.55 * row.modelData.ratio
                                }
                            }
                        }

                        Column {
                            id: info
                            anchors.right: action.left
                            anchors.rightMargin: AppTheme.spacingMd
                            anchors.verticalCenter: parent.verticalCenter
                            width: 110

                            Text {
                                width: parent.width
                                text: root.formatSize(row.modelData.bytes)
                                horizontalAlignment: Text.AlignRight
                                font.family: AppTheme.fontFamily
                                font.pixelSize: AppTheme.fontSizeSmall
                                color: AppTheme.colors.textSecondary
                            }

                            Text {
                                width: parent.width
                                text: row.modelData.selfManaged
                                      ? qsTr("由播放器按播放点管理")
                                      : qsTr("%1 个文件 · 配额 %2")
                                        .arg(row.modelData.files)
                                        .arg(root.formatSize(row.modelData.limitBytes))
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                                font.family: AppTheme.fontFamily
                                font.pixelSize: AppTheme.fontSizeTiny
                                color: AppTheme.colors.textFaint
                            }
                        }

                        PrimaryButton {
                            id: action
                            anchors.right: parent.right
                            anchors.rightMargin: AppTheme.spacingMd
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("清理")
                            iconName: "trash"
                            variant: PrimaryButton.Secondary
                            destructive: true
                            enabled: row.modelData.files > 0 && !Cache.clearing
                            onClicked: {
                                root.pendingDir = row.modelData.dir
                                root.pendingLabel = row.modelData.label
                                clearDialog.open()
                            }
                        }
                    }
                }
            }

            Text {
                width: parent.width
                visible: !Cache.loading && Cache.partitions.length === 0
                text: qsTr("分区目录还没建出来：首次写入缓存后才会出现在这里。")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textFaint
                wrapMode: Text.Wrap
            }

            // ---------------- 目录 ----------------
            Rectangle {
                width: parent.width
                height: dirRow.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Item {
                    id: dirRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    implicitHeight: cacheButton.implicitHeight

                    Text {
                        anchors.left: parent.left
                        anchors.right: dataButton.left
                        anchors.rightMargin: AppTheme.spacingSm
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("缓存目录只存可重建的副本，清掉不影响内容源。")
                        elide: Text.ElideRight
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeSmall
                        color: AppTheme.colors.textSecondary
                    }

                    PrimaryButton {
                        id: cacheButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("打开缓存目录")
                        iconName: "folder-open"
                        variant: PrimaryButton.Secondary
                        onClicked: WindowController.openCacheFolder()
                    }

                    PrimaryButton {
                        id: dataButton
                        anchors.right: cacheButton.left
                        anchors.rightMargin: AppTheme.spacingSm
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("打开数据目录")
                        iconName: "folder-open"
                        variant: PrimaryButton.Secondary
                        onClicked: WindowController.openDataFolder()
                    }
                }
            }

            Item { width: 1; height: AppTheme.spacingXs }
        }
    }

    // 清理确认（单项 / 全部共用）
    ConfirmDialog {
        id: clearDialog
        title: root.pendingDir === "" ? qsTr("清理全部缓存") : qsTr("清理分区缓存")
        message: root.pendingDir === ""
                 ? qsTr("将删除全部缓存文件（%1）。下次打开需要重新加载，"
                        + "正在播放的分片与正在下载的文件会保留。")
                   .arg(root.formatSize(Cache.totalBytes))
                 : qsTr("将清理「%1」分区的缓存，下次打开需要重新加载。")
                   .arg(root.pendingLabel)
        confirmText: qsTr("清理")
        destructive: true
        onAccepted: {
            root.notice = ""
            if (root.pendingDir === "")
                Cache.clearAll()
            else
                Cache.clearPartition(root.pendingDir)
        }
    }
}
