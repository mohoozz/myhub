import Foundation

/// WebDAV 适配器：URLSession + PROPFIND/GET，支持 HTTP Range 串流、HTTPS、Basic 认证
final class WebDAVAdapter: StorageAdapter, RangeVerifyingAdapter, @unchecked Sendable {
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
    static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 封面加载专用 URLSession：与 `streamSession` 的连接池完全隔离。
    static let coverSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
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
        let parser = WebDAVMultiStatusParser()
        let items = parser.parse(data: data)
        // 合法响应必然包含 <multistatus> 根元素（空目录亦然）；解析不到根元素说明服务器/反代
        guard parser.sawMultiStatus else {
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
            AppLogger.shared.log(
                "PROPFIND 响应异常（非 multistatus）path=\(path) depth=\(depth) status=\(status) contentType=\(contentType) bytes=\(data.count) body=\(Self.bodyPrefix(data))",
                level: .warn, module: "webdav"
            )
            throw StorageError.invalidResponse("PROPFIND \(path) 返回非 DAV 响应（HTTP \(status)，\(data.count) 字节）")
        }
        return items
    }

    /// 异常响应诊断：截取响应体前缀（去换行、限长），用于判断是错误页/登录页还是空响应
    private static func bodyPrefix(_ data: Data) -> String {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<empty>" : String(text.prefix(160))
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
        // 服务器返回了条目但全部被过滤（目录自身/隐藏项）：记录一次，便于区分「真空目录」与过滤异常
        if result.isEmpty, items.count > 1 {
            AppLogger.shared.log(
                "list 过滤后为空 dir=\(base) 服务器条目=\(items.count) href=\(items.prefix(5).map(\.href).joined(separator: ","))",
                level: .warn, module: "webdav"
            )
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
        try await readStream(path, range: range, expectedTotal: nil)
    }

    /// 带「期望对象总长」的 Range 流式读取（`RangeVerifyingAdapter`）
    func readStream(
        _ path: String, range: Range<Int64>?, expectedTotal: Int64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await readStream(path, range: range, expectedTotal: Optional(expectedTotal))
    }

    /// 实际实现：`expectedTotal` 为 nil 时跳过总长校验（普通读取）。
    private func readStream(
        _ path: String, range: Range<Int64>?, expectedTotal: Int64?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        var headers: [String: String] = [:]
        if let range {
            headers["Range"] = "bytes=\(range.lowerBound)-\(max(range.lowerBound, range.upperBound - 1))"
        }
        let request = makeRequest("GET", path: path, headers: headers)
        let expectation = StreamingReadExpectation(
            path: path,
            requestedRange: range,
            expectedTotal: expectedTotal,
            originHost: request.url?.host?.lowercased()
        )
        return AsyncThrowingStream { continuation in
            // 真正的增量流式下载：按网络到达的数据块（通常几 KB~几十 KB）持续 yield
            let delegate = StreamingReadDelegate(continuation: continuation, expectation: expectation)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            continuation.onTermination = { _ in
                // 先标记终止再取消：cancel 触发的完成回调会看到终止标记直接忽略
                delegate.markTerminated()
                task.cancel()
            }
            task.resume()
        }
    }

    func writeStream(_ path: String, data: AsyncThrowingStream<Data, Error>) async throws {
        // WebDAV PUT 需要 Content-Length：v1 先落临时文件再上传；分片断点续传见
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

// MARK: - 增量流式下载 delegate

/// `readStream` 的响应校验上下文：把「请求区间 / 期望对象总长 / 原始主机」交给 delegate
struct StreamingReadExpectation {
    let path: String
    let requestedRange: Range<Int64>?
    /// 目录（PROPFIND）声明的内容长度；nil 或 <= 0 表示未知（离线兜底等场景），跳过长度校验
    let expectedTotal: Int64?
    /// 原始请求主机（小写）：跨主机重定向一律不跟
    let originHost: String?

    /// 是否对响应做「网页 / 错误页」嗅探：只针对带 Range 的二进制媒体读取
    var shouldRejectWebPage: Bool {
        guard requestedRange != nil else { return false }
        let textual: Set<String> = ["html", "htm", "xhtml", "xml", "txt", "md", "json", "css", "js"]
        return !textual.contains(StoragePath.ext(of: path))
    }
}

/// `readStream` 的 per-task 数据接收 delegate：将网络到达的数据块持续 `yield` 给上游
final class StreamingReadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let expectation: StreamingReadExpectation
    private let lock = NSLock()
    private var terminated = false
    /// 本次响应最多向消费方输出多少字节（= 请求区间长度）；nil = 不限制（全量读取）
    private var payloadCap: Int64?
    private var receivedBytes: Int64 = 0

    init(
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        expectation: StreamingReadExpectation
    ) {
        self.continuation = continuation
        self.expectation = expectation
    }

    /// 消费方取消迭代时调用：原子标记终止，使随后 cancel 触发的完成回调直接忽略。
    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

 // MARK: - 重定向（防换源）

    /// 只跟随同主机重定向（允许 http → https 升级）。
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let newHost = request.url?.host?.lowercased()
        let originHost = expectation.originHost
        guard let newHost, !newHost.isEmpty, newHost == originHost else {
            AppLogger.shared.log(
                "readStream 拒绝跨主机重定向 path=\(expectation.path) status=\(response.statusCode) \(originHost ?? "-") → \(request.url?.absoluteString ?? "-")",
                level: .warn, module: "webdav"
            )
            completionHandler(nil)   // 不跟随：任务以 3xx 收尾，由 didReceive 抛错
            return
        }
        // 同主机重定向是分片请求的常态（每个 Range 请求都可能 302），只进 os_log
        AppLogger.shared.log(
            "readStream 同主机重定向 path=\(expectation.path) status=\(response.statusCode) → \(request.url?.absoluteString ?? "-")",
            level: .debug, module: "webdav"
        )
        completionHandler(request)
    }

 // MARK: - 响应校验

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let isTerminated = terminated
        lock.unlock()
        if isTerminated {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fail(StorageError.invalidResponse("readStream 收到非 HTTP 响应"))
            completionHandler(.cancel)
            return
        }
        do {
            let cap = try validate(http)
            lock.lock()
            payloadCap = cap
            lock.unlock()
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    /// 校验响应与请求的一致性，返回本次允许输出的最大字节数（nil = 不限）。
    private func validate(_ http: HTTPURLResponse) throws -> Int64? {
        // 状态码必须 2xx：否则（416 / 4xx / 5xx / 网关错误页）响应体若被当数据 yield
        let status = http.statusCode
        guard (200...299).contains(status) else {
            throw StorageError.http(
                status: status,
                message: HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        // 劫持/登录页签名：媒体请求被换成网页时，字节流会被当成视频喂给解码器
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if expectation.shouldRejectWebPage,
           contentType.contains("text/html") || contentType.contains("application/xhtml") || contentType.contains("text/xml") {
            throw StorageError.invalidResponse("媒体请求返回了网页内容（Content-Type: \(contentType)），疑似被劫持或登录页")
        }
        let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }

        guard let range = expectation.requestedRange else { return nil }
        let requestedCount = range.upperBound - range.lowerBound

        if status == 206 {
            guard let raw = http.value(forHTTPHeaderField: "Content-Range") else {
                // 非标准服务器可能省略 Content-Range：从 0 起的分片可按请求长度截断兜底
                guard range.lowerBound == 0 else {
                    throw StorageError.invalidResponse(
                        "206 响应缺少 Content-Range，无法确认分片对齐（起点 \(range.lowerBound)）"
                    )
                }
                return requestedCount
            }
            guard let parsed = Self.parseContentRange(raw) else {
                throw StorageError.invalidResponse("Content-Range 无法解析：\(raw)")
            }
            guard parsed.start == range.lowerBound else {
                throw StorageError.invalidResponse(
                    "Content-Range 起点 \(parsed.start) 与请求起点 \(range.lowerBound) 不一致（数据错位）"
                )
            }
            guard parsed.end >= parsed.start else {
                throw StorageError.invalidResponse("Content-Range 区间非法：\(raw)")
            }
            if let total = parsed.total,
               let expected = expectation.expectedTotal, expected > 0, total != expected {
                throw StorageError.invalidResponse(
                    "响应对象总长 \(total) 与目录记录 \(expected) 不一致（疑似被换源）"
                )
            }
            let available = parsed.end - parsed.start + 1
            if let contentLength, contentLength != available {
                throw StorageError.invalidResponse(
                    "206 Content-Length \(contentLength) 与 Content-Range 区间长度 \(available) 不一致"
                )
            }
            // 允许服务器少给，绝不多给
            return min(requestedCount, available)
        }

        // 200：服务器忽略了 Range，返回整份对象
        guard range.lowerBound == 0 else {
            throw StorageError.invalidResponse(
                "服务器忽略 Range（HTTP 200 返回全量），起点 \(range.lowerBound) 的字节无法对齐"
            )
        }
        if let contentLength, let expected = expectation.expectedTotal, expected > 0, contentLength != expected {
            throw StorageError.invalidResponse(
                "响应长度 \(contentLength) 与目录记录 \(expected) 不一致（疑似被换源）"
            )
        }
        // 从 0 起的全量响应：按请求长度截断，绝不把整份文件当分片写进缓存
        return requestedCount
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if terminated {
            lock.unlock()
            return
        }
        var payload = data
        var capReached = false
        if let cap = payloadCap {
            let remain = cap - receivedBytes
            if remain <= 0 {
                lock.unlock()
                return
            }
            if Int64(payload.count) > remain {
                payload = payload.prefix(Int(remain))
            }
            receivedBytes += Int64(payload.count)
            capReached = receivedBytes >= cap
        } else {
            receivedBytes += Int64(payload.count)
        }
        if capReached {
            // 请求区间已取满即视为完成：服务器忽略 Range 返回整份对象时
            terminated = true
        }
        lock.unlock()

        if !payload.isEmpty {
            // yield 对已终止的流是安全的（返回 .terminated），不会崩溃
            continuation.yield(payload)
        }
        if capReached {
            continuation.finish()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        let received = receivedBytes
        let cap = payloadCap
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
            return
        }
        if let cap, received < cap {
            // 服务器提前收尾（未报错但少给字节）：上层会从断点续传补齐，这里留面包屑便于定位
            AppLogger.shared.log(
                "readStream 响应提前结束 path=\(expectation.path) 期望=\(cap)B 实收=\(received)B（将由断点续传补齐）",
                level: .debug, module: "webdav"
            )
        }
        continuation.finish()
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        lock.unlock()
        AppLogger.shared.log(
            "readStream 响应校验失败 path=\(expectation.path) range=\(describe(expectation.requestedRange)) error=\(error.localizedDescription)",
            level: .warn, module: "webdav"
        )
        continuation.finish(throwing: error)
    }

    private func describe(_ range: Range<Int64>?) -> String {
        guard let range else { return "全量" }
        return "\(range.lowerBound)-\(range.upperBound - 1)"
    }

    /// 解析 `Content-Range: bytes 0-1048575/7340032`（total 可能为 `*`）
    private static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        return (start, end, totalText == "*" ? nil : Int64(totalText))
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
    /// 是否解析到 multistatus 根元素：区分「合法的空 multistatus」与「非 DAV 响应」
    private(set) var sawMultiStatus = false

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
        case "multistatus":
            sawMultiStatus = true
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
