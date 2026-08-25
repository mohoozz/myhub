import SwiftUI

/// 浏览历史页（TODO §8.3，IOS-403）：按日分组 / 搜索 / 单条删除 / 清空。
struct HistoryView: View {
    @EnvironmentObject private var dataStore: BrowserDataStore
    @Environment(\.dismiss) private var dismiss
    var onOpen: (URL) -> Void

    @State private var searchText = ""
    @State private var showingClearConfirm = false

    private struct DayGroup: Identifiable {
        let day: Date
        let items: [BrowserHistory]
        var id: Date { day }

        var label: String {
            if Calendar.current.isDateInToday(day) { return "今天" }
            if Calendar.current.isDateInYesterday(day) { return "昨天" }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: day)
        }
    }

    private var groups: [DayGroup] {
        let source = searchText.isEmpty
            ? dataStore.history
            : dataStore.history.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.url.localizedCaseInsensitiveContains(searchText)
            }
        let grouped = Dictionary(grouping: source) { Calendar.current.startOfDay(for: $0.visitedAt) }
        return grouped.map { day, items in
            DayGroup(day: day, items: items.sorted { $0.visitedAt > $1.visitedAt })
        }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groups) { group in
                            Section(group.label) {
                                ForEach(group.items) { item in
                                    row(item)
                                }
                                .onDelete { offsets in
                                    let items = group.items
                                    for index in offsets {
                                        dataStore.removeHistory(items[index])
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "搜索历史")
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !dataStore.history.isEmpty {
                        Button("清空", role: .destructive) {
                            showingClearConfirm = true
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("确定清空全部历史记录？", isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { dataStore.clearHistory() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func row(_ item: BrowserHistory) -> some View {
        HStack(spacing: 12) {
            favicon(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.url : item.title)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(item.url)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: item.url) {
                onOpen(url)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func favicon(_ item: BrowserHistory) -> some View {
        if let url = faviconURL(for: item) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    fallback
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "clock")
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
            .frame(width: 22, height: 22)
    }

    private func faviconURL(for item: BrowserHistory) -> URL? {
        if let favicon = item.favicon, let url = URL(string: favicon) { return url }
        guard let host = URL(string: item.url)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "暂无历史记录" : "未找到相关记录")
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground)
    }
}
