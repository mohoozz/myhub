import Darwin
import Foundation
import Network

/// 本地 HTTP 代理（IOS-203 边下边播，参考 nPlayer 缓存架构）。
/// 127.0.0.1 回环 HTTP 服务：将解码器（AVPlayer / VLC 双引擎通用）的 HTTP Range 请求
/// 转为 CachedRangeReader 分片读取——缓存命中直出，未命中走 WebDAV Range / SMB 分块并写盘预读。
/// 拖动进度条时解码器发起目标区间 Range 请求，实现秒开与快速 seek。
final class LocalStreamProxy {
    static let shared = LocalStreamProxy()
    static let pathPrefix = "/stream/"

    private struct Session {
        let reader: CachedRangeReader
        let contentType: String
    }

    private let listenerQueue = DispatchQueue(label: "myhub.streamproxy.listener")
    private let connectionQueue = DispatchQueue(label: "myhub.streamproxy.conn", attributes: .concurrent)
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// 监听是否已就绪（.ready）：长时间后台（熄屏）后监听可能进入 waiting/failed，
    /// 端口不再可用且此前只有重启 App 才能恢复（TODO 366）；
    /// 作为健康标记，register / recoverIfNeeded 据此判断是否重建
    private var listenerReady = false
    private let lock = NSLock()
    /// 串行化监听重建流程：重建期间可能等待信号量，故不能持有状态锁（避免与 stateUpdateHandler 互锁）
    private let lifecycleLock = NSLock()
    private var sessions: [String: Session] = [:]

    private init() {}

    /// 注册串流会话，返回回环 URL：`http://127.0.0.1:<port>/stream/<id>/<文件名>`
    /// （保留文件名供引擎按扩展名探测格式）
    func register(reader: CachedRangeReader, fileName: String) throws -> URL {
        try startIfNeeded()
        let id = UUID().uuidString
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        lock.lock()
        let currentPort = port
        lock.unlock()
        guard currentPort > 0,
              let url = URL(string: "http://127.0.0.1:\(currentPort)\(Self.pathPrefix)\(id)/\(encoded)") else {
            throw PlayerPlaybackError("本地代理 URL 生成失败")
        }
        lock.lock()
        sessions[id] = Session(reader: reader, contentType: Self.mimeType(forFileName: fileName))
        lock.unlock()
        // 注册面包屑（TODO 380）：记录起播时监听端口与 reader 参数，复现时确认「熄屏后回环地址是否仍可用」
        AppLogger.shared.log(
            "register 串流会话 file=\(fileName) port=\(currentPort) 内容长度=\(reader.contentLength) 缓存=\(reader.cachingEnabled) 离线=\(reader.offlineMode) 预取=\(reader.prefetchEnabled) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "stream"
        )
        return url
    }

    /// 监听健康快照（诊断日志用，TODO 380）：ready/端口/活跃会话数
    func healthSnapshot() -> String {
        lock.lock()
        let state = listenerReady ? "ready" : (listener == nil ? "未启动" : "未就绪")
        let snapshot = "listener=\(state) port=\(port) sessions=\(sessions.count)"
        lock.unlock()
        return snapshot
    }

    /// 注销串流会话，返回该会话累计网络拉取字节数（封面抽帧等一次性读取后统计下载量）。
    @discardableResult
    func unregister(_ url: URL) -> Int64 {
        let rawPath = url.path
        guard rawPath.hasPrefix(Self.pathPrefix) else { return 0 }
        let sessionID = rawPath.dropFirst(Self.pathPrefix.count)
            .split(separator: "/").first.map(String.init) ?? ""
        guard !sessionID.isEmpty else { return 0 }
        lock.lock()
        let session = sessions.removeValue(forKey: sessionID)
        lock.unlock()
        session?.reader.cancel()
        return session?.reader.networkBytesFetched ?? 0
    }

    // MARK: - 服务生命周期

    /// 长时间后台回前台等场景的健康自愈（TODO 366）：
    /// 以真实回环探活判定监听是否仍可用，不可用才异步重建；
    /// 探活通过的监听不动，避免打断后台音频仍在进行的分片连接。
    func recoverIfNeeded() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                // startIfNeeded 内部做回环探活：健康则直接返回（不重建），不健康/僵尸才重建
                try self.startIfNeeded()
                AppLogger.shared.log("本地串流代理探活校验完成（\(self.healthSnapshot())）", level: .debug, module: "stream")
            } catch {
                AppLogger.shared.log(
                    "本地串流代理自愈重建失败 error=\(String(describing: error))",
                    level: .error, module: "stream"
                )
            }
        }
    }

    /// 复用已注册会话、在**重建后的新端口**上返回同一会话的 URL（TODO 366）。
    /// 挂起后回环监听被系统回收时，解码器已拿到的旧端口 URL 已不可用（连接被拒 -1004），
    /// 但会话（reader / 分片缓存）仍然有效，重建监听换端口即可恢复起播，无需重新解析数据源。
    func revivedURL(for url: URL) throws -> URL {
        let rawPath = url.path
        guard rawPath.hasPrefix(Self.pathPrefix) else {
            throw PlayerPlaybackError("非本地串流代理地址，无法换端口复用")
        }
        let sessionID = rawPath.dropFirst(Self.pathPrefix.count)
            .split(separator: "/").first.map(String.init) ?? ""
        lock.lock()
        let sessionExists = sessions[sessionID] != nil
        lock.unlock()
        guard sessionExists else {
            throw PlayerPlaybackError("串流会话已注销，无法换端口复用")
        }
        try startIfNeeded(force: true)
        lock.lock()
        let revivedPort = port
        lock.unlock()
        guard revivedPort > 0,
              let revived = URL(string: "http://127.0.0.1:\(revivedPort)\(rawPath)") else {
            throw PlayerPlaybackError("本地代理 URL 生成失败")
        }
        AppLogger.shared.log(
            "串流会话换端口重建 file=\(url.lastPathComponent) port=\(revivedPort)",
            level: .warn, module: "stream"
        )
        return revived
    }

    /// 确保监听可用。
    /// - Parameter force: 为 true 时无条件重建（跳过探活），用于起播被拒后的换端口重试。
    private func startIfNeeded(force: Bool = false) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        let flaggedUsable = listener != nil && listenerReady && port > 0
        let candidatePort = port
        let snapshot = "listener=\(listener == nil ? "nil" : "存在") ready=\(listenerReady) port=\(port) sessions=\(sessions.count)"
        lock.unlock()

        var zombie = false
        if !force, flaggedUsable {
            // 被动标记为 ready 不代表端口真的可用：App 被系统挂起时 iOS 会回收回环监听 socket，
            // 且不回调 waiting/failed/cancelled，`listenerReady` 便永久停留在 true（僵尸监听），
            // 复用该端口会让解码器连 127.0.0.1 立刻被拒（-1004）→ 硬解、软解起播全部失败。
            // 故以真实回环探活为准，探活通过才复用（TODO 366）
            if probe(port: candidatePort) {
                AppLogger.shared.log("监听探活通过，复用 port=\(candidatePort)", level: .debug, module: "stream")
                return
            }
            zombie = true
        }

        // 监听不可用（从未启动 / waiting、failed、cancelled / 挂起后被系统回收的僵尸监听）：
        // 清理僵尸监听后重建，避免复用失效端口导致音视频加载全失败（TODO 366）
        lock.lock()
        let stale = listener
        listener = nil
        listenerReady = false
        port = 0
        lock.unlock()
        if zombie {
            AppLogger.shared.log(
                "监听标记为 ready 但回环探活失败（僵尸监听，多因挂起后端口被系统回收），重建本地串流代理（\(snapshot)）",
                level: .warn, module: "stream"
            )
        } else if stale != nil {
            AppLogger.shared.log(
                force ? "强制重建本地串流代理监听（\(snapshot)）" : "监听不可用（\(snapshot)），重建本地串流代理",
                level: .warn, module: "stream"
            )
        }
        stale?.cancel()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)

        let semaphore = DispatchSemaphore(value: 0)
        var started = false
        var startError: Error?
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                let readyPort = listener?.port?.rawValue
                self.lock.lock()
                // 仅接受「当前待安装（listener == nil）或已安装」的监听，避免被替换的旧监听
                // 迟到回调把新监听的状态/端口覆盖掉（TODO 366）
                if self.listener === listener || self.listener == nil {
                    self.listenerReady = true
                    if let readyPort { self.port = readyPort }
                }
                let currentPort = self.port
                self.lock.unlock()
                started = true
                semaphore.signal()
                AppLogger.shared.log("listener ready port=\(currentPort)", level: .info, module: "stream")
            case .waiting(let error):
                // 运行中进入等待（系统网络栈重置等）：标记未就绪（保留对象供重建时 cancel），
                // 由 register 探活 / 回前台（recoverIfNeeded）触发重建（TODO 366）
                self.lock.lock()
                self.listenerReady = false
                self.lock.unlock()
                AppLogger.shared.log(
                    "listener waiting（标记未就绪，待自愈重建）error=\(String(describing: error))",
                    level: .warn, module: "stream"
                )
            case .failed(let error):
                startError = error
                self.clearIfCurrent(listener)
                semaphore.signal()
                AppLogger.shared.log(
                    "listener failed error=\(String(describing: error))",
                    level: .error, module: "stream"
                )
            case .cancelled:
                self.clearIfCurrent(listener)
                AppLogger.shared.log("listener cancelled", level: .warn, module: "stream")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: listenerQueue)

        _ = semaphore.wait(timeout: .now() + 3)
        guard started else {
            listener.cancel()
            AppLogger.shared.log(
                "listener 启动失败 error=\(String(describing: startError))",
                level: .error, module: "stream"
            )
            throw startError ?? PlayerPlaybackError("本地串流代理启动失败")
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    /// 监听彻底不可用（failed / cancelled）：仅当它仍是当前监听时清除状态，
    /// 避免已被替换的旧监听迟到回调把新监听标记为不可用（TODO 366）
    private func clearIfCurrent(_ listener: NWListener?) {
        lock.lock()
        if self.listener === listener {
            self.listener = nil
            self.listenerReady = false
            self.port = 0
        }
        lock.unlock()
    }

    // MARK: - 主动探活（TODO 366）

    /// 真实连一次回环端口，判定监听是否仍然可用。
    ///
    /// 只靠 `NWListener.stateUpdateHandler` 的被动标记判定是不够的：App 被系统挂起时
    /// iOS 会回收回环监听 socket，但并不回调 waiting/failed/cancelled，`listenerReady`
    /// 会永久停留在 true。此后复用该端口，解码器连 127.0.0.1 会立即被拒（-1004），
    /// 硬解与软解起播全部失败且无法自愈。故以真实 connect 结果为准。
    private func probe(port: UInt16, timeout: TimeInterval = 0.3) -> Bool {
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var noDelay: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, timeout * 1000))
        guard poll(&pollDescriptor, 1, milliseconds) > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    // MARK: - 连接处理（每连接一个请求，响应后关闭；客户端按需重连）

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        receiveHeader(on: connection, buffer: Data())
    }

    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var data = buffer
            if let content { data.append(content) }
            if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
                self.serve(header: header, on: connection)
            } else if error != nil || isComplete || data.count > 65536 {
                connection.cancel()
            } else {
                self.receiveHeader(on: connection, buffer: data)
            }
        }
    }

    private func serve(header: String, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else {
            respondError(status: "400 Bad Request", on: connection)
            return
        }
        let method = String(requestParts[0])
        let rawPath = String(requestParts[1])

        guard method == "GET" || method == "HEAD" else {
            respondError(status: "405 Method Not Allowed", on: connection)
            return
        }
        guard rawPath.hasPrefix(Self.pathPrefix) else {
            respondError(status: "404 Not Found", on: connection)
            return
        }
        let sessionID = rawPath.dropFirst(Self.pathPrefix.count).split(separator: "/").first.map(String.init) ?? ""
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()
        guard let session else {
            respondError(status: "404 Not Found", on: connection)
            return
        }

        // Range: bytes=start-end / bytes=start-（缺省全量）
        let total = session.reader.contentLength
        var start: Int64 = 0
        var end: Int64 = max(0, total - 1)
        var isPartial = false
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes=") else { continue }
            let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2, let parsedStart = Int64(bounds[0].trimmingCharacters(in: .whitespaces)) {
                start = parsedStart
                if let parsedEnd = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) {
                    end = parsedEnd
                }
                isPartial = true
            }
        }
        guard total > 0 else {
            respondError(status: "416 Range Not Satisfiable", on: connection)
            return
        }
        start = max(0, min(start, total - 1))
        end = max(start, min(end, total - 1))
        let length = end - start + 1

        var response = "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")\r\n"
        response += "Content-Type: \(session.contentType)\r\n"
        response += "Content-Length: \(length)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        if isPartial {
            response += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        response += "Connection: close\r\n\r\n"

        Task {
            var sentBytes: Int64 = 0
            do {
                try await send(Data(response.utf8), on: connection)
                if method != "HEAD" {
                    // 按 512KB 块流式输出，块内由分片缓存装配（弱网中断即停止）
                    var offset = start
                    let chunk: Int64 = 512 * 1024
                    while offset <= end {
                        try Task.checkCancellation()
                        let upper = min(offset + chunk, end + 1)
                        let data = try await session.reader.read(range: offset..<upper)
                        if data.isEmpty { break }
                        try await send(data, on: connection)
                        offset += Int64(data.count)
                    }
                    sentBytes = offset - start
                }
                AppLogger.shared.log(
                    "stream 完成 range=\(start)-\(end)/\(total) 发送=\(sentBytes)B",
                    level: .debug, module: "stream"
                )
            } catch {
                // 客户端中断（seek 取消旧请求）或底层读取失败：记录真实错误，定位封面抽帧超时/断连
                AppLogger.shared.log(
                    "stream 中断 range=\(start)-\(end)/\(total) 已发送=\(sentBytes)B error=\(String(describing: error))",
                    level: .warn, module: "stream"
                )
            }
            connection.cancel()
        }
    }

    private func respondError(status: String, on connection: NWConnection) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - MIME

    static func mimeType(forFileName name: String) -> String {
        switch StoragePath.ext(of: name) {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        case "wmv", "asf": return "video/x-ms-asf"
        case "ts", "m2ts": return "video/mp2t"
        case "rmvb", "rm": return "application/vnd.rn-realmedia"
        case "webm": return "video/webm"
        case "vob", "mpg", "mpeg": return "video/mpeg"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "ape": return "audio/x-ape"
        case "dts": return "audio/vnd.dts"
        default: return "application/octet-stream"
        }
    }
}
