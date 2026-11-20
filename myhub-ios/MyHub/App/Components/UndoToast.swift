import SwiftUI
import UIKit

// MARK: - 撤销吐司状态

/// 底部「已删除 · 撤销」提示条状态。
@MainActor
final class UndoToastState: ObservableObject {
    struct Item: Equatable {
        let message: String
        /// 进行中（左侧菊花）：此时不显示撤销按钮，也不自动消失——由操作方显式 `finish` 收尾
        var isWorking = false
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
        scheduleDismiss()
    }

    /// 开始一项耗时的破坏性操作（删除 / 移入回收站）：确认弹窗收起前调用
    func beginWorking(_ message: String) {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.appQuick) {
            item = Item(message: message, isWorking: true)
            canUndo = false
        }
    }

    /// 结束进行中提示：原位置替换为结果文案，并恢复 5 秒撤销窗口。
    func finish(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        dismissTask?.cancel()
        if let undo { undoActions.append(undo) }
        let text = undoActions.count > 1 ? "已删除 \(undoActions.count) 项" : message
        withAnimation(.appQuick) {
            item = Item(message: text)
            canUndo = !undoActions.isEmpty
        }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
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
struct UndoToastBar: View {
    @ObservedObject var state: UndoToastState

    init(state: UndoToastState) {
        self.state = state
    }

    var body: some View {
        if let item = state.item {
            HStack(spacing: 12) {
                // 进行中：菊花让「还在动」这件事有持续的视觉证据（弱网下文案不变但界面不死）
                if item.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
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
