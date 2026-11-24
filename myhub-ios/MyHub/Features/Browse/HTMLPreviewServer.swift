import Foundation
import Network

/// HTML 预览专用：进程内回环静态服务（同一时刻只服务一份文档）。
///
/// 浏览界面点到 .html/.htm 时无需经过内置浏览器页签：注册一份「文档」（适配器 + 文件所在目录）后拿到
/// `http://127.0.0.1:<port>/<文件名>`，交给 `WKWebView` 直接渲染即可。站点根 = HTML 文件所在目录，
/// 因此页面里的相对路径（`css/a.css`、`img/x.png`、`../up.js`）与根路径（`/style.css`）都会回到同一
/// 存储目录按需读取——远程 WebDAV / SMB 上的整站也能带样式、带图片地预览。
///
/// 只监听回环地址，且预览界面关闭时立刻停掉，不对外暴露端口。
final class HTMLPreviewServer {
    static let shared = HTMLPreviewServer()

    private struct Document {
        let adapter: StorageAdapter
        /// 站点根：HTML 文件所在目录（连接内虚拟路径）
        let rootDir: String
    }

    private let lock = NSLock()
    /// 串行化监听启停：启动过程会等待信号量，不能持有 `lock`
    private let lifecycleLock = NSLock()
    private var document: Document?
    private var listener: NWListener?
    private var port: UInt16 = 0

    private let listenerQueue = DispatchQueue(label: "myhub.htmlpreview.listener")
    private let connectionQueue = DispatchQueue(label: "myhub.htmlpreview.conn", attributes: .concurrent)

    /// HTML 统一转 UTF-8 的读取上限：超过则按原始字节直出（交给 WebKit 按页面 meta 判编码）
    private let htmlDecodeLimit: Int64 = 8 * 1024 * 1024

    private init() {}

// MARK: - 注册 / 注销

    /// 注册待预览文档并启动（或复用）回环服务，返回可交给 `WKWebView` 的入口 URL。
    func register(entry: FileEntry, adapter: StorageAdapter) throws -> URL {
        let readyPort = try startIfNeeded()
        let rootDir = StoragePath.parent(of: entry.path)
        lock.lock()
        document = Document(adapter: adapter, rootDir: rootDir)
        lock.unlock()

        let encodedName = entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "index.html"
        guard let url = URL(string: "http://127.0.0.1:\(readyPort)/\(encodedName)") else {
            throw StorageError.invalidPath(entry.path)
        }
        AppLogger.shared.log(
            "html 预览注册 file=\(entry.name) root=\(rootDir) port=\(readyPort)",
            level: .info, module: "html-preview"
        )
        return url
    }

    /// 预览界面关闭时调用：停掉监听并释放文档（不再持有适配器与端口）。
    func unregister() {
        lifecycleLock.lock()
        let stale = listener
        listener = nil
        port = 0
        lifecycleLock.unlock()
        stale?.cancel()

        lock.lock()
        let hadDocument = document != nil
        document = nil
        lock.unlock()
        if hadDocument {
            AppLogger.shared.log("html 预览注销，监听已停止", level: .debug, module: "html-preview")
        }
    }

// MARK: - 监听生命周期

    /// 确保回环监听可用；返回监听端口。
    private func startIfNeeded() throws -> UInt16 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        let existingPort = port
        let hasListener = listener != nil
        lock.unlock()
        if hasListener, existingPort > 0 { return existingPort }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let newListener = try NWListener(using: parameters, on: .any)

        let semaphore = DispatchSemaphore(value: 0)
        var started = false
        var startError: Error?
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.port = newListener?.port?.rawValue ?? 0
                let readyPort = self.port
                self.lock.unlock()
                started = true
                semaphore.signal()
                AppLogger.shared.log("html 预览监听 ready port=\(readyPort)", level: .info, module: "html-preview")
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        newListener.start(queue: listenerQueue)

        _ = semaphore.wait(timeout: .now() + 3)
        guard started else {
            newListener.cancel()
            AppLogger.shared.log(
                "html 预览监听启动失败 error=\(String(describing: startError))",
                level: .error, module: "html-preview"
            )
            throw startError ?? StorageError.invalidResponse("HTML 预览服务启动失败")
        }

        lock.lock()
        listener = newListener
        let readyPort = port
        lock.unlock()
        return readyPort
    }

// MARK: - 连接处理（每连接一个请求，响应后关闭）

    private func handle(_ connection: NWConnection) {
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
            respondStatus("400 Bad Request", on: connection)
            return
        }
        let method = String(requestParts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            respondStatus("405 Method Not Allowed", on: connection)
            return
        }

        // 只取路径部分：去掉查询串/锚点，再百分号解码
        var target = String(requestParts[1])
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            target = String(target[..<cut])
        }
        let decodedPath = target.removingPercentEncoding ?? target

        var rangeValue: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeValue = String(line.drop(while: { $0 != ":" }).dropFirst())
                .trimmingCharacters(in: .whitespaces)
            break
        }

        lock.lock()
        let currentDocument = document
        lock.unlock()
        guard let currentDocument else {
            respondStatus("404 Not Found", on: connection)
            return
        }

        Task {
            await serveAsset(
                path: decodedPath, method: method, rangeValue: rangeValue,
                doc: currentDocument, on: connection
            )
        }
    }

// MARK: - 资源应答

    private func serveAsset(
        path: String, method: String, rangeValue: String?, doc: Document, on connection: NWConnection
    ) async {
        /// 响应头是否已发出：已发出后出错只能断开连接，不能再补一个 HTTP 响应
        var wroteHead = false
        do {
            var virtualPath = Self.resolve(path, rootDir: doc.rootDir)
            var entry = try await doc.adapter.stat(virtualPath)
            if entry.isDir {
                virtualPath = StoragePath.joining(virtualPath, "index.html")
                entry = try await doc.adapter.stat(virtualPath)
            }
            guard !entry.isDir else {
                respondStatus("404 Not Found", on: connection)
                return
            }

            // HTML：按编码探测解码成 UTF-8 再直出（GBK/Big5/UTF-16 页面不依赖 WebKit 的默认编码猜测）
            let isHTML = entry.ext == "html" || entry.ext == "htm"
            if isHTML, entry.size <= htmlDecodeLimit,
               let raw = try? await doc.adapter.readAll(virtualPath, limit: htmlDecodeLimit) {
                let utf8 = Data(TextEncodingDetector.decode(raw).text.utf8)
                try await writeHead(
                    status: "200 OK",
                    contentType: Self.mimeType(forExt: entry.ext) + "; charset=utf-8",
                    contentLength: Int64(utf8.count),
                    contentRange: nil,
                    on: connection
                )
                wroteHead = true
                if method != "HEAD" { try await send(utf8, on: connection) }
                connection.cancel()
                return
            }

            let contentType = Self.mimeType(forExt: entry.ext)
            let total = entry.size
            guard total > 0 else {
                try await writeHead(
                    status: "200 OK", contentType: contentType,
                    contentLength: 0, contentRange: nil, on: connection
                )
                connection.cancel()
                return
            }

            let range = Self.byteRange(from: rangeValue, total: total)
            if rangeValue != nil, range == nil {
                respondStatus("416 Range Not Satisfiable", on: connection)
                return
            }
            let start = range?.start ?? 0
            let end = range?.end ?? (total - 1)

            try await writeHead(
                status: range == nil ? "200 OK" : "206 Partial Content",
                contentType: contentType,
                contentLength: end - start + 1,
                contentRange: range.map { (start: $0.start, end: $0.end, total: total) },
                on: connection
            )
            wroteHead = true

            if method != "HEAD" {
                let stream = try await doc.adapter.readStream(virtualPath, range: start..<(end + 1))
                var offset = start
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard !chunk.isEmpty else { continue }
                    let upper = min(offset + Int64(chunk.count), end + 1)
                    let take = Int(upper - offset)
                    if take > 0 {
                        try await send(Data(chunk.prefix(take)), on: connection)
                        offset = upper
                    }
                    if offset > end { break }
                }
            }
            connection.cancel()
        } catch is CancellationError {
            connection.cancel()
        } catch {
            AppLogger.shared.log(
                "html 预览资源读取失败 path=\(path) error=\(String(describing: error))",
                level: .warn, module: "html-preview"
            )
            if wroteHead {
                connection.cancel()
            } else {
                respondStatus("404 Not Found", on: connection)
            }
        }
    }

    /// URL 路径 → 连接内虚拟路径。站点根为 HTML 所在目录；`..` 折叠后无法逃出连接根。
    private static func resolve(_ rawPath: String, rootDir: String) -> String {
        var relative = rawPath
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        let base = rootDir == "/" ? "" : rootDir
        return StoragePath.normalize(base + "/" + relative)
    }

    private func writeHead(
        status: String,
        contentType: String,
        contentLength: Int64,
        contentRange: (start: Int64, end: Int64, total: Int64)?,
        on connection: NWConnection
    ) async throws {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(contentLength)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        // 预览期间源文件可能被外部修改（WebDAV 同步）：不做缓存
        head += "Cache-Control: no-store\r\n"
        if let contentRange {
            head += "Content-Range: bytes \(contentRange.start)-\(contentRange.end)/\(contentRange.total)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        try await send(Data(head.utf8), on: connection)
    }

    /// 解析 `Range: bytes=...`；`total <= 0` 或格式不支持时返回 nil（按全量处理）
    private static func byteRange(from headerValue: String?, total: Int64) -> (start: Int64, end: Int64)? {
        guard let headerValue, headerValue.lowercased().hasPrefix("bytes="), total > 0 else { return nil }
        let bounds = headerValue.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let startText = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(bounds[1]).trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            return (max(0, total - suffix), total - 1)
        }
        guard let start = Int64(startText), start < total else { return nil }
        let requestedEnd = Int64(endText) ?? (total - 1)
        let end = min(max(requestedEnd, start), total - 1)
        return (start, end)
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

    private func respondStatus(_ status: String, on connection: NWConnection) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func mimeType(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "xhtml": return "application/xhtml+xml"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json", "map": return "application/json"
        case "xml": return "application/xml"
        case "txt", "md": return "text/plain"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "avif": return "image/avif"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "pdf": return "application/pdf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
