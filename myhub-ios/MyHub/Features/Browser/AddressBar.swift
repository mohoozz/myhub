import SwiftUI
import UIKit

/// 地址栏（TODO §8.1，IOS-401）：
/// URL 智能识别（合法 URL 直接导航，否则走默认搜索引擎）、域名 + HTTPS 安全图标、聚焦全选。
///
/// 编辑态**由父级 `BrowserToolbar` 持有**（TODO 407）：Safari 风格——点击地址栏后整条操作栏
/// 让位给输入框（导航键 / 标签 / 菜单让出横向空间，右侧出「取消」），故编辑开关必须在父级可见，
/// 不能像此前那样封在本视图的私有 `@State` 里（那会让输入框只占中间一小块）。
struct AddressBar: View {
    @ObservedObject var tab: BrowserTab
    /// 是否处于编辑（输入）态：由父级驱动，外部置 false 即收起键盘退出编辑
    @Binding var isEditing: Bool
    /// 提交（导航）回调：由父视图交给 `BrowserSessionStore.open`
    var onSubmit: (URL) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                SelectableTextField(
                    text: $text,
                    placeholder: "搜索或输入网址",
                    onSubmit: submit,
                    onEndEditing: { isEditing = false }
                )
                .focused($focused)
                .font(.body)
            } else {
                securityIcon
                Text(displayHost)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .padding(.horizontal, 14)
        // 46pt 高：与操作栏 60pt 条高配比，满足 iOS 44pt 最小点击区（TODO 406）
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 胶囊内浅灰填充块（TODO 377 方案 A）：不再描边，靠填充色与白胶囊区分
        .background(Capsule().fill(AppColors.fieldFill))
        // 进入编辑的点击层只在非编辑态存在：若常驻，SwiftUI 的 tap 手势会抢走落在
        // `UITextField` 上的触摸，编辑态下便无法定位光标 / 选词 / 点清除键（TODO 407）
        .overlay {
            if !isEditing {
                Capsule()
                    .fill(.clear)
                    .contentShape(Capsule())
                    .onTapGesture { isEditing = true }
            }
        }
        // 编辑开关在父级，故焦点与文本预填统一由它驱动（无论点本视图还是外部取消/提交）
        .onChange(of: isEditing) { editing in
            if editing {
                text = tab.currentURL?.absoluteString ?? ""
                focused = true
            } else {
                focused = false
            }
        }
    }

    // MARK: - 派生

    private var displayHost: String {
        if let host = tab.currentURL?.host { return host }
        return tab.currentURL?.absoluteString ?? "搜索或输入网址"
    }

    @ViewBuilder
    private var securityIcon: some View {
        if let scheme = tab.currentURL?.scheme, scheme == "https" {
            Image(systemName: tab.hasOnlySecureContent ? "lock.fill" : "lock.slash")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else if tab.currentURL != nil {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - 行为

    private func submit() {
        guard let url = BrowserAddress.resolve(text) else { return }
        isEditing = false
        onSubmit(url)
    }
}

/// URL 智能识别：合法 URL 直接导航，否则走默认搜索引擎（IOS-401）
enum BrowserAddress {
    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 已带 http/https scheme
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        // 域名/IP（含点且无空格），或 localhost → 补全 https
        let lower = trimmed.lowercased()
        if !trimmed.contains(" "), (trimmed.contains(".") || lower == "localhost") {
            if let url = URL(string: "https://\(trimmed)"), url.host != nil {
                return url
            }
        }

        // 其余视为搜索词
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return AppSettings.Browser.searchEngine.searchURL(
            forQuery: query,
            customTemplate: AppSettings.Browser.customSearchTemplate
        )
    }
}

/// 聚焦全选的输入框：`UITextField` 在开始编辑时全选现有文本（IOS-401）
private struct SelectableTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    /// 结束编辑（失去焦点/键盘收起）回调：用于同步退出编辑模式
    var onEndEditing: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.keyboardType = .webSearch
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        // 允许在受限宽度下增长 / 收缩：长 URL 不再把固有宽度撑爆地址栏（TODO §396）
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// 宽度固定为提议宽度：`UITextField` 的固有宽度等于文本完整宽度，
    /// 若不约束，长 URL 会撑爆外层 `frame(maxWidth:)`（frame 不裁剪子视图）→ 输入框占满整屏（TODO §396）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: field.intrinsicContentSize.height)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text {
            field.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectableTextField

        init(_ parent: SelectableTextField) { self.parent = parent }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // 聚焦全选：延后到编辑状态建立后执行
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // 外部收起键盘（点页面/切搜索框/滚动）时同步退出编辑模式
            parent.onEndEditing()
        }
    }
}
