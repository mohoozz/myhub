import Foundation

/// 本地存储适配器：应用沙盒 Documents / 「文件」App 共享目录（Security-Scoped Bookmark）
final class LocalAdapter: StorageAdapter {
    private let root: URL
    /// root 来自 UIDocumentPicker / 文件 App，需要安全作用域访问
    private let securityScoped: Bool

    static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init(root: URL = LocalAdapter.documentsRoot, securityScoped: Bool = false) {
        self.root = root
        self.securityScoped = securityScoped
    }

    /// 从 Security-Scoped Bookmark 恢复（LocalConfig.bookmarkData）
    convenience init?(bookmarkData: Data) {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        self.init(root: url, securityScoped: true)
    }

    private func withAccess<T>(_ body: () async throws -> T) async throws -> T {
        let accessing = securityScoped && root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    /// 本地文件实际 URL（供视频抽帧等需要文件 URL 的场景；security-scoped 目录需配合 withLocalAccess 使用）
    func localFileURL(for path: String) -> URL? {
        try? fileURL(for: path)
    }

    /// 在 security-scoped 访问作用域内执行（封面抽帧等直接访问文件 URL 的场景）
    func withLocalAccess<T>(_ body: () async throws -> T) async throws -> T {
        let accessing = securityScoped && root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    private func fileURL(for path: String) throws -> URL {
        let normalized = StoragePath.normalize(path)
        let url = normalized == "/" ? root : root.appendingPathComponent(String(normalized.dropFirst()))
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else {
            throw StorageError.invalidPath(path)
        }
        return url
    }

    // MARK: - StorageAdapter

    func list(_ dir: String) async throws -> [FileEntry] {
        try await withAccess {
            let url = try fileURL(for: dir)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            let base = StoragePath.normalize(dir)
            return try urls.map { item in
                let values = try item.resourceValues(forKeys: Set(keys))
                let name = values.name ?? item.lastPathComponent
                let isDir = values.isDirectory ?? false
                return FileEntry(
                    name: name,
                    path: StoragePath.joining(base, name),
                    isDir: isDir,
                    size: Int64(values.fileSize ?? 0),
                    modTime: values.contentModificationDate ?? .distantPast,
                    ext: isDir ? "" : StoragePath.ext(of: name)
                )
            }
        }
    }

    func stat(_ path: String) async throws -> FileEntry {
        try await withAccess {
            let url = try fileURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw StorageError.notFound(path)
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            let normalized = StoragePath.normalize(path)
            let isDir = values.isDirectory ?? false
            return FileEntry(
                name: normalized == "/" ? root.lastPathComponent : StoragePath.fileName(of: normalized),
                path: normalized,
                isDir: isDir,
                size: Int64(values.fileSize ?? 0),
                modTime: values.contentModificationDate ?? .distantPast,
                ext: isDir ? "" : StoragePath.ext(of: normalized)
            )
        }
    }

    func readStream(_ path: String, range: Range<Int64>?) async throws -> AsyncThrowingStream<Data, Error> {
        let url = try fileURL(for: path)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accessing = securityScoped && root.startAccessingSecurityScopedResource()
                    defer { if accessing { root.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }

                    let fileSize = Int64(try handle.seekToEnd())
                    var offset: Int64 = 0
                    var end = fileSize
                    if let range {
                        offset = max(0, min(range.lowerBound, fileSize))
                        end = max(offset, min(range.upperBound, fileSize))
                    }
                    try handle.seek(toOffset: UInt64(offset))

                    let chunkSize: Int64 = 256 * 1024
                    while offset < end, !Task.isCancelled {
                        let length = min(chunkSize, end - offset)
                        guard let data = try handle.read(upToCount: Int(length)), !data.isEmpty else { break }
                        offset += Int64(data.count)
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
        try await withAccess {
            let url = try fileURL(for: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            do {
                for try await chunk in data {
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
    }

    func move(_ src: String, _ dest: String) async throws {
        try await withAccess {
            try FileManager.default.moveItem(at: fileURL(for: src), to: fileURL(for: dest))
        }
    }

    func copy(_ src: String, _ dest: String) async throws {
        try await withAccess {
            try FileManager.default.copyItem(at: fileURL(for: src), to: fileURL(for: dest))
        }
    }

    func delete(_ path: String) async throws {
        try await withAccess {
            try FileManager.default.removeItem(at: fileURL(for: path))
        }
    }

    func mkdir(_ path: String) async throws {
        try await withAccess {
            try FileManager.default.createDirectory(at: fileURL(for: path), withIntermediateDirectories: true)
        }
    }

    func testConnection() async throws {
        _ = try await stat("/")
    }
}
