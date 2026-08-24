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
