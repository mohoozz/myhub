import SwiftUI
import UIKit

extension StorageAdapter {
    /// 收集文件内容为 Data（可选 Range + 字节上限），供图片预览/文本查看等一次性读取场景
    func readAll(_ path: String, range: Range<Int64>? = nil, limit: Int64 = 64 * 1024 * 1024) async throws -> Data {
        let stream = try await readStream(path, range: range)
        var data = Data()
        for try await chunk in stream {
            if Task.isCancelled { throw CancellationError() }
            data.append(chunk)
            if Int64(data.count) > limit { throw StorageError.invalidPath("读取超过上限") }
        }
        return data
    }
}

/// 纯图片预览（IOS-706）：独立界面，与漫画阅读器区分。
/// 切换方式：左右滑动 / 点击左右分区 / 外接键盘 ← → / 底部浮动按钮；点击图片区显隐工具层。
struct ImagePreviewView: View {
    let images: [FileEntry]          // 同目录全部图片（自然序）
    let initialIndex: Int
    let adapter: StorageAdapter

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true

    init(images: [FileEntry], initialIndex: Int, adapter: StorageAdapter) {
        self.images = images
        self.initialIndex = initialIndex
        self.adapter = adapter
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                // 左右滑动翻页
                TabView(selection: $index) {
                    ForEach(Array(images.enumerated()), id: \.element.path) { i, entry in
                        RemoteImagePage(entry: entry, adapter: adapter)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                // 键盘 ← →（iPad/外接键盘）
                KeyboardNavigationBridge(onLeft: previous, onRight: next)
                    .frame(width: 0, height: 0)

                // 顶部 / 底部工具层
                if chromeVisible {
                    topBar
                        .transition(.opacity)
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 分区点击：左 25% 上一张 / 右 25% 下一张 / 中间显隐工具层
            // simultaneousGesture 不拦截 TabView 的翻页拖拽
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    let ratio = value.location.x / max(geo.size.width, 1)
                    if ratio < 0.25 {
                        previous()
                    } else if ratio > 0.75 {
                        next()
                    } else {
                        withAnimation(.appQuick) { chromeVisible.toggle() }
                    }
                }
            )
        }
        .statusBarHidden(!chromeVisible)
        .animation(.appQuick, value: chromeVisible)
    }

    // MARK: - 工具层

    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.pressScale)

                Spacer()

                VStack(spacing: 2) {
                    Text(images[safe: index]?.name ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(index + 1) / \(images.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()
                Color.clear.frame(width: 36, height: 36)   // 对称占位
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 24) {
            Button(action: previous) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressScale)
            .disabled(index <= 0)
            .opacity(index <= 0 ? 0.4 : 1)

            Button(action: next) {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressScale)
            .disabled(index >= images.count - 1)
            .opacity(index >= images.count - 1 ? 0.4 : 1)
        }
        .padding(.bottom, 28)
    }

    private func previous() {
        guard index > 0 else { return }
        withAnimation(.appQuick) { index -= 1 }
    }

    private func next() {
        guard index < images.count - 1 else { return }
        withAnimation(.appQuick) { index += 1 }
    }
}

// MARK: - 单页远程图片

private struct RemoteImagePage: View {
    let entry: FileEntry
    let adapter: StorageAdapter

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task(id: entry.path) {
            do {
                let data = try await adapter.readAll(entry.path, limit: 48 * 1024 * 1024)
                image = await Task.detached {
                    ImageDownsampler.downsample(data: data, maxPixel: 2048)
                }.value
                if image == nil { failed = true }
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - 键盘导航桥接（iOS 16 兼容：UIKeyCommand 经由 pressesBegan）

private struct KeyboardNavigationBridge: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void

    func makeUIView(context: Context) -> KeyboardNavigationView {
        let view = KeyboardNavigationView()
        view.onLeft = onLeft
        view.onRight = onRight
        return view
    }

    func updateUIView(_ uiView: KeyboardNavigationView, context: Context) {
        uiView.onLeft = onLeft
        uiView.onRight = onRight
    }
}

private final class KeyboardNavigationView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { self.becomeFirstResponder() }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardLeftArrow:
                onLeft?()
                return
            case .keyboardRightArrow:
                onRight?()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
