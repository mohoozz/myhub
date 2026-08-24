import SwiftUI

/// 纯 txt 阅读器（全屏）：编码自动检测 + 全文滚动阅读 + 文本可选择复制；
/// 阅读排版（字号 / 行距 / 主题 / 衬线）实时生效并持久化；
/// 不建章节索引、不追踪进度，与小说阅读器区分（需要章节/进度走「以小说阅读器打开」）。
struct TxtReaderView: View {
    let context: TxtOpenContext

    @EnvironmentObject private var presenter: TxtReaderPresenter
    @StateObject private var viewModel: TxtReaderViewModel
    @State private var showSettings = false

    init(context: TxtOpenContext) {
        self.context = context
        _viewModel = StateObject(wrappedValue: TxtReaderViewModel(
            connection: context.connection, entry: context.entry
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            viewModel.themeSpec.background
                .ignoresSafeArea()

            content
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) {
            if showSettings { settingsPanel }
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(viewModel.themeSpec.secondaryText)
                Text("正在加载…")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.truncated {
                        Label("文件过大，仅显示前 \(Int(TextFileLoader.readerLimit) / (1024 * 1024))MB",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.bottom, 12)
                    }
                    Text(viewModel.text)
                        .font(bodyFont)
                        .foregroundStyle(viewModel.themeSpec.text)
                        .lineSpacing(CGFloat(viewModel.appearance.fontSize * (viewModel.appearance.lineSpacing - 1)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private var bodyFont: Font {
        let appearance = viewModel.appearance
        let size = CGFloat(appearance.fontSize)
        if appearance.useSerifFont {
            return Font.custom("NotoSerifSC-Regular", size: size)
        }
        return Font.system(size: size)
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { presenter.close() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(viewModel.themeSpec.text)
                    .frame(width: 36, height: 36)
                    .background(viewModel.themeSpec.controlBackground.opacity(0.92))
                    .clipShape(Circle())
            }

            VStack(spacing: 0) {
                Text(context.entry.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(viewModel.themeSpec.text)
                    .lineLimit(1)
                if !viewModel.encodingName.isEmpty {
                    Text(viewModel.encodingName)
                        .font(.caption2)
                        .foregroundStyle(viewModel.themeSpec.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                withAnimation(.appQuick) { showSettings.toggle() }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(viewModel.themeSpec.text)
                    .frame(width: 36, height: 36)
                    .background(viewModel.themeSpec.controlBackground.opacity(0.92))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 阅读设置面板

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读设置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.themeSpec.text)
                Spacer()
                Button {
                    withAnimation(.appQuick) { showSettings = false }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(viewModel.themeSpec.secondaryText)
                }
            }
            .padding(.bottom, 12)

            settingRow("字号") {
                HStack(spacing: 20) {
                    settingButton("minus.circle.fill", disabled: viewModel.appearance.fontSize <= 12) {
                        viewModel.adjustFont(-1)
                    }
                    Text("\(Int(viewModel.appearance.fontSize))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(viewModel.themeSpec.text)
                        .frame(width: 36)
                    settingButton("plus.circle.fill", disabled: viewModel.appearance.fontSize >= 28) {
                        viewModel.adjustFont(1)
                    }
                }
            }

            settingRow("行距") {
                HStack(spacing: 8) {
                    lineSpacingButton(1.4, "紧凑")
                    lineSpacingButton(1.6, "标准")
                    lineSpacingButton(2.0, "宽松")
                }
            }

            settingRow("主题") {
                HStack(spacing: 8) {
                    themeButton(.day, "日间", "sun.max")
                    themeButton(.eyeCare, "护眼", "leaf")
                    themeButton(.night, "夜间", "moon.stars")
                }
            }

            HStack {
                Text("衬线字体")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.themeSpec.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.appearance.useSerifFont },
                    set: { viewModel.setSerif($0) }
                ))
                .labelsHidden()
                .tint(AppColors.primary)
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(viewModel.themeSpec.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(viewModel.themeSpec.secondaryText.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func settingRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(viewModel.themeSpec.text)
            Spacer()
            content()
        }
        .padding(.vertical, 8)
    }

    private func settingButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(disabled ? viewModel.themeSpec.secondaryText.opacity(0.4) : viewModel.themeSpec.secondaryText)
        }
        .disabled(disabled)
    }

    private func lineSpacingButton(_ value: Double, _ title: String) -> some View {
        let selected = abs(viewModel.appearance.lineSpacing - value) < 0.001
        return Button {
            viewModel.setLineSpacing(value)
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : viewModel.themeSpec.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AppColors.primary : viewModel.themeSpec.background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func themeButton(_ theme: ReaderTheme, _ title: String, _ symbol: String) -> some View {
        let selected = viewModel.appearance.theme == theme
        return Button {
            viewModel.setTheme(theme)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(selected ? AppColors.primary : viewModel.themeSpec.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? AppColors.primary.opacity(0.12) : viewModel.themeSpec.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ViewModel

@MainActor
final class TxtReaderViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let entry: FileEntry

    @Published private(set) var state: State = .loading
    @Published private(set) var text = ""
    @Published private(set) var encodingName = ""
    @Published private(set) var truncated = false

    /// 阅读排版（改动即持久化，与小说阅读器共享 Reader 偏好）
    @Published var appearance: ReaderAppearance {
        didSet {
            guard appearance != oldValue else { return }
            AppSettings.Reader.fontSize = appearance.fontSize
            AppSettings.Reader.lineSpacing = appearance.lineSpacing
            AppSettings.Reader.theme = appearance.theme
            AppSettings.Reader.useSerifFont = appearance.useSerifFont
        }
    }

    var themeSpec: ReaderThemeSpec { ReaderThemeSpec.spec(for: appearance.theme) }

    private let adapter: StorageAdapter?
    private var loadTask: Task<Void, Never>?

    init(connection: Connection, entry: FileEntry) {
        self.entry = entry
        self.adapter = try? AdapterFactory.makeAdapter(for: connection)
        self.appearance = ReaderAppearance.current()
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in await self?.performLoad() }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func performLoad() async {
        guard let adapter else {
            state = .failed("连接源不可用，请检查连接配置")
            return
        }
        do {
            let loaded = try await TextFileLoader.load(
                adapter: adapter, path: entry.path, limit: TextFileLoader.readerLimit
            )
            text = loaded.text
            encodingName = loaded.encodingName
            truncated = loaded.truncated
            state = .ready
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - 排版调整

    func adjustFont(_ delta: Double) {
        var a = appearance
        a.fontSize = min(28, max(12, a.fontSize + delta))
        appearance = a
    }

    func setLineSpacing(_ value: Double) {
        var a = appearance
        a.lineSpacing = value
        appearance = a
    }

    func setTheme(_ theme: ReaderTheme) {
        var a = appearance
        a.theme = theme
        appearance = a
    }

    func setSerif(_ enabled: Bool) {
        var a = appearance
        a.useSerifFont = enabled
        appearance = a
    }
}
