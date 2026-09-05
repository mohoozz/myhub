import Foundation

/// 漫画识别策略（IOS-207）：
/// 1. 扩展名优先：`.cbz` / `.cbr` 直接按漫画处理；
/// 2. 内容嗅探兜底：zip/rar 内图片占比 ≥ 90% 且文件名呈自然序列判定为漫画；
/// 3. epub 图集型判定：spine 抽样 XHTML 文本稀少且含插图（见 EpubBook.isComicSpine）；
/// 4. 手动覆盖：浏览页右键/长按菜单「以漫画阅读打开 / 以小说阅读打开」（见 BrowseDirectoryView）；
/// 5. 目录层预判：列目录时对 epub 判定并缓存，直接显示漫画徽标 + 打开走漫画阅读器（见 EpubComicCache）。
enum ComicDetector {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "avif"]

    /// 归档条目名是否为图片页
    static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains(StoragePath.ext(of: name))
    }

    /// 扩展名直接判定（cbz / cbr）
    static func isComicExtension(_ ext: String) -> Bool {
        ext == "cbz" || ext == "cbr"
    }

    /// 内容嗅探：图片占比 ≥ 90% 且存在自然序列命名（编号页）
    /// - Parameter entryNames: 归档内全部非目录条目名
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

/// epub 图集型（漫画）判定结果缓存（IOS-207 漫画识别策略 5）：
/// 目录层预判 epub 是否漫画，命中后直接显示漫画徽标 + 打开直接走漫画阅读器，
/// 避免「小说阅读器判定 → 转交漫画阅读器」的双重解包（大文件 Range 密集请求易触发 WebDAV 空响应）。
/// 键含文件 size/modTime，文件替换即失效。
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
