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

/// 连接测试结果本地快照（UserDefaults 缓存，避免每次进入列表页重复检查内外网）
private struct PersistedTestState: Codable {
    var isSuccess: Bool
    var message: String
}

private let testStateCacheKey = "connectionTestStates.v1"

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
        saveCachedState(state, for: connectionID)
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
        clearCachedState(for: id)
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
        // 配置变更后旧测试结果失效：清除缓存，首次展示时自动重测一次
        if connection.id != nil, let id = connection.id {
            testStates[id] = nil
            clearCachedState(for: id)
        }
        reloadAndNotify()
    }

    /// 读取已保存凭据密码（编辑表单回填用）；无则返回 nil
    func loadPassword(for connectionID: Int64) -> String? {
        try? credentials.loadPassword(for: connectionID)
    }

    // MARK: - 连接测试

    /// 列表出现时自动测试：仅在从未测试过（内存与本地缓存均无结果）时自动测试一次；
    /// 已有结果（成功/失败/测试中）直接复用；重新检查只由用户手动触发（点击状态点 / 表单测试）
    func testIfNeeded(_ connection: Connection) async {
        guard let id = connection.id, connection.enabled else { return }
        switch testStates[id] {
        case .success, .testing, .failure:
            return
        case .none, .unknown:
            if let cached = loadCachedState(for: id) {
                testStates[id] = cached
                return
            }
            await test(connection)
        }
    }

    /// App 启动时对全部已启用连接源探测一次内外网路由（TODO 324）：
    /// 结果同时写入 UI 测试缓存与 `RoutedWebDAVAdapter` 的进程级路由锁定。
    /// 之后所有操作一直使用锁定地址，只有用户手动「测试连接」或重启 App 才会重新判定。
    func probeOnLaunch() async {
        reload()
        await withTaskGroup(of: Void.self) { group in
            for connection in connections where connection.enabled {
                group.addTask { await self.test(connection) }
            }
        }
    }

    func test(_ connection: Connection) async {
        guard let id = connection.id else { return }
        testStates[id] = .testing
        do {
            let adapter = try AdapterFactory.makeAdapter(for: connection)
            try await adapter.testConnection()
            let route = (adapter as? RoutedWebDAVAdapter)?.activeRoute
            let state = ConnectionTestState.success(message: Self.reachabilityMessage(for: connection, activeRoute: route))
            testStates[id] = state
            saveCachedState(state, for: id)
        } catch {
            let state = ConnectionTestState.failure(message: error.localizedDescription)
            testStates[id] = state
            saveCachedState(state, for: id)
        }
    }

    // MARK: - 测试结果缓存（UserDefaults，避免每次进入列表重复检查）

    /// 读取本地缓存的测试结果；无则 nil
    private func loadCachedState(for id: Int64) -> ConnectionTestState? {
        guard let data = UserDefaults.standard.data(forKey: testStateCacheKey),
              let dict = try? JSONDecoder().decode([String: PersistedTestState].self, from: data),
              let item = dict[String(id)] else { return nil }
        return item.isSuccess
            ? .success(message: item.message)
            : .failure(message: item.message)
    }

    private func saveCachedState(_ state: ConnectionTestState, for id: Int64) {
        var dict = cachedTestStateDict()
        switch state {
        case .success(let message):
            dict[String(id)] = PersistedTestState(isSuccess: true, message: message)
        case .failure(let message):
            dict[String(id)] = PersistedTestState(isSuccess: false, message: message)
        case .testing, .unknown:
            return
        }
        persistTestStateDict(dict)
    }

    private func clearCachedState(for id: Int64) {
        var dict = cachedTestStateDict()
        guard dict.removeValue(forKey: String(id)) != nil else { return }
        persistTestStateDict(dict)
    }

    private func cachedTestStateDict() -> [String: PersistedTestState] {
        guard let data = UserDefaults.standard.data(forKey: testStateCacheKey),
              let dict = try? JSONDecoder().decode([String: PersistedTestState].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistTestStateDict(_ dict: [String: PersistedTestState]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: testStateCacheKey)
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
