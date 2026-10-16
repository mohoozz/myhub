import SwiftUI

/// 主题模式（《需求分析文档》§2.2.3），持久化到 UserDefaults
enum AppThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "亮色"
        case .dark: return "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class ThemeManager: ObservableObject {
    private static let storageKey = "app.themeMode"

    @Published var mode: AppThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey) }
    }

    var colorScheme: ColorScheme? { mode.colorScheme }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        mode = AppThemeMode(rawValue: raw) ?? .system
    }
}

// MARK: - 全局外观

/// 启动时设一次、全app生效的 UIKit 外观（在 `MyHubApp.init` 里调动，必须早于任何导航栏创建）
enum GlobalAppearance {

    static func apply() {
        applyBackIndicator()
    }

    /// 导航栏返回箭头统一用主色（TODO 404 附带）
    ///
    /// **为什么需要这层**：iOS 26（Liquid Glass）下系统返回按钮**不再吃 `tintColor`**。暗色实测三件事：
    /// 1. 默认（不设任何色）返回箭头与栏内 item 都是**白**的——不是本页特有问题；
    /// 2. 页面级 `.tint(AppColors.primary)` 只让 **SwiftUI 自己声明的 item** 变蓝（栏内右侧那种），
    ///    返回箭头照旧白；`navigationBar.tintColor` 本来就是蓝的，也一样照旧白；
    /// 3. `UIBarButtonItem.appearance().tintColor`（社区给的那招）**逐字节没有任何变化**。
    /// Apple 论坛同题帖 developer.apple.com/forums/thread/788176 至今无解，`UIBarButtonItemAppearance`
    /// 也没有任何字形配色属性（SDK 里只有 `titleTextAttributes` / `backgroundImage`）。
    ///
    /// **做法**：按钮本身不动（点按返回、左缘侧滑都还是系统实现），只把**栏级返回指示图**换成自带主色的
    /// 那张——`.alwaysOriginal` 让箭头带自己的颜色，不必再指望 tint。
    private static func applyBackIndicator() {
        // 尺寸/字重按系统返回箭头来（17 semibold），换图不改观感，只改颜色
        guard let chevron = UIImage(
            systemName: "chevron.backward",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )?.withTintColor(AppColors.primaryUIColor, renderingMode: .alwaysOriginal) else { return }

        UINavigationBar.appearance().backIndicatorImage = chevron
        UINavigationBar.appearance().backIndicatorTransitionMaskImage = chevron
    }
}
