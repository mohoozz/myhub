import SwiftUI

/// 主题模式，持久化到 UserDefaults
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

    /// 导航栏返回箭头统一用主色
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
