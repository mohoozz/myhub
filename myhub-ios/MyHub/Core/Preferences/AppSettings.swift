import Combine
import Foundation

/// UserDefaults 属性包装
@propertyWrapper
struct UserDefault<Value> {
    let key: String
    let defaultValue: Value

    init(_ key: String, `default` defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// RawRepresentable(String) 枚举的 UserDefaults 属性包装
@propertyWrapper
struct RawUserDefault<Value: RawRepresentable> where Value.RawValue == String {
    let key: String
    let defaultValue: Value

    init(_ key: String, `default` defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return defaultValue }
            return Value(rawValue: raw) ?? defaultValue
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - 偏好枚举

enum ReaderTheme: String, CaseIterable, Codable {
    case auto, day, night, eyeCare   // 跟随系统 / 日间 / 夜间 / 护眼
}

enum ReaderPageMode: String, CaseIterable, Codable {
    case paging, scrolling     // 翻页 / 滚动
}

enum ComicReadingDirection: String, CaseIterable, Codable {
    case auto, rightToLeft, leftToRight   // 自动（横屏/平板默认双页 RTL）
}

enum DecodePreference: String, CaseIterable, Codable {
    case auto, hardware, software   // 自动 / 强制硬解 / 强制软解
}

/// 播放器横竖屏切换方式（TODO §10：设置 → 播放器偏好）
enum PlayerOrientationMode: String, CaseIterable, Codable {
    case manual, auto   // 手动：点按钮切换并缓存方向；自动：跟随设备横放/竖放
}

/// 内嵌文本字幕（软解 VLC 渲染路径）的字符编码（TODO 412）：
/// 动漫内嵌 srt 常见 GBK/Big5，VLC 自动探测偶有误判导致乱码，可在此强制指定。
/// 外挂字幕不受影响——由 App 自己用 `TextEncodingDetector` 解码并浮层渲染。
enum SubtitleTextEncoding: String, CaseIterable, Codable {
    case auto, utf8, gb18030, big5, shiftJIS

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .utf8: return "UTF-8"
        case .gb18030: return "简体中文（GB18030）"
        case .big5: return "繁体中文（Big5）"
        case .shiftJIS: return "日文（Shift-JIS）"
        }
    }

    /// libvlc `subsdec-encoding` 取值（iconv 名称）；nil = 交给 VLC 自动探测
    var vlcEncodingName: String? {
        switch self {
        case .auto: return nil
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift_JIS"
        }
    }
}

enum SearchEngine: String, CaseIterable, Codable {
    case google, bing, baidu, custom

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .baidu: return "百度"
        case .custom: return "自定义"
        }
    }

    /// query 已 URL 编码；custom 模板以 %@ 占位
    func searchURL(forQuery query: String, customTemplate: String) -> URL? {
        let template: String
        switch self {
        case .google: template = "https://www.google.com/search?q=%@"
        case .bing: template = "https://www.bing.com/search?q=%@"
        case .baidu: template = "https://www.baidu.com/s?wd=%@"
        case .custom: template = customTemplate
        }
        guard template.contains("%@") else { return nil }
        return URL(string: template.replacingOccurrences(of: "%@", with: query))
    }
}

enum BrowserUserAgent: String, CaseIterable, Codable {
    case platform, desktop, mobile   // 跟随平台 / 桌面 / 移动
}

// MARK: - 偏好封装（IOS-502 / 503 / 504，主题见 ThemeManager）

enum AppSettings {
    /// 阅读器偏好
    enum Reader {
        @UserDefault("reader.fontSize", default: 17) static var fontSize: Double
        @UserDefault("reader.lineSpacing", default: 1.6) static var lineSpacing: Double
        @RawUserDefault("reader.theme", default: .auto) static var theme: ReaderTheme
        @RawUserDefault("reader.pageMode", default: .paging) static var pageMode: ReaderPageMode
        @RawUserDefault("reader.comicDirection", default: .auto) static var comicDirection: ComicReadingDirection
        @RawUserDefault("reader.comicMode", default: .webtoon) static var comicMode: ComicReadMode
        @UserDefault("reader.brightness", default: -1) static var brightness: Double   // -1 = 跟随系统
        @UserDefault("reader.useSerifFont", default: false) static var useSerifFont: Bool   // 正文思源宋体（未打包字体时回退系统宋体）

        /// 一次性迁移：旧版固定三档主题（日间/夜间/护眼）统一迁移为「跟随系统」，
        /// 使阅读器背景与 App 浅色/深色主题对齐。
        static func migrateReaderThemeToAutoIfNeeded() {
            let flagKey = "reader.theme.migrated.to.auto.v1"
            guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
            UserDefaults.standard.set(true, forKey: flagKey)
            theme = .auto
        }
    }

    /// 播放器偏好
    enum Player {
        @UserDefault("player.defaultSpeed", default: 1.0) static var defaultSpeed: Double
        @RawUserDefault("player.decodePreference", default: .auto) static var decodePreference: DecodePreference
        /// 前向缓冲目标（秒）：AVPlayer `preferredForwardBufferDuration` 与软解 `network-caching` 的取值来源。
        /// 旧默认 30s 在高码率片源下会让播放器满速缓冲上百 MB（且全部经代理落盘缓存），是真机发热主因之一，
        /// 故下调为 10s（弱网抗抖动由代理侧预读 + 播放器自身重试承担）。
        @UserDefault("player.preloadSeconds", default: 10) static var preloadSeconds: Double
        /// 前向缓冲硬上限（秒）：无论用户把预读窗口调多大，播放器实际缓冲目标都不超过此值——
        /// 代理侧预读已固定 3MB，播放器再囤过多数据只会持续下载 + 反复写盘（发热）。
        static let forwardBufferCapSeconds: Double = 12
        @UserDefault("player.audioOnlyByDefault", default: false) static var audioOnlyByDefault: Bool
        @UserDefault("player.volumeStep", default: 0.05) static var volumeStep: Double   // iOS 音量步进，默认 5%
        @UserDefault("player.subtitleFontSize", default: 16) static var subtitleFontSize: Double
        @UserDefault("player.subtitleDelay", default: 0) static var subtitleDelay: Double
        /// 内嵌文本字幕编码（软解 VLC 渲染路径）；默认交给 VLC 自动探测（TODO 412）
        @RawUserDefault("player.embeddedSubtitleEncoding", default: .auto) static var embeddedSubtitleEncoding: SubtitleTextEncoding
        @UserDefault("player.seekStepSeconds", default: 10) static var seekStepSeconds: Double   // 快进/快退步进
        /// App 退后台时自动进入画中画（默认关闭；仅硬解 AVPlayer 路径生效）
        @UserDefault("player.autoPiPOnBackground", default: false) static var autoPiPOnBackground: Bool
        /// 横竖屏切换方式（手动 / 自动）
        @RawUserDefault("player.orientationMode", default: .manual) static var orientationMode: PlayerOrientationMode
        /// 手动模式下缓存的方向偏好（true = 横屏）：退出播放页不重置，下次播放沿用
        @UserDefault("player.landscapePreferred", default: false) static var landscapePreferred: Bool

        /// 一次性迁移（发热优化）：旧默认预读窗口 30s 会让播放器与代理持续满速下载并写盘。
        /// 只下调「从未改过」的旧默认值（== 30），用户手动调过的值保持不动。
        static func migratePreloadWindowIfNeeded() {
            let flagKey = "player.preloadSeconds.migrated.v1"
            guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
            UserDefaults.standard.set(true, forKey: flagKey)
            if let stored = UserDefaults.standard.object(forKey: "player.preloadSeconds") as? Double,
               abs(stored - 30) < 0.001 {
                preloadSeconds = 10
            }
        }
    }

    /// 浏览器偏好
    enum Browser {
        @RawUserDefault("browser.searchEngine", default: .bing) static var searchEngine: SearchEngine
        @UserDefault("browser.customSearchTemplate", default: "") static var customSearchTemplate: String
        @RawUserDefault("browser.userAgent", default: .platform) static var userAgent: BrowserUserAgent
        @UserDefault("browser.privateMode", default: false) static var privateMode: Bool
        /// 长按链接「在新标签页中打开」/ `target=_blank` / `window.open` 后是否立即切换到新标签（TODO 408）。
        /// 开启（默认）= 新开即跳转；关闭 = 仅后台新开，停留在当前页面继续浏览（对应 Safari「在后台打开」）。
        @UserDefault("browser.openNewTabInForeground", default: true) static var openNewTabInForeground: Bool
        /// 沉浸态左下角退出钮的首启提示气泡是否已展示过（「退出全屏」，仅提示一次）
        @UserDefault("browser.exitHandleTipShown", default: false) static var exitHandleTipShown: Bool
    }

    /// 缓存偏好（IOS-504 / 605）
    enum Cache {
        @UserDefault("cache.totalLimitMB", default: 2048) static var totalLimitMB: Int
        @UserDefault("cache.contentCachingEnabled", default: true) static var contentCachingEnabled: Bool
    }

    /// 回收站（IOS-106）
    enum Trash {
        @UserDefault("trash.retentionDays", default: 30) static var retentionDays: Int
    }

    /// 安全（IOS-501：应用锁）
    enum Security {
        @UserDefault("security.appLockEnabled", default: false) static var appLockEnabled: Bool
    }

    /// 文件浏览偏好（IOS-102：排序与路径显示设置缓存）
    enum Browse {
        @RawUserDefault("browse.sortKey", default: .name) static var sortKey: BrowseSortKey
        @UserDefault("browse.sortAscending", default: true) static var sortAscending: Bool
        @RawUserDefault("browse.viewMode", default: .grid) static var viewMode: BrowseViewMode
    }

    /// 收藏页偏好（IOS-107）
    enum Favorites {
        @RawUserDefault("favorites.viewMode", default: .grid) static var viewMode: BrowseViewMode
    }

    /// 正在阅读页偏好（IOS-209）
    enum Reading {
        @RawUserDefault("reading.viewMode", default: .grid) static var viewMode: BrowseViewMode
    }
}

/// 浏览排序键
enum BrowseSortKey: String, CaseIterable, Codable {
    case name, size, modTime

    var displayName: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .modTime: return "修改时间"
        }
    }
}

/// 浏览视图模式
enum BrowseViewMode: String, CaseIterable, Codable {
    case grid, list

    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - 浏览显示偏好（即时响应版）

/// 文件名行数等浏览显示偏好的集中发布源（IOS-102）。
///
/// 说明：仅用 `@AppStorage` 时值会正常写入 UserDefaults，但在部分系统版本下
/// 已存活的视图（如常驻的浏览/收藏网格、设置页 Picker）不会收到刷新，
/// 需切换主题等操作触发整体重绘后才生效；改用 `@Published` 统一发布后，
/// 设置页标签与网格标题行数可即时更新。
final class BrowseDisplaySettings: ObservableObject {
    static let shared = BrowseDisplaySettings()

    /// 文件名标题行数（1~5）
    @Published var fileNameLines: Int {
        didSet {
            guard fileNameLines != oldValue else { return }
            UserDefaults.standard.set(fileNameLines, forKey: "browse.fileNameLines")
        }
    }

    private init() {
        fileNameLines = UserDefaults.standard.object(forKey: "browse.fileNameLines") as? Int ?? 3
    }
}
