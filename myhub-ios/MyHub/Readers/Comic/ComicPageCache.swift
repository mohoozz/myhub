import CryptoKit
import Foundation

/// 漫画解压页磁盘缓存（IOS-605 内容缓存本地化 / TODO §11）：
/// - 解压出的单页原始数据按「文件指纹 + 页名」落盘，下次打开（含弱网/无网络）直接命中，无需重新解压；
/// - 页名列表持久化（`pages.json`）+ 远程 rar/cbr 整包落缓存复用 → **已缓存漫画支持离线打开阅读**；
/// - 目录粒度 LRU + 分区配额（`CacheManager.limitBytes(for: .comicPages)`），受「内容缓存本地化」开关约束。
enum ComicPageCache {
    private static let store = FingerprintDiskCache(partition: .comicPages)

    /// 缓存是否启用（内容缓存本地化开关）
    static var enabled: Bool { AppSettings.Cache.contentCachingEnabled }

    /// 文件缓存身份（在线：entry 指纹）
    static func identity(connectionID: Int64, entry: FileEntry) -> SegmentCache.FileIdentity {
        SegmentCache.FileIdentity(
            connectionID: connectionID,
            path: entry.path,
            size: entry.size,
            modTime: entry.modTime.timeIntervalSince1970
        )
    }

    /// 离线身份反查（stat/打开失败后兜底，指纹随身份一并取回供进度校验）
    static func identity(connectionID: Int64, path: String) async -> SegmentCache.FileIdentity? {
        await store.identity(connectionID: connectionID, path: path)
    }

    // MARK: - 解压页

    private static func pageName(_ name: String) -> String {
        let digest = SHA256.hash(data: Data(name.utf8))
        return "p_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func page(file: SegmentCache.FileIdentity, name: String) async -> Data? {
        guard enabled else { return nil }
        return await store.data(named: pageName(name), for: file)
    }

    static func storePage(_ data: Data, file: SegmentCache.FileIdentity, name: String) async {
        guard enabled else { return }
        await store.store(named: pageName(name), data: data, for: file)
    }

    // MARK: - 页名列表（离线打开的结构基础）

    static func pageList(file: SegmentCache.FileIdentity) async -> [String]? {
        guard let data = await store.data(named: "pages.json", for: file) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func storePageList(_ names: [String], file: SegmentCache.FileIdentity) async {
        guard enabled, let data = try? JSONEncoder().encode(names) else { return }
        await store.store(named: "pages.json", data: data, for: file)
    }

    // MARK: - 页宽高比（条漫占位高度 = 真实高度，恢复定位不被解码膨胀顶偏）

    static func pageRatios(file: SegmentCache.FileIdentity) async -> [Int: Float]? {
        guard let data = await store.data(named: "ratios.json", for: file) else { return nil }
        return try? JSONDecoder().decode([Int: Float].self, from: data)
    }

    static func storePageRatios(_ ratios: [Int: Float], file: SegmentCache.FileIdentity) async {
        guard enabled, let data = try? JSONEncoder().encode(ratios) else { return }
        await store.store(named: "ratios.json", data: data, for: file)
    }

    // MARK: - 远程 rar/cbr 整包复用（UnrarKit 需要文件 URL；落缓存分区供下次/离线直接用）

    static func archiveURL(for file: SegmentCache.FileIdentity, ext: String) async -> URL {
        await store.url(named: "archive.\(ext)", for: file)
    }

    /// 整包写入完成后刷新访问时间并触发 LRU
    static func noteArchiveWritten(for file: SegmentCache.FileIdentity) async {
        await store.touch(file)
    }

    /// 离线漫画源：反查身份 + 页名列表，两者俱在才可离线打开
    static func offlineSource(connectionID: Int64, path: String) async -> DiskCachedComicSource? {
        guard let identity = await identity(connectionID: connectionID, path: path),
              let names = await pageList(file: identity), !names.isEmpty else { return nil }
        return DiskCachedComicSource(identity: identity, pageNames: names)
    }
}

/// 离线漫画数据源（IOS-605）：页数据全部来自磁盘页缓存，未缓存页报错占位
final class DiskCachedComicSource: ComicPageSource {
    let identity: SegmentCache.FileIdentity
    let pageNames: [String]

    init(identity: SegmentCache.FileIdentity, pageNames: [String]) {
        self.identity = identity
        self.pageNames = pageNames
    }

    func pageData(at index: Int) async throws -> Data {
        guard pageNames.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        if let data = await ComicPageCache.page(file: identity, name: pageNames[index]) {
            return data
        }
        throw StorageError.offline("第 \(index + 1) 页")
    }
}

/// 缓存优先漫画源（缓存秒开）：页名列表来自缓存，单页数据优先命中磁盘缓存；
/// 后台归档源（fallback）补齐后，缓存未命中的页回退到归档按需解压，保证完整性。
/// fallback 用锁保护（`pageData` 在后台线程调用，`setFallback`/`markFallbackFailed` 在 MainActor 调用）。
final class CachedFirstComicSource: ComicPageSource {
    let identity: SegmentCache.FileIdentity
    let pageNames: [String]

    private enum FallbackState {
        case pending
        case ready(ComicPageSource)
        case failed
    }

    private let lock = NSLock()
    private var fallbackState: FallbackState = .pending

    init(identity: SegmentCache.FileIdentity, pageNames: [String]) {
        self.identity = identity
        self.pageNames = pageNames
    }

    func setFallback(_ source: ComicPageSource) {
        lock.lock(); fallbackState = .ready(source); lock.unlock()
    }

    func markFallbackFailed() {
        lock.lock(); fallbackState = .failed; lock.unlock()
    }

    func pageData(at index: Int) async throws -> Data {
        guard pageNames.indices.contains(index) else { throw ArchiveDecodeError.noPages }
        // 缓存命中（ViewModel 层通常已命中，此处兜底）
        if let data = await ComicPageCache.page(file: identity, name: pageNames[index]) {
            AppLogger.shared.log("CachedFirst 缓存命中兜底: 第\(index + 1)页", module: "comic-reader")
            return data
        }
        // 等 fallback 就绪（后台归档打开中，最多 ~8s）；失败/超时按离线占位报错
        let t0 = CFAbsoluteTimeGetCurrent()
        var waitedMs = 0
        while true {
            lock.lock()
            let state = fallbackState
            lock.unlock()
            switch state {
            case .ready(let source):
                let waited = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                AppLogger.shared.log(
                    String(format: "CachedFirst 等 fallback 就绪: 第%d页 等待=%.0fms", index + 1, waited),
                    module: "comic-reader"
                )
                return try await source.pageData(at: index)
            case .failed:
                throw StorageError.offline("第 \(index + 1) 页")
            case .pending:
                break
            }
            if waitedMs >= 8_000 { throw StorageError.offline("第 \(index + 1) 页") }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitedMs += 100
            if Task.isCancelled { throw CancellationError() }
        }
    }

    func close() {
        lock.lock()
        if case .ready(let source) = fallbackState {
            fallbackState = .failed
            lock.unlock()
            source.close()
        } else {
            lock.unlock()
        }
    }
}
