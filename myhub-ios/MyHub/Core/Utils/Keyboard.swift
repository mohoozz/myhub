import UIKit

/// 键盘工具：统一收起键盘（点击空白处退出输入法）
enum Keyboard {
    /// 结束所有输入视图的编辑并收起键盘；无键盘时调用无副作用（幂等）。
    static func dismiss() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
            .forEach { $0.endEditing(true) }
    }
}
