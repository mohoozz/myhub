import SwiftUI
import UniformTypeIdentifiers

/// 连接源 添加/编辑 表单（IOS-101）：连接测试 + 内网/外网可达提示
struct ConnectionFormView: View {
    @ObservedObject var store: ConnectionStore
    let original: Connection
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var type: ConnectionType
    @State private var name: String
    @State private var enabled: Bool

    // WebDAV
    @State private var webdavBaseURL: String       // 外网地址
    @State private var webdavInternalURL: String   // 内网地址（可选，优先直连，不通回退外网）
    @State private var webdavRootPath: String
    @State private var webdavUsername: String
    // SMB
    @State private var smbHost: String
    @State private var smbShare: String
    @State private var smbUsername: String
    @State private var smbDomain: String
    @State private var smbGuest: Bool
    // 本地
    @State private var localBookmark: Data?
    @State private var localFolderName: String?
    @State private var pickingFolder = false
    // 凭据（编辑时回填已存密码；保存写 Keychain）
    @State private var password: String
    @State private var showPassword = false
    // 状态
    @State private var testing = false
    @State private var testResult: ConnectionTestState?
    @State private var errorMessage: String?

    init(store: ConnectionStore, connection: Connection, isNew: Bool) {
        self.store = store
        self.original = connection
        self.isNew = isNew
        _type = State(initialValue: connection.type)
        _name = State(initialValue: connection.name)
        _enabled = State(initialValue: connection.enabled)
        let webdav = connection.decodeConfig(WebDAVConfig.self)
        _webdavBaseURL = State(initialValue: webdav?.baseURL ?? "")
        _webdavInternalURL = State(initialValue: webdav?.internalBaseURL ?? "")
        _webdavRootPath = State(initialValue: webdav?.rootPath ?? "/")
        _webdavUsername = State(initialValue: webdav?.username ?? "")
        let smb = connection.decodeConfig(SMBConfig.self)
        _smbHost = State(initialValue: smb?.host ?? "")
        _smbShare = State(initialValue: smb?.share ?? "")
        _smbUsername = State(initialValue: smb?.username ?? "")
        _smbDomain = State(initialValue: smb?.domain ?? "")
        _smbGuest = State(initialValue: smb?.guest ?? false)
        let local = connection.decodeConfig(LocalConfig.self)
        _localBookmark = State(initialValue: local?.bookmarkData)
        _localFolderName = State(initialValue: local?.bookmarkData != nil ? "已选择共享文件夹" : nil)
        // 编辑时回填 Keychain 中已保存的密码
        let savedPassword: String? = isNew ? nil : connection.id.flatMap { store.loadPassword(for: $0) }
        _password = State(initialValue: savedPassword ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("类型", selection: $type) {
                        ForEach(ConnectionType.supportedCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.symbol).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isNew)   // 编辑时不允许换类型（避免凭据/配置错位）
                }

                Section("基本信息") {
                    TextField("名称（如：家里 NAS）", text: $name)
                    if !isNew {
                        Toggle("启用", isOn: $enabled)
                    }
                }

                switch type {
                case .local: localSection
                case .webdav: webdavSection
                case .smb: smbSection
                case .ftp, .sftp, .nfs: EmptyView()
                }

                testSection
            }
            .navigationTitle(isNew ? "添加连接源" : "编辑连接源")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    localBookmark = try? url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    localFolderName = url.lastPathComponent
                }
            }
        }
    }

    // MARK: - 分类型配置区

    private var localSection: some View {
        Section("本地目录") {
            LabeledContent("目录", value: localFolderName ?? "应用沙盒 Documents")
            Button("选择「文件」App 文件夹…") { pickingFolder = true }
            if localBookmark != nil {
                Button("恢复为沙盒 Documents", role: .destructive) {
                    localBookmark = nil
                    localFolderName = nil
                }
            }
        }
    }

    private var webdavSection: some View {
        Group {
            Section {
                TextField("外网地址（https://host:port）", text: $webdavBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("内网地址（可选，https://192.168.x.x）", text: $webdavInternalURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("根路径（如 /dav，默认 /）", text: $webdavRootPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("WebDAV 服务器")
            } footer: {
                Text("填写内网地址后，App 会优先连接内网，不通时自动切换到外网。")
            }
            Section("凭据") {
                TextField("用户名（可空为匿名）", text: $webdavUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                passwordField
            }
        }
    }

    private var smbSection: some View {
        Group {
            Section("SMB 服务器") {
                TextField("服务器（如 192.168.1.10）", text: $smbHost)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("共享名", text: $smbShare)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("凭据") {
                Toggle("访客访问", isOn: $smbGuest)
                if !smbGuest {
                    TextField("用户名", text: $smbUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    passwordField
                    TextField("域 / 工作组（可空）", text: $smbDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    // MARK: - 密码输入（带明文切换）

    private var passwordField: some View {
        HStack {
            Group {
                if showPassword {
                    TextField(isNew ? "密码" : "密码（留空则不修改）", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(isNew ? "密码" : "密码（留空则不修改）", text: $password)
                }
            }
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Text("连接测试")
                    if testing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(testing || !isValid)

            if let testResult {
                switch testResult {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            do {
                let adapter = try AdapterFactory.makeAdapter(
                    for: previewConnection(),
                    passwordOverride: password.isEmpty ? nil : password
                )
                try await adapter.testConnection()
                let route = (adapter as? RoutedWebDAVAdapter)?.activeRoute
                testResult = .success(message: ConnectionStore.reachabilityMessage(
                    for: previewConnection(),
                    activeRoute: route
                ))
            } catch {
                testResult = .failure(message: error.localizedDescription)
            }
            testing = false
        }
    }

    // MARK: - 保存

    private var isValid: Bool {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch type {
        case .local:
            return true
        case .webdav:
            let external = webdavBaseURL.trimmingCharacters(in: .whitespaces)
            guard !external.isEmpty else { return false }
            // 内网地址可选；填写时须为合法的 http/https 地址
            let internalURL = webdavInternalURL.trimmingCharacters(in: .whitespaces)
            if internalURL.isEmpty { return true }
            guard let url = URL(string: internalURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return false }
            return true
        case .smb:
            return !smbHost.isEmpty && !smbShare.isEmpty && (smbGuest || !smbUsername.isEmpty)
        case .ftp, .sftp, .nfs:
            return false
        }
    }

    private func save() {
        var connection = previewConnection()
        connection.createdAt = isNew ? Date() : original.createdAt
        do {
            try store.save(&connection, password: password.isEmpty ? nil : password)
            // 编辑已有连接且做过连接测试时，把最新结果同步到列表绿/红点（避免红点残留到重启）
            if let id = original.id, let testResult {
                store.applyTestResult(testResult, for: id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func previewConnection() -> Connection {
        var connection = original
        connection.name = name.trimmingCharacters(in: .whitespaces)
        connection.type = type
        // 挂载点直接用名称，不再拼接前缀或做规范化
        connection.mountPoint = name.trimmingCharacters(in: .whitespaces)
        connection.enabled = isNew ? true : enabled
        connection.configJSON = buildConfigJSON()
        return connection
    }

    private func buildConfigJSON() -> String {
        switch type {
        case .local:
            return Connection.makeConfigJSON(LocalConfig(path: nil, bookmarkData: localBookmark))
        case .webdav:
            let internalURL = webdavInternalURL.trimmingCharacters(in: .whitespaces)
            return Connection.makeConfigJSON(WebDAVConfig(
                baseURL: webdavBaseURL.trimmingCharacters(in: .whitespaces),
                username: webdavUsername.trimmingCharacters(in: .whitespaces),
                rootPath: webdavRootPath.isEmpty ? "/" : webdavRootPath,
                internalBaseURL: internalURL.isEmpty ? nil : internalURL
            ))
        case .smb:
            return Connection.makeConfigJSON(SMBConfig(
                host: smbHost.trimmingCharacters(in: .whitespaces),
                share: smbShare.trimmingCharacters(in: .whitespaces),
                username: smbGuest ? nil : smbUsername,
                domain: smbDomain.isEmpty ? nil : smbDomain,
                guest: smbGuest
            ))
        case .ftp, .sftp, .nfs:
            return "{}"
        }
    }
}
