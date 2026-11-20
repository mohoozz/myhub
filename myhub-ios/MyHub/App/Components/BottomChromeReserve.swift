import SwiftUI

/// 为滚动内容末尾预留「全局底部装饰」（悬浮页签栏 / mini 播放器）自身的空间。
struct BottomChromeReserve: ViewModifier {
    @Environment(\.bottomChromeHeight) private var bottomChromeHeight

    /// 额外呼吸间距（默认 12pt）：让最后一行与胶囊描边之间留一点缝，不贴在一起
    var extra: CGFloat = 12

    /// 多选态等场景下页面主动隐藏了页签栏（`RootView` 里装饰整体让位给多选操作栏）
    @Environment(\.bottomTabBarHidden) private var bottomTabBarHidden

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: reserve)
        }
    }

    /// 需要预留的高度：装饰隐藏 / 高度为 0（iPad 无页签栏）时不留白
    private var reserve: CGFloat {
        guard !bottomTabBarHidden.wrappedValue, bottomChromeHeight > 0 else { return 0 }
        return bottomChromeHeight + extra
    }
}

extension View {
    /// 滚动内容末尾预留底部装饰空间，滚到底时最后一行停在悬浮胶囊上方
    func reservedBottomChrome(extra: CGFloat = 12) -> some View {
        modifier(BottomChromeReserve(extra: extra))
    }
}
