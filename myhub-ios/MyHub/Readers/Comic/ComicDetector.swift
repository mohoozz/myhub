import Foundation

/// 漫画识别策略
/// 1. 扩展名优先：`.cbz` / `.cbr` 直接按漫画处理
enum ComicDetector {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "avif"]

    /// 漫画阅读器实际能解析的「压缩包」扩展名（zip 走 RangeZipReader，rar 走 UnrarKit）。
    static let readableArchiveExtensions: Set<String> = ["zip", "rar"]

    /// 归档条目名是否为图片页
    static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains(StoragePath.ext(of: name))
    }

    /// 扩展名直接判定（cbz / cbr）
    static func isComicExtension(_ ext: String) -> Bool {
        ext == "cbz" || ext == "cbr"
    }

    /// 内容嗅探：图片占比 ≥ 90% 且存在自然序列命名（编号页）
    static func sniff(entryNames: [String]) -> Bool {
        let files = entryNames.filter { !$0.hasSuffix("/") }
        guard !files.isEmpty else { return false }
        let images = files.filter { isImageName($0) }
        guard Double(images.count) / Double(files.count) >= 0.9, !images.isEmpty else { return false }
        // 自然序列：至少半数图片文件名包含数字编号
        let numbered = images.filter { name in
            let stem = (name as NSString).deletingPathExtension
            return stem.rangeOfCharacter(from: .decimalDigits) != nil
        }
        return numbered.count * 2 >= images.count
    }
}

/// epub 图集型（漫画）判定结果缓存（漫画识别策略 5）
enum EpubComicCache {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "epub.comic."

    private static func key(connectionID: Int64, entry: FileEntry) -> String {
        "\(keyPrefix)\(connectionID)|\(entry.path)|\(entry.size)|\(Int64(entry.modTime.timeIntervalSince1970))"
    }

    /// 命中返回判定结果，未命中返回 nil
    static func lookup(connectionID: Int64, entry: FileEntry) -> Bool? {
        defaults.object(forKey: key(connectionID: connectionID, entry: entry)) as? Bool
    }

    static func store(_ isComic: Bool, connectionID: Int64, entry: FileEntry) {
        defaults.set(isComic, forKey: key(connectionID: connectionID, entry: entry))
    }
}
