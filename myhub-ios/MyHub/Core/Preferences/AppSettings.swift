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
    case day, night, eyeCare   // 日间 / 夜间 / 护眼
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
        @RawUserDefault("reader.theme", default: .day) static var theme: ReaderTheme
        @RawUserDefault("reader.pageMode", default: .paging) static var pageMode: ReaderPageMode
        @RawUserDefault("reader.comicDirection", default: .auto) static var comicDirection: ComicReadingDirection
        @UserDefault("reader.brightness", default: -1) static var brightness: Double   // -1 = 跟随系统
        @UserDefault("reader.useSerifFont", default: false) static var useSerifFont: Bool   // 正文思源宋体（未打包字体时回退系统宋体）
    }

    /// 播放器偏好
    enum Player {
        @UserDefault("player.defaultSpeed", default: 1.0) static var defaultSpeed: Double
        @RawUserDefault("player.decodePreference", default: .auto) static var decodePreference: DecodePreference
        @UserDefault("player.preloadSeconds", default: 30) static var preloadSeconds: Double
        @UserDefault("player.audioOnlyByDefault", default: false) static var audioOnlyByDefault: Bool
        @UserDefault("player.volumeStep", default: 0.05) static var volumeStep: Double   // iOS 音量步进，默认 5%
        @UserDefault("player.subtitleFontSize", default: 16) static var subtitleFontSize: Double
        @UserDefault("player.subtitleDelay", default: 0) static var subtitleDelay: Double
        @UserDefault("player.seekStepSeconds", default: 10) static var seekStepSeconds: Double   // 双击快进/快退
    }

    /// 浏览器偏好
    enum Browser {
        @RawUserDefault("browser.searchEngine", default: .bing) static var searchEngine: SearchEngine
        @UserDefault("browser.customSearchTemplate", default: "") static var customSearchTemplate: String
        @RawUserDefault("browser.userAgent", default: .platform) static var userAgent: BrowserUserAgent
        @UserDefault("browser.privateMode", default: false) static var privateMode: Bool
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
        /// 各连接源最后浏览路径（key = connectionID），二次进入恢复
        @UserDefault("browse.lastPaths", default: [:]) static var lastPaths: [String: String]
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
