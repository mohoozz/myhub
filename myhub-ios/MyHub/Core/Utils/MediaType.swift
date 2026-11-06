import Foundation

/// 媒体类型与扩展名识别（《需求分析文档》§8.1）
enum MediaType: String, Codable, CaseIterable {
    case video, audio, novel, comic, archive, image, subtitle, other

    /// 中文类型标签（列表副标题、类型徽标共用）
    var label: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .novel: return "小说"
        case .comic: return "漫画"
        case .archive: return "压缩包"
        case .image: return "图片"
        case .subtitle: return "字幕"
        case .other: return "文件"
        }
    }

    /// 归档类（漫画 / 压缩包）：封面、徽标、打开分发常需一起判断
    var isArchiveLike: Bool {
        self == .comic || self == .archive
    }

    static func detect(ext: String) -> MediaType {
        switch ext.lowercased() {
        case "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "rmvb", "ts", "wmv", "m2ts", "vob":
            return .video
        case "mp3", "m4a", "flac", "wav", "ogg", "ape", "aac":
            return .audio
        case "txt", "epub":
            return .novel
        // 漫画专用扩展名：直接按漫画展示
        case "cbz", "cbr":
            return .comic
        // 通用压缩包：内容可能是图集，但 UI 上仍按压缩包展示（打开时再嗅探）
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst":
            return .archive
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return .image
        case "srt", "ass", "ssa":
            return .subtitle
        default:
            return .other
        }
    }
}
