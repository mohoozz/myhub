import SwiftUI

/// txt 在线编辑（IOS-103）：加载 → 编辑 → 保存回源。
/// 编码自动检测；保存优先沿用原编码（无法表示新内容时回退 UTF-8）。
struct TextFileEditorView: View {
    let entry: FileEntry
    let adapter: StorageAdapter
    /// 保存成功回调（刷新目录等）
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var encoding: String.Encoding = .utf8
    @State private var encodingName = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载…")
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(loadError)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(AppColors.pageBackground)
                        .padding(.horizontal, 8)
                }
            }
            .background(AppColors.pageBackground)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存").fontWeight(.semibold)
                        }
                    }
                    .disabled(isLoading || loadError != nil || isSaving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !encodingName.isEmpty {
                        Text(encodingName)
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("知道了", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let loaded = try await TextFileLoader.load(
                adapter: adapter, path: entry.path, limit: TextFileLoader.editLimit
            )
            text = loaded.text
            encoding = loaded.encoding
            encodingName = loaded.encodingName
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let data = TextEncodingDetector.encode(text, preferred: encoding)
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(data)
                continuation.finish()
            }
            try await adapter.writeStream(entry.path, data: stream)
            onSaved?()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
