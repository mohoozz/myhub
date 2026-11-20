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

/// 全局播放呈现状态
/// - 播放器走独立全屏路由（`fullScreenCover`），不随 Tab 切换销毁
final class PlayerPresenter: ObservableObject {
    @Published private(set) var current: PlayableItem?
    @Published var isFullscreen = false
    @Published private(set) var isMini = false
    /// 下拉进 mini 的瞬消标志：置 true 让全屏内容层立即透明（视觉瞬消）
    @Published var isMinimizing = false
    /// 数据源解析失败信息（PlayerView 呈现失败态）
    @Published var lastError: String?

    /// 播放文件；若为 mini 中的同一文件 → 回到完整播放
    func play(_ item: PlayableItem) {
        if current == item, isMini {
            expand()
            // 该媒体若已播放结束，从历史记录/列表重新进入时自动从头重播（未结束则不打断，保持原状态）
            Task { await PlayerCore.shared.replayIfFinished() }
            return
        }
        current = item
        isMini = false
        isFullscreen = true
    }

    /// 从连接源条目播放：解析数据源（本地 file:// / 边下边播代理）+ 历史进度恢复（精准续播）
    func play(connection: Connection, entry: FileEntry) {
        // 点击面包屑：与后续「数据源解析完成 / open」日志对照
        AppLogger.shared.log(
            "点击播放 file=\(entry.name) type=\(connection.type.rawValue) 代理=\(LocalStreamProxy.shared.healthSnapshot()) 网络=\(NetworkPathMonitor.shared.snapshot())",
            level: .info, module: "player"
        )
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
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    AppLogger.shared.log(
                        "播放失败态呈现 error=\(error.localizedDescription)",
                        level: .error, module: "player"
                    )
                }
            }
        }
    }

    /// 进入 mini（保留会话）
    func enterMini(instant: Bool = false) {
        guard current != nil else { return }
        if instant {
            isMinimizing = true
        }
        isFullscreen = false
        withAnimation(.appQuick) { isMini = true }
    }

    /// 从 mini 展开回全屏（复用同一会话）
    func expand() {
        guard current != nil else { return }
        withAnimation(.appQuick) {
            isMini = false
            isFullscreen = true
        }
    }

    /// 直接退出（不进入 mini，同时停止播放内核）。
    func close() {
        current = nil
        isMini = false
        isFullscreen = false
        isMinimizing = false
        lastError = nil
        Task { await PlayerCore.shared.close() }
    }
}
