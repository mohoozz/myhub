import Foundation

/// 媒体类型与扩展名识别（《需求分析文档》§8.1）
enum MediaType: String, Codable, CaseIterable {
    case video, audio, novel, comic, image, subtitle, other

    /// 中文类型标签（列表副标题用）
    var label: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .novel: return "小说"
        case .comic: return "漫画"
        case .image: return "图片"
        case .subtitle: return "字幕"
        case .other: return "文件"
        }
    }

    static func detect(ext: String) -> MediaType {
        switch ext.lowercased() {
        case "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "rmvb", "ts", "wmv", "m2ts", "vob":
            return .video
        case "mp3", "m4a", "flac", "wav", "ogg", "ape", "aac":
            return .audio
        case "txt", "epub":
            return .novel
        case "zip", "cbz", "rar", "cbr":
            return .comic
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return .image
        case "srt", "ass", "ssa":
            return .subtitle
        default:
            return .other
        }
    }
}
