import AVFoundation

/// 格式探测与引擎自动路由（《需求分析文档》§4.3：探测容器/编码选择引擎）。
/// 设置可强制硬解/软解（AppSettings.Player.decodePreference）；
/// 自动模式下硬解起播失败由 PlayerCore 回退软解。
enum EngineRouter {
    /// 原生硬解优先（系统可播容器/编码：H.264/HEVC/AAC/ALAC…）
    static let nativeExtensions: Set<String> = [
        "mp4", "m4v", "mov", "3gp",
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "caf"
    ]

    /// 软解兜底（非原生容器/编码）
    static let softExtensions: Set<String> = [
        "mkv", "avi", "flv", "rmvb", "rm", "ts", "m2ts", "wmv", "vob",
        "mpg", "mpeg", "ogg", "ogm", "ape", "dts", "mka", "asf", "divx"
    ]

    /// 引擎路由：偏好强制 > 扩展名集合 > 原生可播性探测（webm 等不确定容器）
    static func resolve(url: URL, preference: DecodePreference) async -> PlayerEngineKind {
        switch preference {
        case .hardware:
            return .hardware
        case .software:
            return .software
        case .auto:
            let ext = url.pathExtension.lowercased()
            if softExtensions.contains(ext) { return .software }
            if nativeExtensions.contains(ext) { return .hardware }
            // 未知 / 部分支持容器（如 webm）：探测原生可播性，不可播回退软解
            return await canPlayNatively(url: url) ? .hardware : .software
        }
    }

    /// 探测原生可播性（带超时，避免远端 URL 探测长时间阻塞起播）
    private static func canPlayNatively(url: URL, timeout: TimeInterval = 5) async -> Bool {
        let asset = AVURLAsset(url: url)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await asset.load(.isPlayable)) ?? false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
