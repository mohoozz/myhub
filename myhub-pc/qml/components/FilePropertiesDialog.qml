import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

pragma ComponentBehavior: Bound

/*
  文件属性面板（PC-110）。

  纪律：
    · 大小 / 修改时间必须**现场 stat**（`Files.requestProperties`），不拿目录缓存的行数据充数；
      条目已被删除时明确报错，而不是显示一份「看起来没问题」的旧值。
    · 阅读进度来自 `readingProgress` 表：没读过就显示「尚未阅读」，不伪造 0%。
    · 路径可一键复制；连接源已删除时如实标注，且不提供「定位」（定不过去）。
    · 复用的入口：浏览页右键「属性」、收藏页、正在阅读页。
*/
C.Dialog {
    id: control

    property string connectionId: ""
    property string filePath: ""
    /// 查询结果（字段见 FileOperations::inspect）
    property var info: ({})
    property bool loading: false
    property string errorText: ""
    /// 复制成功提示（短暂显示）
    property bool copied: false

    readonly property bool hasInfo: info !== null && Object.keys(info).length > 0
    readonly property bool available: hasInfo && info.connectionAvailable === true
    readonly property string requestKey: connectionId + "\n" + filePath

    /// 属性面板里的「定位」由页面接走（要切模块 + 滚动高亮，只有目录页能做）
    signal revealRequested(string connectionId, string path, bool isDir)

    /// 由 info 派生出的展示行：一处拼装，避免每个字段散落在布局里
    readonly property var rows: {
        const data = control.info
        if (!data || Object.keys(data).length === 0)
            return []
        const list = [
            { label: qsTr("名称"), value: data.name || "" },
            {
                label: qsTr("位置"),
                value: data.connectionAvailable
                    ? qsTr("%1 · %2").arg(data.connectionName).arg(data.connectionTypeName)
                    : qsTr("连接源已删除"),
                warn: !data.connectionAvailable
            },
            { label: qsTr("路径"), value: data.filePath || "", mono: true, wrap: true },
            { label: qsTr("类型"), value: data.mediaKindText || "" }
        ]
        if (!data.isDir) {
            list.push({ label: qsTr("大小"), value: data.sizeText || "" })
        }
        list.push({ label: qsTr("修改时间"), value: data.modTimeText || "" })
        // 只有能「接着读」的类型才提进度（普通文件显示「尚未阅读」是噪音）
        const progressKinds = ["video", "audio", "novel", "comic"]
        if (data.hasProgress) {
            list.push({
                label: qsTr("阅读进度"),
                value: data.finished
                    ? qsTr("%1 · 已看完").arg(data.progressText)
                    : data.progressText
            })
            if (data.lastReadText)
                list.push({ label: qsTr("上次阅读"), value: data.lastReadText })
        } else if (progressKinds.indexOf(data.mediaKind) >= 0) {
            list.push({ label: qsTr("阅读进度"), value: qsTr("尚未阅读") })
        }
        list.push({
            label: qsTr("收藏"),
            value: Favorites.revision >= 0 && Favorites.isFavorite(data.connectionId, data.filePath)
                ? qsTr("已收藏")
                : qsTr("未收藏")
        })
        return list
    }

    function openFor(connId, path) {
        control.connectionId = connId
        control.filePath = path
        control.info = ({})
        control.errorText = ""
        control.copied = false
        control.loading = true
        copiedTimer.stop()
        open()
        Files.requestProperties(connId, path)
    }

    function copyPath() {
        if (!control.hasInfo)
            return
        Files.copyToClipboard(control.info.filePath)
        control.copied = true
        copiedTimer.restart()
    }

    modal: true
    anchors.centerIn: C.Overlay.overlay
    width: 520
    // 行数决定高度（不用内容隐式高度，避免与 ScrollView 的可用宽高互锁成绑定环）
    height: Math.min(560, 150 + Math.max(1, control.rows.length) * 30)
    padding: 0
    header: null
    closePolicy: C.Popup.CloseOnEscape

    background: Rectangle {
        radius: AppTheme.radiusCard
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    C.Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.36)
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: Motion.fast
            }
            NumberAnimation {
                property: "scale"
                from: 0.97
                to: 1
                duration: Motion.normal
                easing.type: Motion.easeOut
            }
        }
    }
    exit: Transition {
        NumberAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: Motion.fast
        }
    }

    contentItem: Item {
        // ---------------- 头部 ----------------
        Item {
            id: headerBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 50

            AppIcon {
                id: headerIcon
                anchors.left: parent.left
                anchors.leftMargin: AppTheme.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                width: 17
                height: 17
                name: "info"
                color: AppTheme.colors.textSecondary
            }

            Text {
                anchors.left: headerIcon.right
                anchors.leftMargin: AppTheme.spacingSm
                anchors.right: parent.right
                anchors.rightMargin: AppTheme.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("属性")
                elide: Text.ElideRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeHeading
                font.bold: true
                color: AppTheme.colors.textPrimary
            }
        }

        Rectangle {
            id: headerDivider
            anchors.top: headerBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: AppTheme.borderWidth
            color: AppTheme.colors.separator
        }

        // ---------------- 正文 ----------------
        C.ScrollView {
            id: bodyArea
            anchors.top: headerDivider.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footerDivider.top
            clip: true
            C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
            contentWidth: availableWidth

            Column {
                id: contentColumn
                x: AppTheme.spacingLg
                width: bodyArea.availableWidth - AppTheme.spacingLg * 2
                topPadding: AppTheme.spacingLg
                bottomPadding: AppTheme.spacingLg
                spacing: AppTheme.spacingMd

                // 加载中
                Text {
                    visible: control.loading
                    text: qsTr("正在读取…")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeBody
                    color: AppTheme.colors.textSecondary
                }

                // 读取失败（条目多半已被删除）
                Text {
                    visible: !control.loading && control.errorText !== ""
                    width: parent.width
                    text: control.errorText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeBody
                    color: AppTheme.colors.danger
                }

                Repeater {
                    model: control.rows

                    delegate: Row {
                        id: rowItem

                        required property var modelData

                        width: contentColumn.width
                        spacing: AppTheme.spacingMd
                        visible: !control.loading && control.errorText === ""

                        Text {
                            width: 68
                            text: rowItem.modelData.label
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeSmall
                            color: AppTheme.colors.textFaint
                            topPadding: 1
                        }

                        Text {
                            width: rowItem.width - 68 - AppTheme.spacingMd
                            text: rowItem.modelData.value
                            textFormat: Text.PlainText
                            wrapMode: rowItem.modelData.wrap
                                ? Text.WrapAnywhere
                                : Text.WrapAtWordBoundaryOrAnywhere
                            maximumLineCount: rowItem.modelData.wrap ? 4 : 2
                            elide: Text.ElideRight
                            font.family: rowItem.modelData.mono
                                ? (Qt.platform.os === "osx"
                                    ? "Menlo, PingFang SC"
                                    : "Consolas, Microsoft YaHei UI")
                                : AppTheme.fontFamily
                            font.pixelSize: rowItem.modelData.mono
                                ? AppTheme.fontSizeSmall
                                : AppTheme.fontSizeBody
                            color: rowItem.modelData.warn
                                ? AppTheme.colors.danger
                                : AppTheme.colors.textPrimary
                        }
                    }
                }
            }
        }

        // ---------------- 底部 ----------------
        Item {
            id: footerBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 54

            Text {
                anchors.left: parent.left
                anchors.leftMargin: AppTheme.spacingLg
                anchors.right: footerButtons.left
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                text: control.copied ? qsTr("路径已复制") : ""
                elide: Text.ElideRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: AppTheme.colors.textSecondary
            }

            Row {
                id: footerButtons
                anchors.right: parent.right
                anchors.rightMargin: AppTheme.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                spacing: AppTheme.spacingSm

                PrimaryButton {
                    text: qsTr("复制路径")
                    variant: PrimaryButton.Text
                    enabled: control.hasInfo
                    onClicked: control.copyPath()
                }
                PrimaryButton {
                    text: qsTr("定位")
                    variant: PrimaryButton.Text
                    enabled: control.available
                    onClicked: {
                        control.revealRequested(control.connectionId, control.filePath,
                                                control.info.isDir === true)
                        control.close()
                    }
                }
                PrimaryButton {
                    text: qsTr("关闭")
                    variant: PrimaryButton.Primary
                    onClicked: control.close()
                }
            }
        }

        Rectangle {
            id: footerDivider
            anchors.bottom: footerBar.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: AppTheme.borderWidth
            color: AppTheme.colors.separator
        }
    }

    Timer {
        id: copiedTimer
        interval: 1600
        onTriggered: control.copied = false
    }

    Connections {
        target: Files

        function onPropertiesReady(info) {
            // 只接受本次请求的结果（面板可能已被关掉又打开到别的文件）
            if (info.connectionId !== control.connectionId || info.filePath !== control.filePath)
                return
            control.info = info
            control.errorText = ""
            control.loading = false
        }

        function onPropertiesFailed(connectionId, path, reason) {
            if (connectionId !== control.connectionId || path !== control.filePath)
                return
            control.errorText = reason
            control.loading = false
        }
    }
}
