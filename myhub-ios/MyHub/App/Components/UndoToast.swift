import SwiftUI
import UIKit

// MARK: - 撤销吐司状态

/// 底部「已删除 · 撤销」提示条状态（TODO 408 左滑删除的误删兜底）。
///
/// 方案 A 不弹确认框以求「点一下就删」的爽快，代价必须由撤销来补：删除后 5 秒内可一键还原。
///
/// **撤销按栈累积**：连删多行是极常见操作，若后一次 `show` 直接覆盖前一次的撤销闭包，
/// 先删那条会被静默变成不可撤销（用户完全无感知）——而方案 A 的全部安全兜底就压在这 5 秒上。
/// 故把待撤销动作压栈，`performUndo()` 逆序全部执行，计时窗口随每次新删除顺延。
@MainActor
final class UndoToastState: ObservableObject {
    struct Item: Equatable {
        let message: String
        let id = UUID()

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var item: Item?
    /// 是否有可撤销动作（纯提示时隐藏「撤销」按钮）
    @Published private(set) var canUndo = false

    /// 自动消失时长
    private let duration: TimeInterval = 5
    /// 待撤销动作栈（后进先出：撤销时逆序还原）
    private var undoActions: [@MainActor () -> Void] = []
    private var dismissTask: Task<Void, Never>?

    /// 展示提示（`undo` 为 nil 时不显示撤销按钮，纯提示；此时也会清空既有撤销栈）
    func show(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        dismissTask?.cancel()
        if let undo {
            undoActions.append(undo)
        } else {
            undoActions.removeAll()
        }
        // 多条待撤销时合并计数，避免「删了 N 条只提示最后一条」
        let text = undoActions.count > 1 ? "已删除 \(undoActions.count) 项" : message
        withAnimation(.appQuick) {
            item = Item(message: text)
            canUndo = !undoActions.isEmpty
        }
        // 每次新删除都顺延计时窗口
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// 撤销：先收起提示，再逆序还原全部待撤销动作
    func performUndo() {
        let actions = undoActions.reversed()
        dismiss()
        for action in actions { action() }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        undoActions.removeAll()
        withAnimation(.appQuick) {
            item = nil
            canUndo = false
        }
    }
}

// MARK: - 提示条视图

/// 删除结果提示条：`已删除 · 撤销`（撤销按钮在右）。
///
/// 样式沿用浏览页现有轻提示（深色圆角 + 白字），尺寸放大到可点按。
/// 调用方把它放进自己的底部覆盖层（与多选操作栏 / 传输横幅同一个 VStack），
/// 复用该页已有的 `bottomChromeHeight` 抬升逻辑——页面内 overlay 的落点是系统底部
/// 安全区，不含祖先注入的悬浮页签栏，必须由页面自己抬升（TODO 379）。
struct UndoToastBar: View {
    @ObservedObject var state: UndoToastState

    init(state: UndoToastState) {
        self.state = state
    }

    var body: some View {
        if let item = state.item {
            HStack(spacing: 12) {
                Text(item.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if state.canUndo {
                    Button {
                        state.performUndo()
                    } label: {
                        Text("撤销")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .systemBlue))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressScale)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.82))
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
