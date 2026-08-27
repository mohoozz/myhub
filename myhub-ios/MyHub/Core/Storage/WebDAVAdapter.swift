import Foundation

/// WebDAV 适配器：URLSession + PROPFIND/GET，支持 HTTP Range 串流、HTTPS、Basic 认证
final class WebDAVAdapter: StorageAdapter {
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
            let task = Task {
                do {
                    // 用 data(for:) 一次性读完整 range：AsyncBytes 逐字节迭代性能极差
                    // （1MB ≈ 100 万次 await），弱网下分片/moov 读取极易超时，封面抽帧与播放均受影响。
                    // 当前所有调用方（1MB 分片、moov、封面图片）均为读完整 range，无流式增量消费需求。
                    let (data, response) = try await session.data(for: request)
                    try validate(response)
                    if !data.isEmpty {
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
