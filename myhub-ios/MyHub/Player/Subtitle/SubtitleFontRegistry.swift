import CoreText
import Foundation

/// 内嵌字幕（软解 VLC 渲染路径）的字体供给（TODO 412）。
///
/// 背景：内嵌字幕由 VLC 自己画进画面（`VLCEngine.selectSubtitleTrack` 只交索引），
/// 而 VLC 3.x 在 Apple 平台**不自带任何字幕字体**——`modules/codec/libass.c` 里
/// `default_font = NULL`（注释原文「We don't ship a default font with VLC」）、
/// 默认族名硬编码 `Helvetica Neue`；动漫 ASS 字幕的 Style 普遍指定方正/华康/思源等中文字体，
/// 片源又常常不内附字体（或附件 MIME / 后缀不在 libass 的
/// `application/x-truetype-font` + `.ttf/.otf/.ttc` 白名单内），
/// 于是中文落到无中文字形的字体上，整行渲染成 □ 方框——这正是「只有部分动漫出问题」的原因。
///
/// 本模块按三层补齐字体供给：
/// 1. 把可用字体汇聚到一个**独立目录**，经 `--ssa-fontsdir` 交给 libass。
///    注意 libass 的 `load_fonts_from_dir` 会把该目录下**每个文件整体读入内存**（不筛扩展名、
///    不递归、只跳过点文件），所以绝不能直接把 App Bundle 根目录丢过去，必须自建只含字体的目录；
///    符号链接会被 `fopen` 透明跟随，因此这里优先建链接、不复制字体（省磁盘、免首启拷贝）。
///    目录字体与「内嵌附件字体」共用同一条通道注册进 libass 字体库，既参与按族名匹配，
///    也参与「按字形覆盖兜底」——即 ASS 指定的字体缺失时能被挑中补位。
/// 2. 用 CoreText **进程级**注册同一批字体，让 libass 的 coretext provider 与 VLC freetype 的
///    darwin 字体选择器都能按族名查到它们（仅本进程可见，不污染系统字体库）。
/// 3. 用 `--freetype-font` 指定默认族名（内嵌 srt 等纯文本字幕走 freetype 渲染）：
///    有打包/用户字体时用其族名，否则回落系统中文族 `PingFang SC`。
///
/// 字体来源优先级：用户目录 `Documents/Fonts`（`UIFileSharingEnabled` 已开启，
/// 可用「文件」App 自行投放，无需重新打包）> App Bundle（`MyHub/Resources/Fonts/`，见 README）
/// > 系统中文字体文件（上述两者都没有时的兜底，只取一个文件，避免目录字体整体读入内存过大）。
enum SubtitleFontRegistry {
    /// FreeType / libass 可读的字体扩展名
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// 系统中文字体候选（无打包 / 用户字体时的兜底来源，取其中最小的可读文件；路径随 iOS 版本有差异）
    private static let systemFontCandidates = [
        "/System/Library/Fonts/LanguageSupport/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/PingFangSC.ttc",
        "/System/Library/Fonts/Core/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/Hiragino Sans GB W3.ttc",
        "/System/Library/Fonts/LanguageSupport/HiraginoSansGB.ttc",
        "/System/Library/Fonts/Core/STHeiti-Light.ttc",
        "/System/Library/Fonts/Core/HeitiSC.ttc",
        "/System/Library/Fonts/Cache/STHeiti-Light.ttc"
    ]

    /// freetype 文本渲染的系统兜底族名（无打包 / 用户字体时用）
    static let systemFallbackFamily = "PingFang SC"

    struct Snapshot {
        /// 交给 `--ssa-fontsdir` 的目录；nil = 一个字体都没有，不下发该选项
        let directory: URL?
        /// 已注册字体的族名（顺序即优先级，首个用于 `--freetype-font`）
        let families: [String]
        let fontCount: Int
    }

    private static let lock = NSLock()
    private static var registeredPaths: Set<String> = []
    private static var lastSnapshot = Snapshot(directory: nil, families: [], fontCount: 0)
    private static var didLogResult = false

    // MARK: - 目录

    /// 汇聚目录（只含字体文件 / 指向字体的符号链接）
    static var stagingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SubtitleFonts", isDirectory: true)
    }

    /// 用户自备字体目录（「文件」App 中可见：MyHub → Fonts）
    static var userDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Fonts", isDirectory: true)
    }

    // MARK: - 对外

    /// libvlc 启动选项（随 `VLCLibrary` 创建一次；目录路径固定不变，目录内容由每次起播前的 sync 刷新）
    static func libraryOptions() -> [String] {
        let snapshot = sync()
        var options: [String] = []
        if let directory = snapshot.directory {
            options.append("--ssa-fontsdir=\(directory.path)")
        }
        // 值含空格无需转义：libvlc 直接按 argv 条目解析，不经 shell
        options.append("--freetype-font=\(snapshot.families.first ?? systemFallbackFamily)")
        return options
    }

    /// 诊断快照（起播日志用：字幕方框问题复现时可直接看到字体是否就位）
    static var diagnosticSnapshot: String {
        lock.lock()
        defer { lock.unlock() }
        let families = lastSnapshot.families.prefix(3).joined(separator: ",")
        return "字体数=\(lastSnapshot.fontCount) 族名=[\(families)] 目录=\(lastSnapshot.directory?.path ?? "nil")"
    }

    /// 汇聚字体 + CoreText 注册 + 解析族名（幂等、线程安全，可在每次起播前调用）
    @discardableResult
    static func sync() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let sources = collectSources(fm: fm)
        guard !sources.isEmpty else {
            lastSnapshot = Snapshot(directory: nil, families: [], fontCount: 0)
            logResultIfNeeded(snapshot: lastSnapshot, level: .warn,
                              detail: "未找到任何可用字幕字体，内嵌 ASS 字幕可能出现方框")
            return lastSnapshot
        }

        let directory = stagingDirectory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var linked: Set<String> = []
        for source in sources where stage(source: source, into: directory, fm: fm) {
            linked.insert(source.lastPathComponent)
        }
        // 清理已失效条目（用户删了字体 / 换了打包字体），避免 libass 读进无用文件
        if let entries = try? fm.contentsOfDirectory(atPath: directory.path) {
            for entry in entries where !linked.contains(entry) {
                try? fm.removeItem(at: directory.appendingPathComponent(entry))
            }
        }

        registerWithCoreText(sources: sources)

        let families = resolveFamilies(of: sources)
        lastSnapshot = Snapshot(
            directory: linked.isEmpty ? nil : directory,
            families: families,
            fontCount: linked.count
        )
        logResultIfNeeded(snapshot: lastSnapshot, level: .info, detail: nil)
        return lastSnapshot
    }

    // MARK: - 来源收集

    /// 用户字体 > 打包字体 > 系统中文字体兜底；同名只取优先级最高的一个
    private static func collectSources(fm: FileManager) -> [URL] {
        var result: [URL] = []
        var names: Set<String> = []

        func append(_ urls: [URL]) {
            for url in urls where fontExtensions.contains(url.pathExtension.lowercased()) {
                guard fm.isReadableFile(atPath: url.path) else { continue }
                guard names.insert(url.lastPathComponent).inserted else { continue }
                result.append(url)
            }
        }

        append(userFonts(fm: fm))
        append(bundledFonts())
        guard result.isEmpty else { return result }

        // 兜底：没有打包 / 用户字体时借用系统中文字体文件。
        // libass 会把目录字体**整体读入内存**（峰值约文件大小 2 倍），因此只取一个、且优先挑最小的，
        // 超过 60MB 的直接放弃（宁可没有兜底，也不冒播放中被 Jetsam 回收的风险）。
        let candidates = systemFontCandidates
            .compactMap { path -> (path: String, size: Int)? in
                guard fm.isReadableFile(atPath: path),
                      let size = fm.fontFileSize(atPath: path), size <= 60 * 1024 * 1024 else { return nil }
                return (path, size)
            }
            .sorted { $0.size < $1.size }
        guard let chosen = candidates.first else { return result }
        append([URL(fileURLWithPath: chosen.path)])
        if !didLogSystemFallback {
            didLogSystemFallback = true
            AppLogger.shared.log(
                "字幕字体回落系统字体 path=\(chosen.path) size=\(chosen.size / 1024 / 1024)MB（libass 整体读入内存，建议改放子集化的打包字体）",
                module: "player-subtitle"
            )
        }
        return result
    }

    private static var didLogSystemFallback = false

    private static func userFonts(fm: FileManager) -> [URL] {
        let directory = userDirectory
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // 首次创建时留一份说明，用户在「文件」App 里能看懂这个目录是干什么的
            let readme = directory.appendingPathComponent("使用说明.txt")
            let text = """
            把中文 / 日文字体文件（.ttf / .otf / .ttc）放进本目录，
            即可供播放内嵌 ASS 字幕时使用（解决字幕显示为方框 □ 的问题）。
            放入后重新进入播放页即生效，无需重启 App。
            推荐：Noto Sans SC（思源黑体，开源）。
            """
            try? text.data(using: .utf8)?.write(to: readme, options: .atomic)
        }
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Bundle 内字体（XcodeGen 把 `Resources/Fonts/*` 平铺进 bundle 根目录，兼容两种检索）
    private static func bundledFonts() -> [URL] {
        var urls: [URL] = []
        for ext in fontExtensions.sorted() {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
        }
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - 汇聚

    /// 在汇聚目录建立指向 source 的符号链接（已存在且有效则跳过；建链接失败回退复制）
    private static func stage(source: URL, into directory: URL, fm: FileManager) -> Bool {
        let target = directory.appendingPathComponent(source.lastPathComponent)

        if let destination = try? fm.destinationOfSymbolicLink(atPath: target.path) {
            if destination == source.path, fm.isReadableFile(atPath: target.path) { return true }
            try? fm.removeItem(at: target)
        } else if fm.fileExists(atPath: target.path) {
            // 旧版本回退复制下来的实体文件：大小一致即认为仍然有效
            let sourceSize = fm.fontFileSize(atPath: source.path)
            let targetSize = fm.fontFileSize(atPath: target.path)
            if let sourceSize, let targetSize, sourceSize == targetSize { return true }
            try? fm.removeItem(at: target)
        }

        do {
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: source.path)
            return true
        } catch {
            do {
                try fm.copyItem(at: source, to: target)
                return true
            } catch {
                AppLogger.shared.log(
                    "字幕字体汇聚失败 font=\(source.lastPathComponent) error=\(error.localizedDescription)",
                    level: .warn, module: "player-subtitle"
                )
                return false
            }
        }
    }

    // MARK: - CoreText / 族名

    private static func registerWithCoreText(sources: [URL]) {
        // 系统字体本就在字体库中，无需注册
        let pending = sources.filter { !$0.path.hasPrefix("/System/") && !registeredPaths.contains($0.path) }
        guard !pending.isEmpty else { return }
        registeredPaths.formUnion(pending.map(\.path))
        for url in pending {
            var error: Unmanaged<CFError>?
            guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else { continue }
            // 打包字体已由 Info.plist `UIAppFonts` 注册，这里会以「已注册」失败——属预期，
            // 族名解析与 `--ssa-fontsdir` 直读都不依赖本次注册，故仅记 debug 不作处理。
            let cfError = error?.takeRetainedValue()
            let message = cfError.map { String(describing: $0) } ?? "未知原因"
            AppLogger.shared.log(
                "字幕字体 CoreText 注册跳过（可能已由 UIAppFonts 注册）font=\(url.lastPathComponent) detail=\(message)",
                level: .debug, module: "player-subtitle"
            )
        }
    }

    /// 读取字体文件的族名（libass / freetype 按族名匹配，与文件名无关）
    private static func resolveFamilies(of sources: [URL]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for source in sources {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(source as CFURL) as? [CTFontDescriptor] else { continue }
            for descriptor in descriptors {
                guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                      seen.insert(family).inserted else { continue }
                result.append(family)
            }
        }
        return result
    }

    // MARK: - 日志

    /// 结果日志只在「首次」或「结果发生变化」时打，避免每次起播刷屏
    private static func logResultIfNeeded(snapshot: Snapshot, level: AppLogger.Level, detail: String?) {
        let fingerprint = "\(snapshot.fontCount)|\(snapshot.families.joined(separator: ","))"
        guard !didLogResult || fingerprint != loggedFingerprint else { return }
        didLogResult = true
        loggedFingerprint = fingerprint
        let suffix = detail.map { " \($0)" } ?? ""
        AppLogger.shared.log(
            "字幕字体就绪 字体数=\(snapshot.fontCount) 族名=[\(snapshot.families.joined(separator: ","))] 目录=\(snapshot.directory?.path ?? "nil")\(suffix)",
            level: level, module: "player-subtitle"
        )
    }

    private static var loggedFingerprint = ""
}

private extension FileManager {
    /// 文件字节数（取不到返回 nil）
    func fontFileSize(atPath path: String) -> Int? {
        guard let attributes = try? attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return nil }
        return size
    }
}
