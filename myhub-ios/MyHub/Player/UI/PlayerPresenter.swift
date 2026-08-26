import Foundation
import SwiftUI

/// 可播放媒体描述（与 FileEntry / 进度记录联动）
struct PlayableItem: Equatable {
    var title: String
    var path: String
    var isAudioOnly: Bool = false
    /// 来源连接源（进度记录 / 数据源解析）
    var connectionID: Int64? = nil
}

/// 全局播放呈现状态（TODO §1.1 页面保活 / §4.4 mini 播放器）：
/// - 播放器走独立全屏路由（`fullScreenCover`），不随 Tab 切换销毁；
/// - mini 播放器全局悬浮持有，可展开回全屏（复用同一会话不重载）。
final class PlayerPresenter: ObservableObject {
    @Published private(set) var current: PlayableItem?
    @Published var isFullscreen = false
    @Published private(set) var isMini = false
    /// 下拉进 mini 的瞬消标志：置 true 让全屏内容层立即透明（视觉瞬消），
    /// 配合正常 dismiss 动画；不再用 disablesAnimations 强制禁用系统 dismiss 动画（iOS 26 会崩溃）
    @Published var isMinimizing = false
    /// 数据源解析失败信息（PlayerView §4.3 呈现失败态）
    @Published var lastError: String?

    /// 播放文件；若为 mini 中的同一文件 → 回到完整播放（IOS-701）
    func play(_ item: PlayableItem) {
        if current == item, isMini {
            expand()
            return
        }
        current = item
        isMini = false
        isFullscreen = true
    }

    /// 从连接源条目播放：解析数据源（本地 file:// / 边下边播代理）+ 历史进度恢复（§4.2 精准续播）；
    /// 先展示播放 UI 再异步解析（弱网不出现「点了没反应」），解析失败经 lastError 呈现失败态
    func play(connection: Connection, entry: FileEntry) {
        let mediaType = MediaType.detect(ext: entry.ext)
        play(PlayableItem(
            title: entry.name, path: entry.path,
            isAudioOnly: mediaType == .audio, connectionID: connection.id
        ))
        Task {
            do {
                let request = try await PlaybackSourceResolver.makeRequest(connection: connection, entry: entry)
                await PlayerCore.shared.open(request)
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// 进入 mini（保留会话）
    /// - Parameter instant: true 时全屏封面「瞬消」。实现为：先把内容层置透明（视觉瞬消），
    ///   再用正常动画 dismiss。不再用 disablesAnimations 强制禁用系统 dismiss 动画（会崩溃）。
    func enterMini(instant: Bool = false) {
        guard current != nil else { return }
        AppLogger.shared.log("enterMini instant=\(instant)", module: "player")
        if instant {
            isMinimizing = true   // 内容层立即透明，视觉瞬消，避免画面跳回 + 双画面重影
        }
        isFullscreen = false
        withAnimation(.appQuick) { isMini = true }
    }

    /// 从 mini 展开回全屏（复用同一会话）
    func expand() {
        guard current != nil else { return }
        AppLogger.shared.log("expand", module: "player")
        withAnimation(.appQuick) {
            isMini = false
            isFullscreen = true
        }
    }

    /// 直接退出（不进入 mini，同时停止播放内核）。
    /// 不加 withAnimation：让 mini 立即消失，避免停内核时图标先切换再淡出的闪烁。
    func close() {
        AppLogger.shared.log("close", module: "player")
        current = nil
        isMini = false
        isFullscreen = false
        isMinimizing = false
        lastError = nil
        Task { await PlayerCore.shared.close() }
    }
}
