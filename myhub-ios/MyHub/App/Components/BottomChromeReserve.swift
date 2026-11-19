import SwiftUI

/// 为滚动内容末尾预留「全局底部装饰」（悬浮页签栏 / mini 播放器）自身的空间（TODO 425，方案 A）。
///
/// 背景：TODO 376 把页签栏改成经 `RootView` 的 `safeAreaInset` 注入的悬浮圆角胶囊后，
/// 页面内 `NavigationStack` 里的滚动容器（`ScrollView` / `List`）拿到的底部安全区只有
/// Home 指示条、并不包含这条胶囊（与 `RootView.bottomChromeHeight` 的说明同源）。
/// 于是列表末尾没有可滚出的空间——滚到底时最后一行 / 最后一个选项永久停在胶囊下方，
/// 透过半透明玻璃看得见、却点不到（文件越多越容易踩到）。
///
/// 做法：在滚动容器上挂本修饰器，等于在内容末尾补一段「装饰高度 + 呼吸间距」的透明占位，
/// 滚到底时最后一行正好停在胶囊上方 12pt。内容仍然从胶囊下方穿过（玻璃透出、层次保留），
/// 现状的视觉语言不变。
///
/// 不要给覆盖层（多选操作栏 / 传输横幅 / 轻提示）加本修饰器：它们是 `overlay` + 自己按
/// `bottomChromeHeight` 抬升的，再加一层会双重留白（见 TODO 379）。
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

    /// 需要预留的高度：装饰隐藏 / 高度为 0（iPad 无页签栏）时不留白，
    /// 否则底部本该让给页面自己的操作栏，凭空多出的 12pt 会把操作栏顶离底部。
    private var reserve: CGFloat {
        guard !bottomTabBarHidden.wrappedValue, bottomChromeHeight > 0 else { return 0 }
        return bottomChromeHeight + extra
    }
}

extension View {
    /// 滚动内容末尾预留底部装饰空间，滚到底时最后一行停在悬浮胶囊上方（TODO 425）
    func reservedBottomChrome(extra: CGFloat = 12) -> some View {
        modifier(BottomChromeReserve(extra: extra))
    }
}
