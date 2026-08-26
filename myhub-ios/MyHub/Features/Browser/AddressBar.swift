import SwiftUI
import UIKit

/// 地址栏（TODO §8.1，IOS-401）：
/// URL 智能识别（合法 URL 直接导航，否则走默认搜索引擎）、域名 + HTTPS 安全图标、聚焦全选。
struct AddressBar: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var dataStore: BrowserDataStore
    /// 提交（导航）回调：由父视图交给 `BrowserSessionStore.open`
    var onSubmit: (URL) -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                SelectableTextField(
                    text: $text,
                    placeholder: "搜索或输入网址",
                    onSubmit: submit,
                    onEndEditing: { isEditing = false }
                )
                .focused($focused)
                .font(.subheadline)
            } else {
                securityIcon
                Text(displayHost)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
                bookmarkButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !isEditing else { return }
            beginEditing()
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

    // MARK: - 书签（TODO §8.3 星标收藏）

    private var isBookmarked: Bool {
        guard let url = tab.currentURL else { return false }
        return dataStore.isBookmarked(url.absoluteString)
    }

    private var bookmarkButton: some View {
        Button {
            guard let url = tab.currentURL else { return }
            let title = tab.title.isEmpty ? (url.host ?? url.absoluteString) : tab.title
            dataStore.toggleBookmark(
                title: title,
                url: url.absoluteString,
                favicon: tab.faviconURL?.absoluteString
            )
        } label: {
            Image(systemName: isBookmarked ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(isBookmarked ? AppColors.primary : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(tab.currentURL == nil)
    }

    // MARK: - 行为

    private func beginEditing() {
        text = tab.currentURL?.absoluteString ?? ""
        isEditing = true
        focused = true
    }

    private func submit() {
        guard let url = BrowserAddress.resolve(text) else { return }
        isEditing = false
        focused = false
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
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
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
