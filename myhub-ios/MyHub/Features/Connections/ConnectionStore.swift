import Foundation
import GRDB

/// 连接测试结果（列表绿/红点 + 表单内外网提示）
enum ConnectionTestState: Equatable {
    case unknown
    case testing
    case success(message: String)
    case failure(message: String)
}

extension ConnectionTestState {
    /// 列表绿点旁的路径标签：（内网）/（外网）；仅成功态且含路径提示时返回
    var routeBadge: String? {
        guard case .success(let message) = self else { return nil }
        if message.contains("内网") { return "（内网）" }
        if message.contains("外网") { return "（外网）" }
        return nil
    }
}

@MainActor
final class ConnectionStore: ObservableObject {
    /// 连接源数据变更广播：设置页新增/编辑/删除/启停后，浏览页等其它实例自动刷新（无需重启 App）
    static let didChangeNotification = Notification.Name("ConnectionDidChange")

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var testStates: [Int64: ConnectionTestState] = [:]

    private let database: AppDatabase
    private let credentials = CredentialStore()
    private var changeObserver: NSObjectProtocol?

    init(database: AppDatabase = .shared) {
        self.database = database
        changeObserver = NotificationCenter.default.addObserver(
            forName: Self.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func reload() {
        guard let db = database.dbQueue else { return }
        connections = (try? db.read {
            try Connection.order(Column("createdAt")).fetchAll($0)
        }) ?? []
    }

    /// 数据变更后：刷新自身并广播，让其它实例（浏览页等）同步刷新
    private func reloadAndNotify() {
        reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 将表单「连接测试」的结果同步到指定连接，供列表绿/红点即时刷新（无需重启 App）
    func applyTestResult(_ state: ConnectionTestState, for connectionID: Int64) {
        testStates[connectionID] = state
    }

    func setEnabled(_ connection: Connection, _ enabled: Bool) {
        guard let db = database.dbQueue, connection.id != nil else { return }
        var item = connection
        item.enabled = enabled
        try? db.write { try item.update($0) }
        reloadAndNotify()
    }

    func delete(_ connection: Connection) {
        guard let db = database.dbQueue, let id = connection.id else { return }
        _ = try? db.write { try connection.delete($0) }
        credentials.deletePassword(for: id)
        testStates[id] = nil
        reloadAndNotify()
    }

    /// 新增/更新；password 非空时写入 Keychain（编辑留空则保持原密码）
    func save(_ connection: inout Connection, password: String?) throws {
        guard let db = database.dbQueue else { throw ConfigTransferError.databaseNotReady }
        try db.write { db in
            if connection.id == nil {
                try connection.insert(db)
            } else {
                try connection.update(db)
            }
        }
        if let id = connection.id, let password, !password.isEmpty {
            try credentials.savePassword(password, for: id)
        }
        reloadAndNotify()
    }

    /// 读取已保存凭据密码（编辑表单回填用）；无则返回 nil
    func loadPassword(for connectionID: Int64) -> String? {
        try? credentials.loadPassword(for: connectionID)
    }

    // MARK: - 连接测试

    /// 列表出现时自动测试：成功/测试中的不重测；未知或失败的重试，便于连接恢复后立即变绿
    func testIfNeeded(_ connection: Connection) async {
        guard let id = connection.id, connection.enabled else { return }
        switch testStates[id] {
        case .success, .testing: return
        case .unknown, .failure, .none: await test(connection)
        }
    }

    func test(_ connection: Connection) async {
        guard let id = connection.id else { return }
        testStates[id] = .testing
        do {
            let adapter = try AdapterFactory.makeAdapter(for: connection)
            try await adapter.testConnection()
            let route = (adapter as? RoutedWebDAVAdapter)?.activeRoute
            testStates[id] = .success(message: Self.reachabilityMessage(for: connection, activeRoute: route))
        } catch {
            testStates[id] = .failure(message: error.localizedDescription)
        }
    }

    /// 测试成功提示：区分内网 / 外网可达（IOS-101）
    static func reachabilityMessage(for connection: Connection, activeRoute: ConnectionRoute? = nil) -> String {
        switch connection.type {
        case .local:
            return "本地连接正常"
        case .smb:
            return "连接成功（内网可达）"   // SMB 面向局域网
        case .webdav:
            // 配置了内网地址时，以实际测试路由为准；否则按地址启发式判定
            if let activeRoute {
                return activeRoute == .internalNetwork
                    ? "连接成功（内网可达）"
                    : "连接成功（外网可达）"
            }
            let host = connection.decodeConfig(WebDAVConfig.self)
                .flatMap { URL(string: $0.baseURL)?.host } ?? ""
            return NetworkHeuristics.isPrivateHost(host)
                ? "连接成功（内网可达）"
                : "连接成功（外网可达）"
        case .ftp, .sftp, .nfs:
            return "连接成功"
        }
    }
}

/// 内网判定启发式：私有 IP / localhost / .local·.lan / 无点主机名
enum NetworkHeuristics {
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return false }
        if h == "localhost" { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".internal") { return true }
        if h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") { return true }   // IPv6 本地
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
            if parts[0] == 169 && parts[1] == 254 { return true }
            return false
        }
        // 非 IP 的无点主机名（NetBIOS / 局域网主机）
        return !h.contains(".") && !h.contains(":")
    }
}
