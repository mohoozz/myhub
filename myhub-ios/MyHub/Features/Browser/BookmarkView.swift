import SwiftUI

/// 书签管理页（TODO §8.3，IOS-402）：列表 / 搜索 / 编辑 / 删除。
struct BookmarkView: View {
    @EnvironmentObject private var dataStore: BrowserDataStore
    @Environment(\.dismiss) private var dismiss
    var onOpen: (URL) -> Void

    @State private var searchText = ""
    @State private var editingBookmark: Bookmark?

    private var filtered: [Bookmark] {
        guard !searchText.isEmpty else { return dataStore.bookmarks }
        return dataStore.bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { bookmark in
                            row(bookmark)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                dataStore.removeBookmark(filtered[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "搜索书签")
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingBookmark) { bookmark in
                BookmarkEditorView(bookmark: bookmark) { title, url in
                    var updated = bookmark
                    updated.title = title
                    updated.url = url
                    dataStore.updateBookmark(updated)
                }
            }
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 12) {
            favicon(bookmark)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(bookmark.url)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: bookmark.url) {
                onOpen(url)
                dismiss()
            }
        }
        .contextMenu {
            Button {
                editingBookmark = bookmark
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                dataStore.removeBookmark(bookmark)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func favicon(_ bookmark: Bookmark) -> some View {
        if let url = faviconURL(for: bookmark) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    fallback
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "bookmark.fill")
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: 24, height: 24)
    }

    private func faviconURL(for bookmark: Bookmark) -> URL? {
        if let favicon = bookmark.favicon, let url = URL(string: favicon) { return url }
        guard let host = URL(string: bookmark.url)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "暂无书签" : "未找到相关书签")
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground)
    }
}

/// 书签编辑表单
private struct BookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    let onSave: (String, String) -> Void

    @State private var titleText: String
    @State private var urlText: String

    init(bookmark: Bookmark, onSave: @escaping (String, String) -> Void) {
        self.bookmark = bookmark
        self.onSave = onSave
        _titleText = State(initialValue: bookmark.title)
        _urlText = State(initialValue: bookmark.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("标题", text: $titleText)
                }
                Section("网址") {
                    TextField("https://…", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("编辑书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            titleText.trimmingCharacters(in: .whitespaces),
                            urlText.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
