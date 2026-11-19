pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  阅读器偏好（§10）。

  纪律：
    - 所有控件直接绑 `Novel.*` / `Comic.*` 的落键属性，不另存一份镜像：
      阅读器里拖滑块与设置页拖滑块是同一份偏好，任一入口改动都要即时反映到另一处
      （跨入口同步由 C++ 侧监听 `AppSettings::settingChanged` 完成）
    - 预览必须与正文同源：纸色/墨色抄 `NovelReaderView` 的那套映射，
      否则设置页看着满意、进阅读器又是另一种观感
    - 亮度是「这块屏幕」的偏好，小说与漫画共用 `reader.brightness`，
      负值是「跟随系统 / 不压蒙层」的哨兵值，不能简单当作 0 显示
*/
Item {
    id: root

    /// 与正文一致的纸色 / 墨色（跟随系统时按外壳明暗取日间或夜间）
    readonly property int palette: Novel.theme === 0 ? (AppTheme.dark ? 2 : 1) : Novel.theme
    readonly property color paper: palette === 2 ? "#141517" : palette === 3 ? "#CFE3D0" : "#F6F1E4"
    readonly property color ink: palette === 2 ? "#BFC3CB" : palette === 3 ? "#2C3A2E" : "#2A2721"
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    readonly property color rule: Qt.rgba(ink.r, ink.g, ink.b, 0.12)

    readonly property bool followSystemBrightness: Novel.brightness < 0
    readonly property real brightnessPercent:
        Math.round((Novel.brightness < 0 ? 1.0 : Novel.brightness) * 100)

    function setBrightness(percent) {
        // 负值是哨兵，别让滑块把 -1 当 0% 写回去
        Novel.brightness = Math.round(Math.max(0.2, Math.min(1.0, percent)) * 100) / 100
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
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("阅读器偏好")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeHeading
                    font.bold: true
                    color: AppTheme.colors.textPrimary
                }

                Text {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    text: qsTr("改动即时生效，与阅读器内调整的是同一份偏好。")
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeTiny
                    color: AppTheme.colors.textFaint
                }
            }

            // ---------------- 小说排版 ----------------
            Rectangle {
                width: parent.width
                height: novelCard.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Column {
                    id: novelCard
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingLg

                    Text {
                        text: qsTr("小说排版")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        font.bold: true
                        color: AppTheme.colors.textPrimary
                    }

                    // 字号
                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("字号：%1 px").arg(Novel.fontSize)
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        C.Slider {
                            width: Math.min(parent.width, 320)
                            from: 12
                            to: 32
                            stepSize: 1
                            snapMode: C.Slider.SnapAlways
                            value: Novel.fontSize
                            onMoved: Novel.fontSize = value
                        }
                    }

                    // 行距
                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("行距：%1 倍").arg(Novel.lineSpacing.toFixed(1))
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        C.Slider {
                            width: Math.min(parent.width, 320)
                            from: 1.2
                            to: 2.4
                            stepSize: 0.1
                            snapMode: C.Slider.SnapAlways
                            // 滑块值会跳小数：先四舍五入到 0.1，避免 1.7000000000000002
                            value: Math.round(Novel.lineSpacing * 10) / 10
                            onMoved: Novel.lineSpacing = Math.round(value * 10) / 10
                        }
                    }

                    // 正文字体
                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("正文字体")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        Text {
                            text: qsTr("黑体适合屏幕扫读，宋体更适合长文细读；缺字时按字体链逐级回落。")
                            width: parent.width
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTiny
                            color: AppTheme.colors.textFaint
                            wrapMode: Text.Wrap
                        }

                        Row {
                            spacing: AppTheme.spacingSm

                            PrimaryButton {
                                text: qsTr("黑体")
                                variant: Novel.fontStyle === 0
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Novel.fontStyle = 0
                            }
                            PrimaryButton {
                                text: qsTr("宋体")
                                variant: Novel.fontStyle === 1
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Novel.fontStyle = 1
                            }
                        }
                    }

                    // 排版方式
                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("排版方式")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        Text {
                            text: qsTr("翻页按行切页，页边界只会落在整行之间；滚动是连续列表，长短章节都顺。")
                            width: parent.width
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTiny
                            color: AppTheme.colors.textFaint
                            wrapMode: Text.Wrap
                        }

                        Row {
                            spacing: AppTheme.spacingSm

                            PrimaryButton {
                                text: qsTr("滚动")
                                variant: !Novel.pageMode
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Novel.pageMode = false
                            }
                            PrimaryButton {
                                text: qsTr("翻页")
                                variant: Novel.pageMode
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Novel.pageMode = true
                            }
                        }
                    }

                    // 主题
                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("阅读主题")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        Text {
                            text: qsTr("与外壳主题独立：正文底色属于「内容」，不跟着应用换肤走。")
                            width: parent.width
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTiny
                            color: AppTheme.colors.textFaint
                            wrapMode: Text.Wrap
                        }

                        Row {
                            spacing: AppTheme.spacingSm

                            Repeater {
                                model: [
                                    { theme: 0, label: qsTr("跟随系统") },
                                    { theme: 1, label: qsTr("日间") },
                                    { theme: 2, label: qsTr("夜间") },
                                    { theme: 3, label: qsTr("护眼") }
                                ]

                                delegate: PrimaryButton {
                                    required property var modelData
                                    text: modelData.label
                                    variant: Novel.theme === modelData.theme
                                        ? PrimaryButton.Primary : PrimaryButton.Secondary
                                    onClicked: Novel.theme = modelData.theme
                                }
                            }
                        }
                    }
                }
            }

            // ---------------- 预览 ----------------
            Rectangle {
                width: parent.width
                height: preview.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: root.paper
                border.width: AppTheme.borderWidth
                border.color: root.rule

                Column {
                    id: preview
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingMd

                    Text {
                        width: parent.width
                        text: qsTr("第一章 · 预览")
                        color: root.ink
                        wrapMode: Text.Wrap
                        // 与阅读器正文同源：换字体先在这里看出来
                        font.family: Novel.fontFamilies
                        font.pixelSize: Math.round(Novel.fontSize * 1.32)
                        font.weight: Font.DemiBold
                    }

                    Rectangle {
                        width: 36
                        height: 2
                        color: root.rule
                    }

                    Text {
                        width: parent.width
                        text: qsTr("山海之间有一条旧路。雨天走上去，青石会泛出细碎的光，"
                                   + "像是有人把星星碾碎了铺在脚下。")
                        color: root.ink
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        font.family: Novel.fontFamilies
                        font.pixelSize: Novel.fontSize
                        lineHeight: Novel.lineSpacing
                        lineHeightMode: Text.ProportionalHeight
                    }

                    Text {
                        width: parent.width
                        text: qsTr("字号、行距、字体、主题都会直接反映在这段文字上——所见即阅读页所得。")
                        color: root.inkSoft
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        font.family: Novel.fontFamilies
                        font.pixelSize: Novel.fontSize
                        lineHeight: Novel.lineSpacing
                        lineHeightMode: Text.ProportionalHeight
                    }
                }
            }

            // ---------------- 漫画阅读 ----------------
            Rectangle {
                width: parent.width
                height: comicCard.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Column {
                    id: comicCard
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingLg

                    Text {
                        text: qsTr("漫画阅读")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        font.bold: true
                        color: AppTheme.colors.textPrimary
                    }

                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("默认阅读模式")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        Row {
                            spacing: AppTheme.spacingSm

                            Repeater {
                                model: [
                                    { mode: 0, label: qsTr("单页") },
                                    { mode: 1, label: qsTr("双页") },
                                    { mode: 2, label: qsTr("条漫") }
                                ]

                                delegate: PrimaryButton {
                                    required property var modelData
                                    text: modelData.label
                                    variant: Comic.mode === modelData.mode
                                        ? PrimaryButton.Primary : PrimaryButton.Secondary
                                    onClicked: Comic.mode = modelData.mode
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: AppTheme.spacingXs

                        Text {
                            text: qsTr("双页翻页方向")
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeBody
                            color: AppTheme.colors.textPrimary
                        }

                        Text {
                            text: qsTr("只在双页模式下有意义：日漫从右向左，美漫/国漫/条漫多从左向右。"
                                       + "「自动」按书名（假名、巻/話、条漫/webtoon）判定，判不出时用右到左。")
                            width: parent.width
                            font.family: AppTheme.fontFamily
                            font.pixelSize: AppTheme.fontSizeTiny
                            color: AppTheme.colors.textFaint
                            wrapMode: Text.Wrap
                        }

                        Row {
                            spacing: AppTheme.spacingSm

                            PrimaryButton {
                                text: qsTr("自动")
                                enabled: Comic.mode === 1
                                variant: Comic.direction < 0 && Comic.mode === 1
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Comic.direction = -1
                            }
                            PrimaryButton {
                                text: qsTr("从左到右")
                                enabled: Comic.mode === 1
                                variant: Comic.direction === 0 && Comic.mode === 1
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Comic.direction = 0
                            }
                            PrimaryButton {
                                text: qsTr("从右到左")
                                enabled: Comic.mode === 1
                                variant: Comic.direction === 1 && Comic.mode === 1
                                    ? PrimaryButton.Primary : PrimaryButton.Secondary
                                onClicked: Comic.direction = 1
                            }
                        }
                    }
                }
            }

            // ---------------- 亮度（小说 + 漫画共用）----------------
            Rectangle {
                width: parent.width
                height: brightnessCard.implicitHeight + AppTheme.spacingLg * 2
                radius: AppTheme.radiusCard
                color: AppTheme.colors.cardBg
                border.width: AppTheme.borderWidth
                border.color: AppTheme.colors.cardBorder

                Column {
                    id: brightnessCard
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: AppTheme.spacingLg
                    spacing: AppTheme.spacingSm

                    Text {
                        text: qsTr("阅读亮度")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeBody
                        font.bold: true
                        color: AppTheme.colors.textPrimary
                    }

                    Text {
                        width: parent.width
                        text: qsTr("小说与漫画共用同一个亮度；「跟随系统」时不叠加蒙层。")
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeTiny
                        color: AppTheme.colors.textFaint
                        wrapMode: Text.Wrap
                    }

                    Row {
                        spacing: AppTheme.spacingSm

                        PrimaryButton {
                            text: qsTr("跟随系统")
                            variant: root.followSystemBrightness
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: Novel.brightness = -1
                        }
                        PrimaryButton {
                            text: qsTr("手动调节")
                            variant: !root.followSystemBrightness
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: {
                                if (root.followSystemBrightness)
                                    root.setBrightness(1.0)
                            }
                        }
                    }

                    C.Slider {
                        width: Math.min(parent.width, 320)
                        visible: !root.followSystemBrightness
                        from: 0.2
                        to: 1.0
                        stepSize: 0.05
                        snapMode: C.Slider.SnapAlways
                        value: root.brightnessPercent / 100
                        onMoved: root.setBrightness(value)
                    }

                    Text {
                        text: root.followSystemBrightness
                            ? qsTr("当前：跟随系统")
                            : qsTr("当前：%1%").arg(root.brightnessPercent)
                        font.family: AppTheme.fontFamily
                        font.pixelSize: AppTheme.fontSizeSmall
                        color: AppTheme.colors.textSecondary
                    }
                }
            }

            Item { width: 1; height: AppTheme.spacingXs }
        }
    }
}
