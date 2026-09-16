import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// 亮/暗双值颜色
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// 色板常量（《需求分析文档》§2.10）
enum AppColors {
    static let primary = Color(light: Color(hex: 0x2563EB), dark: Color(hex: 0x3B82F6))
    /// 主界面背景：纯白（TODO 376，原浅蓝灰 #EEF4FB）；白底下卡片靠 `cardBorder` 1pt 描边界定
    static let pageBackground = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x000000))
    static let cardBackground = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x121212))
    /// 白底卡片极浅描边：页面背景改白后用于区分卡片与背景（TODO 376）
    static let cardBorder = Color(light: Color(hex: 0xEDF0F3), dark: Color(hex: 0x262626))
    /// 底部页签栏灰边框：与白色主界面分割（TODO 376 方案 C 悬浮圆角胶囊）
    static let tabBarBorder = Color(light: Color(hex: 0xD1D5DB), dark: Color(hex: 0x3A3A3C))
    static let sidebarBackground = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x0A0A0A))
    static let textPrimary = Color(light: Color(hex: 0x1A1A2E), dark: Color(hex: 0xE0E0E0))
    static let textSecondary = Color(light: Color(hex: 0x6B7280), dark: Color(hex: 0x888888))
    static let separator = Color(light: Color(hex: 0xE5E7EB), dark: Color(hex: 0x1E1E1E))
    static let highlightBackground = Color(light: Color(hex: 0xEEF4FB), dark: Color(hex: 0x1A2744))
    /// 播放器/阅读器等沉浸场景统一纯黑
    static let immersiveBackground = Color.black
}
