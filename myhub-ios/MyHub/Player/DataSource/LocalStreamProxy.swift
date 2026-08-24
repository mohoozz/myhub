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
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    private init() {}

    /// 注册串流会话，返回回环 URL：`http://127.0.0.1:<port>/stream/<id>/<文件名>`
    /// （保留文件名供引擎按扩展名探测格式）
    func register(reader: CachedRangeReader, fileName: String) throws -> URL {
        try startIfNeeded()
        let id = UUID().uuidString
        lock.lock()
        sessions[id] = Session(reader: reader, contentType: Self.mimeType(forFileName: fileName))
        lock.unlock()
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        guard let url = URL(string: "http://127.0.0.1:\(port)\(Self.pathPrefix)\(id)/\(encoded)") else {
            throw PlayerPlaybackError("本地代理 URL 生成失败")
        }
        return url
    }

    // MARK: - 服务生命周期

    private func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if listener != nil { return }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)

        let semaphore = DispatchSemaphore(value: 0)
        var readyPort: UInt16?
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyPort = listener.port?.rawValue
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: listenerQueue)

        _ = semaphore.wait(timeout: .now() + 3)
        guard let port = readyPort else {
            listener.cancel()
            throw startError ?? PlayerPlaybackError("本地串流代理启动失败")
        }
        self.port = port
        self.listener = listener
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
                }
            } catch {
                // 客户端中断（seek 取消旧请求）或读取失败：关闭连接
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
