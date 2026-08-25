import SwiftUI

/// 左对齐导航栏标题（iOS 26 起系统 inline 标题默认居中显示）。
/// 通过 principal + .toolbarRole(.editor) 实现左对齐纯文本：不触发 Liquid Glass 按钮背景，
/// 且只作用于当前页面，不影响二级页面的返回按钮与居中标题。字体还原为系统标题样式（.headline）。
struct LeadingNavTitleModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .toolbarRole(.editor)
    }
}

extension View {
    /// 将导航栏标题左对齐显示在左上角，替代系统居中的 inline 标题。
    func leadingNavTitle(_ title: String) -> some View {
        modifier(LeadingNavTitleModifier(title: title))
    }
}
