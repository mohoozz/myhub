import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

/*
  纯文本在线编辑（PC-103 的「txt 在线修改并保存回源」）。

  纪律：
    · **编码沿用原文**：打开时检测出的编码原样回写；原编码表示不了新字符时
      由 core 回退 UTF-8，这里只负责把「已回退」如实告诉用户（不静默丢字）。
    · 体积上限 8MB 由 core 拦截，本页不截断内容。
    · 关闭前有未保存修改必须二次确认。
*/
C.Dialog {
    id: control

    property string connectionId: ""
    property string filePath: ""
    property string fileName: ""
    /// 只读查看：不支持预览的文件「以纯文本查看」走这条（不提供保存，绝不回写源文件）
    property bool readOnly: false

    /// loading → editing → saving → editing
    property string status: "loading"
    /// 打开时检测出的编码（保存时原样回写）
    property string encodingName: "UTF-8"
    property bool hadBom: false
    /// 编辑器当前内容是否与已落盘内容不同
    property bool dirty: false
    /// 打开/保存后的一次性提示（编码说明、回退说明）
    property string saveHint: ""
    /// 最近一次保存是否因原编码不可表示而回退 UTF-8
    property bool saveFellBack: false

    /// 内容已成功写回源，页面据此刷新该行大小等元信息
    signal saved(string connectionId, string path)

    readonly property bool loading: status === "loading"
    readonly property bool saving: status === "saving"
    readonly property string textFont: Qt.platform.os === "osx"
                                          ? "Menlo, PingFang SC"
                                          : "Consolas, Microsoft YaHei UI"

    function openFor(connectionId, path, name, readOnly) {
        control.connectionId = connectionId
        control.filePath = path
        const fallbackName = path.substring(path.lastIndexOf("/") + 1)
        control.fileName = (name !== undefined && name !== "") ? name : fallbackName
        control.readOnly = readOnly === true
        control.status = "loading"
        control.encodingName = "UTF-8"
        control.hadBom = false
        control.dirty = false
        control.saveHint = ""
        control.saveFellBack = false
        loadedText = ""
        editor.text = ""
        editor.readOnly = control.readOnly
        open()
        Files.loadText(connectionId, path)
    }

    /// 当前编辑器内容是否已是落盘内容（用于脏判定）
    property string loadedText: ""

    function requestSave() {
        if (control.readOnly || control.status !== "editing" || !control.dirty)
            return
        control.status = "saving"
        control.saveHint = ""
        Files.saveText(control.connectionId, control.filePath, editor.text,
                       control.encodingName, control.hadBom)
    }

    function requestClose() {
        if (control.saving)
            return
        if (control.dirty)
            discardDialog.open()
        else
            close()
    }

    modal: true
    anchors.centerIn: C.Overlay.overlay
    width: Math.min(900, (parent ? parent.width : 900) - 96)
    height: Math.min(680, (parent ? parent.height : 680) - 96)
    padding: 0
    header: null
    closePolicy: C.Popup.NoAutoClose

    background: Rectangle {
        radius: AppTheme.radiusCard
        color: AppTheme.colors.cardBg
        border.width: AppTheme.borderWidth
        border.color: AppTheme.colors.cardBorder
    }

    C.Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.42)
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.fast }
            NumberAnimation { property: "scale"; from: 0.97; to: 1
                              duration: Motion.normal; easing.type: Motion.easeOut }
        }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Motion.fast }
    }

    contentItem: Item {
        // 快捷键挂在 contentItem（有 window 的 Item）上，Popup 自身不是 Item
        Shortcut {
            sequences: [StandardKey.Save]
            enabled: control.visible && !control.readOnly
                     && control.status === "editing" && control.dirty
            onActivated: control.requestSave()
        }
        Shortcut {
            sequences: [StandardKey.Cancel, "Esc"]
            enabled: control.visible && !control.saving
            onActivated: control.requestClose()
        }

        // ---------------- 头部 ----------------
        Item {
            id: headerBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 54

            AppIcon {
                id: headerIcon
                anchors.left: parent.left
                anchors.leftMargin: AppTheme.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                name: "file-text"
                width: 18
                height: 18
                color: AppTheme.colors.textSecondary
            }

            Text {
                id: nameText
                anchors.left: headerIcon.right
                anchors.leftMargin: AppTheme.spacingSm
                anchors.right: encodingChip.left
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                text: control.fileName
                elide: Text.ElideMiddle
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeHeading
                font.bold: true
                color: AppTheme.colors.textPrimary
            }

            // 编码徽标：让用户在保存前就知道会按什么编码回写
            Rectangle {
                id: encodingChip
                anchors.right: closeButton.left
                anchors.rightMargin: AppTheme.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                width: encodingText.implicitWidth + AppTheme.spacingMd * 2
                height: 22
                radius: height / 2
                color: AppTheme.colors.fieldFill

                Text {
                    id: encodingText
                    anchors.centerIn: parent
                    text: control.encodingName
                    font.family: AppTheme.fontFamily
                    font.pixelSize: AppTheme.fontSizeTiny
                    color: AppTheme.colors.textSecondary
                }
            }

            // 未保存标记
            Rectangle {
                anchors.right: encodingChip.left
                anchors.rightMargin: AppTheme.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                visible: control.dirty
                width: 7
                height: 7
                radius: 3.5
                color: AppTheme.colors.primary
            }

            ToolbarButton {
                id: closeButton
                anchors.right: parent.right
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                iconName: "x"
                tooltip: qsTr("关闭")
                onClicked: control.requestClose()
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

        // ---------------- 底部 ----------------
        Item {
            id: footerBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 58

            Text {
                anchors.left: parent.left
                anchors.leftMargin: AppTheme.spacingLg
                anchors.right: footerButtons.left
                anchors.rightMargin: AppTheme.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                text: control.saveHint
                elide: Text.ElideRight
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeSmall
                color: control.saveFellBack ? AppTheme.colors.textSecondary
                                            : AppTheme.colors.textFaint
            }

            Row {
                id: footerButtons
                anchors.right: parent.right
                anchors.rightMargin: AppTheme.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                spacing: AppTheme.spacingSm

                PrimaryButton {
                    text: qsTr("关闭")
                    variant: PrimaryButton.Text
                    onClicked: control.requestClose()
                }
                PrimaryButton {
                    text: control.saving ? qsTr("保存中…") : qsTr("保存")
                    variant: PrimaryButton.Primary
                    visible: !control.readOnly
                    enabled: !control.saving && !control.loading && control.dirty
                    onClicked: control.requestSave()
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

        // ---------------- 正文 ----------------
        Item {
            id: bodyArea
            anchors.top: headerDivider.bottom
            anchors.bottom: footerDivider.top
            anchors.left: parent.left
            anchors.right: parent.right

            C.ScrollView {
                anchors.fill: parent
                anchors.margins: AppTheme.spacingMd
                visible: !control.loading
                clip: true

                C.TextArea {
                    id: editor
                    wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                    selectByMouse: true
                    persistentSelection: true
                    font.family: control.textFont
                    font.pixelSize: 13
                    color: AppTheme.colors.textPrimary
                    padding: AppTheme.spacingMd
                    background: Rectangle {
                        color: AppTheme.colors.fieldFill
                        radius: AppTheme.radiusInput
                    }
                    // 只拦截 Tab（缩进），其余按键交给默认处理
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Tab && !control.readOnly) {
                            editor.insert("\t")
                            event.accepted = true
                        }
                    }
                    onTextChanged: control.dirty = !control.readOnly
                                                  && (text !== control.loadedText)
                }
            }

            Text {
                anchors.centerIn: parent
                visible: control.loading
                text: qsTr("正在读取…")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: AppTheme.colors.textSecondary
            }
        }
    }

    // 关闭确认（有未保存修改时）
    ConfirmDialog {
        id: discardDialog
        title: qsTr("放弃未保存的修改？")
        message: qsTr("「%1」有尚未保存的修改，关闭后将丢失。").arg(control.fileName)
        confirmText: qsTr("放弃修改")
        cancelText: qsTr("继续编辑")
        destructive: true
        onAccepted: control.close()
    }

    // core 回传：读取完成
    Connections {
        target: Files
        function onTextLoaded(connectionId, path, text, encoding, hadBom) {
            if (!control.visible || connectionId !== control.connectionId
                    || path !== control.filePath)
                return
            control.encodingName = encoding
            control.hadBom = hadBom
            control.loadedText = text
            editor.text = text
            editor.readOnly = control.readOnly
            control.dirty = false
            control.status = "editing"
            control.saveFellBack = false
            control.saveHint = control.readOnly
                ? qsTr("共 %1 字符 · 只读查看（按 %2 解码，不会改动源文件）")
                      .arg(text.length).arg(encoding)
                : qsTr("共 %1 字符 · 按 %2 保存").arg(text.length).arg(encoding)
        }

        function onTextSaved(connectionId, path, fellBack, encoding) {
            if (!control.visible || connectionId !== control.connectionId
                    || path !== control.filePath)
                return
            control.status = "editing"
            control.encodingName = encoding
            control.hadBom = control.hadBom && encoding === "UTF-8"
            control.loadedText = editor.text
            control.dirty = false
            control.saveFellBack = fellBack
            control.saveHint = fellBack
                ? qsTr("原编码无法表示新内容，已回退为 UTF-8 保存")
                : qsTr("已保存（%1）").arg(encoding)
            control.saved(connectionId, path)
        }

        // 失败弹窗由页面统一展示；这里只把自身状态收回到可用状态
        function onFailed(title, reason) {
            if (!control.visible)
                return
            if (control.status === "loading")
                control.close()
            else if (control.status === "saving")
                control.status = "editing"
        }
    }
}
