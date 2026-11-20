import Foundation
import MobileVLCKit

/// 带「字幕字体选项」的 libvlc 实例持有者。
@MainActor
enum VLCPlayerFactory {
    private static var library: VLCLibrary?

    /// 创建播放器：首个播放器创建时建立带选项的 libvlc，后续共享
    static func makePlayer() -> VLCMediaPlayer {
        // 每次起播前同步一次字体目录（用户可能刚往 Documents/Fonts 放了字体），目录路径固定不变
        let options = SubtitleFontRegistry.libraryOptions()
        guard !options.isEmpty else { return VLCMediaPlayer() }

        if library == nil {
            library = VLCLibrary(options: options)
            AppLogger.shared.log(
                "软解 libvlc 实例创建 options=[\(options.joined(separator: " "))]",
                module: "player-subtitle"
            )
        }
        guard let library = library else { return VLCMediaPlayer() }
        return VLCMediaPlayer(library: library)
    }
}
