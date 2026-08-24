import SwiftUI

/// 阅读器偏好（TODO §10 / IOS-502）：字号/行距/主题/翻页模式/漫画方向（含自动），持久化 AppSettings.Reader
struct ReaderPreferencesView: View {
    @State private var fontSize = AppSettings.Reader.fontSize
    @State private var lineSpacing = AppSettings.Reader.lineSpacing
    @State private var theme = AppSettings.Reader.theme
    @State private var pageMode = AppSettings.Reader.pageMode
    @State private var comicDirection = AppSettings.Reader.comicDirection
    @State private var useSerifFont = AppSettings.Reader.useSerifFont

    var body: some View {
        Form {
            Section("文字") {
                valueRow(title: "字号", value: "\(Int(fontSize))") {
                    Slider(value: $fontSize, in: 12...32, step: 1)
                }
                valueRow(title: "行距", value: String(format: "%.1f", lineSpacing)) {
                    Slider(value: $lineSpacing, in: 1.2...2.4, step: 0.1)
                }
                Toggle("正文宋体（思源宋体）", isOn: $useSerifFont)
            }
            Section("外观") {
                Picker("阅读主题", selection: $theme) {
                    Text("日间").tag(ReaderTheme.day)
                    Text("护眼").tag(ReaderTheme.eyeCare)
                    Text("夜间").tag(ReaderTheme.night)
                }
                Picker("翻页模式", selection: $pageMode) {
                    Text("翻页").tag(ReaderPageMode.paging)
                    Text("滚动").tag(ReaderPageMode.scrolling)
                }
                Picker("漫画阅读方向", selection: $comicDirection) {
                    Text("自动").tag(ComicReadingDirection.auto)
                    Text("从右向左").tag(ComicReadingDirection.rightToLeft)
                    Text("从左向右").tag(ComicReadingDirection.leftToRight)
                }
            } footer: {
                Text("此处为默认值，阅读器内仍可临时调整；漫画「自动」方向默认日漫从右向左。")
            }
        }
        .navigationTitle("阅读器偏好")
        .tint(AppColors.primary)
        .onChange(of: fontSize) { AppSettings.Reader.fontSize = $0 }
        .onChange(of: lineSpacing) { AppSettings.Reader.lineSpacing = $0 }
        .onChange(of: theme) { AppSettings.Reader.theme = $0 }
        .onChange(of: pageMode) { AppSettings.Reader.pageMode = $0 }
        .onChange(of: comicDirection) { AppSettings.Reader.comicDirection = $0 }
        .onChange(of: useSerifFont) { AppSettings.Reader.useSerifFont = $0 }
    }

    private func valueRow<Content: View>(
        title: String, value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            content()
        }
    }
}
