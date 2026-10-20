import Foundation
import MobileVLCKit

/// 带「字幕字体选项」的 libvlc 实例持有者（TODO 412）。
///
/// 为什么需要它：`--ssa-fontsdir`（libass 字体目录）与 `--freetype-font`（文本字幕默认族名）
/// 都必须在 **libvlc 实例创建时**下发——前者由字幕解码器 `var_InheritString` 向上继承到 libvlc 对象，
/// 后者的使用者是 vout/spu 侧的 text_renderer（**不在 input 的对象树上**，媒体级 `:option` 继承不到）。
/// 而 `VLCLibrary.sharedLibrary` 由框架载入时用默认选项自动创建、无法事后补选项（也没有 setter），
/// 因此这里自建一个带选项的 `VLCLibrary` 并全局复用；
/// 不用 `VLCMediaPlayer(options:)` 是因为它每次都会新建一套 libvlc + VLCLibrary（内存开销随引擎重建累积）。
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
