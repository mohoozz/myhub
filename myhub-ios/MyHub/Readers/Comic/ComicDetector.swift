import Foundation

/// 漫画识别策略（IOS-207）：
/// 1. 扩展名优先：`.cbz` / `.cbr` 直接按漫画处理；
/// 2. 内容嗅探兜底：zip/rar/epub 内图片占比 ≥ 90% 且文件名呈自然序列判定为漫画；
/// 3. 手动覆盖：浏览页右键/长按菜单「以漫画阅读打开」（见 BrowseDirectoryView）。
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
