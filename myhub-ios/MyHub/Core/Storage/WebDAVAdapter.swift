import Foundation

/// WebDAV 适配器：URLSession + PROPFIND/GET，支持 HTTP Range 串流、HTTPS、Basic 认证
/// 所有存储属性均为不可变 `let`（URLSession 亦线程安全），可安全跨并发域使用（内外网竞速判定捕获）。
final class WebDAVAdapter: StorageAdapter, @unchecked Sendable {
    private let config: WebDAVConfig
    private let password: String?
    private let session: URLSession
    /// 普通请求超时（内网探测用短超时，见 RoutedWebDAVAdapter 注释）
    private let timeoutInterval: TimeInterval
    /// baseURL + rootPath 合成的连接根
    private let rootURL: URL

    /// 连接根 URL 字符串：作为内外网路由共享冷却的 key（RoutedWebDAVAdapter 使用）
    var rootURLString: String { rootURL.absoluteString }

    /// 串流专用共享 URLSession：与 `URLSession.shared` 隔离，避免边下边播的高频 Range 请求
    /// 与频繁取消污染全局共享连接池（僵尸连接导致后续请求 30s 超时）。
    /// 提升单主机并发上限、关闭 URL 缓存（视频流不缓存）。
    private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    init(
        config: WebDAVConfig,
        password: String?,
        session: URLSession = WebDAVAdapter.streamSession,
        timeoutInterval: TimeInterval = 30
    ) throws {
        guard let base = URL(string: config.baseURL),
              let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw StorageError.invalidConfig("地址需为 http(s)://host[:port]，当前：\(config.baseURL)")
        }
        self.config = config
        self.password = password
        self.session = session
        self.timeoutInterval = timeoutInterval
        var url = base
        let rootPath = config.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rootPath.isEmpty {
            for component in rootPath.split(separator: "/") {
                url = url.appendingPathComponent(String(component), isDirectory: true)
            }
        }
        self.rootURL = url
    }

    // MARK: - 请求构造

    private func url(for path: String) -> URL {
        let normalized = StoragePath.normalize(path)
        guard normalized != "/" else { return rootURL }
        var url = rootURL
        for component in normalized.dropFirst().split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }

    private func makeRequest(
        _ method: String, path: String, headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        if let authorization = authorizationHeader {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private var authorizationHeader: String? {
        guard !config.username.isEmpty else { return nil }
        let raw = "\(config.username):\(password ?? "")"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.underlying(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw StorageError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw StorageError.http(
                status: http.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
    }

    private static let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
          </D:prop>
        </D:propfind>
        """

    private func propfind(_ path: String, depth: String) async throws -> [WebDAVResponseItem] {
        var request = makeRequest("PROPFIND", path: path, headers: [
            "Depth": depth,
            "Content-Type": "application/xml; charset=utf-8",
        ])
        request.httpBody = Data(Self.propfindBody.utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw StorageError.notFound(path)
        }
        try validate(response)
        return WebDAVMultiStatusParser().parse(data: data)
    }

    // MARK: - StorageAdapter

    func list(_ dir: String) async throws -> [FileEntry] {
        let items = try await propfind(dir, depth: "1")
        let dirURL = url(for: dir)
        let base = StoragePath.normalize(dir)
        var result: [FileEntry] = []
        for item in items {
            if item.isSameResource(as: dirURL) { continue }   // 跳过目录自身
            guard let name = item.displayName ?? item.hrefLastComponent,
                  !name.isEmpty, !name.hasPrefix(".") else { continue }
            result.append(FileEntry(
                name: name,
                path: StoragePath.joining(base, name),
                isDir: item.isCollection,
                size: item.contentLength ?? 0,
                modTime: item.lastModified ?? .distantPast,
                ext: item.isCollection ? "" : StoragePath.ext(of: name)
            ))
        }
        return result
    }

    func stat(_ path: String) async throws -> FileEntry {
        let items = try await propfind(path, depth: "0")
        guard let item = items.first else { throw StorageError.notFound(path) }
        let normalized = StoragePath.normalize(path)
        let name = item.displayName ?? StoragePath.fileName(of: normalized)
        return FileEntry(
            name: name,
            path: normalized,
            isDir: item.isCollection,
            size: item.contentLength ?? 0,
            modTime: item.lastModified ?? .distantPast,
            ext: item.isCollection ? "" : StoragePath.ext(of: normalized)
        )
    }

    func readStream(_ path: String, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
        var headers: [String: String] = [:]
        if let range {
            headers["Range"] = "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))"
        }
        let request = makeRequest("GET", path: path, headers: headers)
        return AsyncThrowingStream { continuation in
            // 真正的增量流式下载（TODO 356）：按网络到达的数据块（通常几 KB~几十 KB）持续 yield，
            // 弱网慢速下载不再「整块下完才返回」——配合上层停滞超时可断点续传、不丢弃已下载数据。
            // 用 per-task delegate（iOS 15+，task 强引用直至完成）承接回调，而非 AsyncBytes
            // （后者逐字节 await，1MB ≈ 百万次，性能极差）。task 保持对 delegate 强引用，无需额外持有。
            let delegate = StreamingReadDelegate(continuation: continuation)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            continuation.onTermination = { _ in
                // 先标记终止再取消：cancel 触发的完成回调会看到终止标记直接忽略，
                // 避免对已终止的 continuation 二次 finish 导致崩溃
                delegate.markTerminated()
                task.cancel()
            }
            task.resume()
        }
    }

    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws {
        // WebDAV PUT 需要 Content-Length：v1 先落临时文件再上传；分片断点续传见 TODO §3.2
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            for try await chunk in data {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let request = makeRequest("PUT", path: path)
        let (_, response) = try await session.upload(for: request, fromFile: temp)
        try validate(response)
    }

    func move(_ src: String, _ dest: String) async throws {
        let request = makeRequest("MOVE", path: src, headers: [
            "Destination": url(for: dest).absoluteString,
            "Overwrite": "T",
        ])
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func copy(_ src: String, _ dest: String) async throws {
        let request = makeRequest("COPY", path: src, headers: [
            "Destination": url(for: dest).absoluteString,
            "Overwrite": "T",
        ])
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func delete(_ path: String) async throws {
        let request = makeRequest("DELETE", path: path)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func mkdir(_ path: String) async throws {
        let request = makeRequest("MKCOL", path: path)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func testConnection() async throws {
        var request = makeRequest("PROPFIND", path: "/", headers: [
            "Depth": "0",
            "Content-Type": "application/xml; charset=utf-8",
        ])
        request.httpBody = Data(Self.propfindBody.utf8)
        request.timeoutInterval = min(timeoutInterval, 10)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }
}

// MARK: - 增量流式下载 delegate（TODO 356）

/// `readStream` 的 per-task 数据接收 delegate：将网络到达的数据块持续 `yield` 给上游，
/// 完成或失败时结束流。URLSession 的 per-task delegate（iOS 15+）会被 task 强引用直至结束，
/// 无需额外持有；消费方取消迭代时经 `markTerminated` 提前标记，避免已终止后续流再 `finish` 崩溃。
final class StreamingReadDelegate: NSObject, URLSessionDataDelegate {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var terminated = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    /// 消费方取消迭代时调用：原子标记终止，使随后 cancel 触发的完成回调直接忽略。
    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 校验 HTTP 状态码：Range 读取必须 2xx（206 Partial Content / 200）。
        // 否则（416 Range 不满足 / 4xx / 5xx / 内网代理错误页）错误响应体若被当数据 yield，
        // 会污染 RangeZipReader 的中央目录/条目解析，表现为「malformed」「图片一直加载中」等偶发故障。
        var badStatus: Int?
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            badStatus = http.statusCode
        }
        lock.lock()
        if let code = badStatus, !terminated {
            terminated = true
            lock.unlock()
            continuation.finish(throwing: StorageError.http(
                status: code,
                message: HTTPURLResponse.localizedString(forStatusCode: code)
            ))
            completionHandler(.cancel)
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isTerminated = terminated
        lock.unlock()
        guard !isTerminated else { return }
        // yield 对已终止的流是安全的（返回 .terminated），不会崩溃
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - PROPFIND multistatus 解析

struct WebDAVResponseItem {
    var href: String = ""
    var displayName: String?
    var isCollection = false
    var contentLength: Int64?
    var lastModified: Date?

    var hrefLastComponent: String? {
        href.split(separator: "/").last.map(String.init)
    }

    func isSameResource(as requestURL: URL) -> Bool {
        let hrefPath: String
        if let url = URL(string: href), url.scheme != nil {
            hrefPath = url.path
        } else {
            hrefPath = href
        }
        func trim(_ path: String) -> String {
            path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return trim(hrefPath) == trim(requestURL.path)
    }
}

final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private var items: [WebDAVResponseItem] = []
    private var current = WebDAVResponseItem()
    private var currentText = ""
    private var insideResponse = false

    func parse(data: Data) -> [WebDAVResponseItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        switch localName(elementName) {
        case "response":
            insideResponse = true
            current = WebDAVResponseItem()
        case "collection" where insideResponse:
            current.isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(elementName) {
        case "response":
            items.append(current)
            insideResponse = false
        case "href" where insideResponse && current.href.isEmpty:
            current.href = text.removingPercentEncoding ?? text
        case "displayname" where !text.isEmpty:
            current.displayName = text
        case "getcontentlength":
            current.contentLength = Int64(text)
        case "getlastmodified":
            current.lastModified = Self.httpDateFormatter.date(from: text)
        default:
            break
        }
        currentText = ""
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
