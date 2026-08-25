import Foundation

/// 崩溃捕获（专治「漫画闪退」等崩溃定位）：
/// - NSException：完整落盘（名称/原因/调用栈）到 Documents/Logs/crash.log
/// - native signal：用 async-signal-safe 的 write 写 signal 编号，再交还系统生成 .ips
/// 崩溃日志随 myhub-ios-fetch-logs.sh 一并导出，供 AI 分析。
enum CrashReporter {
    private static var crashFD: Int32 = -1

    static func install(logsDirectory: URL) {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        crashFD = open(logsDirectory.appendingPathComponent("crash.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler { recordException($0) }

        signal(SIGABRT, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGFPE, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGTRAP, signalHandler)
    }

    /// NSException：此时栈尚未破坏，可安全完整记录
    private static func recordException(_ exception: NSException) {
        let timestamp = timestampFormatter.string(from: Date())
        let text = "\n===== CRASH (NSException) \(timestamp) =====\n"
            + "name: \(exception.name.rawValue)\n"
            + "reason: \(exception.reason ?? "")\n"
            + "callStack:\n\(exception.callStackSymbols.joined(separator: "\n"))\n"
            + "===== END =====\n\n"
        writeToCrashFile(text)
    }

    /// signal handler：仅允许 async-signal-safe 操作（write 直接落盘，不分配内存/加锁）
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        var buffer = [CChar](repeating: 0, count: 128)
        let len = buffer.withUnsafeMutableBufferPointer {
            snprintf($0.baseAddress, $0.count, "\n===== CRASH (signal %d) =====\n", sig)
        }
        buffer.withUnsafeBufferPointer { _ = write(crashFD, $0.baseAddress, Int(len)) }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func writeToCrashFile(_ text: String) {
        guard crashFD >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { _ = write(crashFD, $0.baseAddress, $0.count) }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
