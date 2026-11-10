import QtQuick
import QtQuick.Controls.Basic as C
import MyHub

// 表单内的重复区块要访问外层 id，绑定组件上下文（qmllint 约定）
pragma ComponentBehavior: Bound

/*
  连接源编辑表单（PC-501）。

  分类型表单：
    本地路径  path
    WebDAV   外网地址 + **内网地址（可选）** + 账号 + 密码 + 根路径 + 自签证书信任
    SMB      服务器 + 共享名 + 账号/访客 + 域

  纪律：表单未保存时「测试连接」用 passwordOverride，不污染已存凭据（§2.4）。
*/
Item {
    id: root

    /// 空字符串表示新建
    property string editingId: ""
    readonly property bool isNew: editingId === ""

    signal saved()
    signal cancelled()

    property string _type: "webdav"

    function loadFrom(data) {
        editingId = data.connectionId !== undefined ? data.connectionId : ""
        _type = data.type !== undefined ? data.type : "webdav"
        nameField.text = data.name !== undefined ? data.name : ""
        mountField.text = data.mountPoint !== undefined ? data.mountPoint : ""

        pathField.text = data.path !== undefined ? data.path : ""
        baseUrlField.text = data.baseURL !== undefined ? data.baseURL : ""
        internalUrlField.text = data.internalBaseURL !== undefined ? data.internalBaseURL : ""
        rootPathField.text = data.rootPath !== undefined ? data.rootPath : "/"
        insecureSwitch.checked = data.allowInsecureTLS === true

        hostField.text = data.host !== undefined ? data.host : ""
        shareField.text = data.share !== undefined ? data.share : ""
        domainField.text = data.domain !== undefined ? data.domain : ""
        guestSwitch.checked = data.guest === true

        usernameField.text = data.username !== undefined ? data.username : ""
        passwordField.text = ""   // 密码不回显（存于系统凭据库）
    }

    function resetForNew() {
        loadFrom({ type: "webdav", rootPath: "/" })
    }

    C.ScrollView {
        anchors.fill: parent
        anchors.margins: AppTheme.spacingXl
        contentWidth: availableWidth

        Column {
            width: parent.width
            spacing: AppTheme.spacingLg

            Text {
                text: root.isNew ? qsTr("添加连接源") : qsTr("编辑连接源")
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTitle
                font.bold: true
                color: AppTheme.colors.textPrimary
            }

            // ---- 类型选择 ----
            Column {
                width: parent.width
                spacing: AppTheme.spacingSm
                visible: root.isNew

                FieldLabel { text: qsTr("类型") }

                Row {
                    spacing: AppTheme.spacingSm

                    Repeater {
                        model: [
                            { id: "webdav", label: "WebDAV" },
                            { id: "smb",    label: "SMB" },
                            { id: "local",  label: qsTr("本地路径") }
                        ]
                        delegate: PrimaryButton {
                            required property var modelData
                            text: modelData.label
                            variant: root._type === modelData.id
                                ? PrimaryButton.Primary : PrimaryButton.Secondary
                            onClicked: root._type = modelData.id
                        }
                    }
                }
            }

            // ---- 通用字段 ----
            Column {
                width: parent.width
                spacing: AppTheme.spacingSm

                FieldLabel { text: qsTr("名称") }
                TextField {
                    id: nameField
                    width: parent.width
                    placeholderText: qsTr("例如：家里的 NAS")
                }
            }

            Column {
                width: parent.width
                spacing: AppTheme.spacingSm

                FieldLabel { text: qsTr("挂载点") }
                TextField {
                    id: mountField
                    width: parent.width
                    placeholderText: qsTr("留空则自动使用「/名称」")
                }
            }

            // ---- 本地路径 ----
            Column {
                width: parent.width
                spacing: AppTheme.spacingSm
                visible: root._type === "local"

                FieldLabel { text: qsTr("本地目录") }
                TextField {
                    id: pathField
                    width: parent.width
                    placeholderText: "D:/Media"
                }
            }

            // ---- WebDAV ----
            Column {
                width: parent.width
                spacing: AppTheme.spacingLg
                visible: root._type === "webdav"

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("服务器地址（外网）") }
                    TextField {
                        id: baseUrlField
                        width: parent.width
                        placeholderText: "https://dav.example.com"
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel {
                        text: qsTr("内网地址（可选）")
                        hint: qsTr("填写后启用内外网竞速：内网先发、外网 700ms 兜底，先成功者锁定")
                    }
                    TextField {
                        id: internalUrlField
                        width: parent.width
                        placeholderText: "http://192.168.1.10:5005"
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("根路径") }
                    TextField {
                        id: rootPathField
                        width: parent.width
                        placeholderText: "/"
                    }
                }

                SwitchRow {
                    id: insecureSwitch
                    width: parent.width
                    label: qsTr("信任自签证书")
                    hint: qsTr("仅在使用自签 HTTPS 证书的私有服务器上开启")
                }
            }

            // ---- SMB ----
            Column {
                width: parent.width
                spacing: AppTheme.spacingLg
                visible: root._type === "smb"

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("服务器地址") }
                    TextField {
                        id: hostField
                        width: parent.width
                        placeholderText: "192.168.1.10"
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("共享名") }
                    TextField {
                        id: shareField
                        width: parent.width
                        placeholderText: "Media"
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("域 / 工作组（可选）") }
                    TextField {
                        id: domainField
                        width: parent.width
                        placeholderText: "WORKGROUP"
                    }
                }

                SwitchRow {
                    id: guestSwitch
                    width: parent.width
                    label: qsTr("以访客身份连接")
                }
            }

            // ---- 账号密码（WebDAV / SMB 共用）----
            Column {
                width: parent.width
                spacing: AppTheme.spacingLg
                visible: root._type !== "local" && !guestSwitch.checked

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel { text: qsTr("账号") }
                    TextField {
                        id: usernameField
                        width: parent.width
                    }
                }

                Column {
                    width: parent.width
                    spacing: AppTheme.spacingSm
                    FieldLabel {
                        text: qsTr("密码")
                        hint: root.isNew ? "" : qsTr("留空表示不修改已保存的密码")
                    }
                    TextField {
                        id: passwordField
                        width: parent.width
                        echoMode: TextInput.Password
                    }
                }
            }

            Item { width: 1; height: AppTheme.spacingSm }

            // ---- 操作 ----
            Row {
                spacing: AppTheme.spacingSm

                PrimaryButton {
                    text: qsTr("保存")
                    iconName: "check"
                    enabled: nameField.text !== ""
                    onClicked: root._save()
                }
                PrimaryButton {
                    text: qsTr("测试连接")
                    variant: PrimaryButton.Secondary
                    enabled: nameField.text !== ""
                    onClicked: root._test()
                }
                PrimaryButton {
                    text: qsTr("取消")
                    variant: PrimaryButton.Text
                    onClicked: root.cancelled()
                }
            }
        }
    }

    // 构造配置对象
    function _buildConfig() {
        switch (_type) {
        case "local":
            return { path: pathField.text }
        case "webdav":
            return {
                baseURL: baseUrlField.text,
                internalBaseURL: internalUrlField.text,
                username: usernameField.text,
                rootPath: rootPathField.text === "" ? "/" : rootPathField.text,
                allowInsecureTLS: insecureSwitch.checked
            }
        case "smb":
            return {
                host: hostField.text,
                share: shareField.text,
                username: usernameField.text,
                domain: domainField.text,
                guest: guestSwitch.checked
            }
        }
        return ({})
    }

    function _save() {
        const id = ConnectionStore.upsertFromQml(
            editingId, nameField.text, _type, _buildConfig(),
            mountField.text, true, passwordField.text)
        if (id !== "")
            root.saved()
    }

    function _test() {
        // 先保存再测试，保证测试的是最新配置（testConnection 会清锁重判）
        const id = ConnectionStore.upsertFromQml(
            editingId, nameField.text, _type, _buildConfig(),
            mountField.text, true, passwordField.text)
        if (id !== "") {
            editingId = id
            ConnectionStore.testConnection(id, passwordField.text)
        }
    }

    // ---- 内联小组件 ----
    component FieldLabel: Column {
        property string text: ""
        property string hint: ""
        spacing: 2

        Text {
            text: parent.text
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeSmall
            font.bold: true
            color: AppTheme.colors.textPrimary
        }
        Text {
            text: parent.hint
            visible: text !== ""
            width: parent.parent ? parent.parent.width : implicitWidth
            font.family: AppTheme.fontFamily
            font.pixelSize: AppTheme.fontSizeTiny
            color: AppTheme.colors.textFaint
            wrapMode: Text.Wrap
        }
    }

    component SwitchRow: Item {
        property string label: ""
        property string hint: ""
        property bool checked: false

        implicitHeight: 44

        Column {
            anchors.left: parent.left
            anchors.right: toggle.left
            anchors.rightMargin: AppTheme.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: parent.parent.label
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeBody
                color: AppTheme.colors.textPrimary
            }
            Text {
                text: parent.parent.hint
                visible: text !== ""
                width: parent.width
                font.family: AppTheme.fontFamily
                font.pixelSize: AppTheme.fontSizeTiny
                color: AppTheme.colors.textFaint
                wrapMode: Text.Wrap
            }
        }

        C.Switch {
            id: toggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: parent.checked
            onToggled: parent.checked = checked
        }
    }
}
