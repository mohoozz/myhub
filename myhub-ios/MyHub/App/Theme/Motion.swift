import SwiftUI

/// 轻量过渡（≤ 200ms，《需求分析文档》§2.10），不使用复杂动画。
extension Animation {
    /// 常规过渡（180ms）
    static let appQuick = Animation.easeInOut(duration: 0.18)
    /// 按压反馈（150ms）
    static let appFast = Animation.easeOut(duration: 0.15)
    /// 轻量弹性（页签选中回弹等，约 180ms 主振）
    static let appPop = Animation.spring(response: 0.28, dampingFraction: 0.62)
}
