import Foundation

// 崩溃回调相关的符号放在文件级全局作用域：它们需要作为 C function pointer
// 传给 signal / NSSetUncaughtExceptionHandler，而 C function pointer 要求闭包
// 不捕获上下文——全局符号不捕获，static 成员经由类型 self 访问会捕获。

private var crashFD: Int32 = -1

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

private func recordException(_ exception: NSException) {
    let timestamp = timestampFormatter.string(from: Date())
    let text = "\n===== CRASH (NSException) \(timestamp) =====\n"
        + "name: \(exception.name.rawValue)\n"
        + "reason: \(exception.reason ?? "")\n"
        + "callStack:\n\(exception.callStackSymbols.joined(separator: "\n"))\n"
        + "===== END =====\n\n"
    writeToCrashFile(text)
}

private func writeToCrashFile(_ text: String) {
    guard crashFD >= 0, let data = text.data(using: .utf8) else { return }
    data.withUnsafeBytes { _ = write(crashFD, $0.baseAddress, $0.count) }
}

// signal handler：仅 async-signal-safe（write 落盘，不分配/加锁）。
// Swift 无法调用可变参数的 snprintf，手动将 signal 编号拼成 ASCII。
private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    var buffer = [CChar](repeating: 0, count: 128)
    var n = 0
    for byte in "\n===== CRASH (signal ".utf8 { buffer[n] = CChar(byte); n += 1 }
    var value = sig
    if value < 0 { buffer[n] = 45; n += 1; value = -value }
    var digits = [CChar](repeating: 0, count: 16)
    var d = 0
    repeat {
        digits[d] = CChar(48 + value % 10)
        d += 1
        value /= 10
    } while value > 0
    while d > 0 { d -= 1; buffer[n] = digits[d]; n += 1 }
    for byte in ") =====\n".utf8 { buffer[n] = CChar(byte); n += 1 }
    buffer.withUnsafeBufferPointer { _ = write(crashFD, $0.baseAddress, Int(n)) }

    // 记录崩溃调用栈：backtrace 取原始帧地址，手动拼十六进制写入。
    // 不用 backtrace_symbols_fd —— 它内部会 malloc，崩溃瞬间 malloc 锁可能被持有，
    // 导致死锁 / 二次崩溃，从而把栈丢光（crash.log 只剩 signal 号）。
    // 这里只用 write + 整数运算，全程 async-signal-safe；拿到地址后用 atos 符号化。
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let frameCount = backtrace(&frames, Int32(frames.count))
    var line = [CChar](repeating: 0, count: 40)
    for i in 0..<Int(frameCount) {
        let addr = UInt(bitPattern: frames[i])
        var ln = 0
        line[ln] = 48; ln += 1   // '0'
        line[ln] = 120; ln += 1  // 'x'
        var started = false
        var shift = UInt((MemoryLayout<UInt>.size * 8) - 4)
        while true {
            let digit = (addr >> shift) & 0xF
            if digit != 0 || started {
                started = true
                line[ln] = CChar(digit < 10 ? 48 + digit : 87 + digit)  // 小写十六进制
                ln += 1
            }
            if shift == 0 { break }
            shift -= 4
        }
        if !started { line[ln] = 48; ln += 1 }
        line[ln] = 10; ln += 1   // '\n'
        line.withUnsafeBufferPointer { _ = write(crashFD, $0.baseAddress, ln) }
    }
    var end = [CChar](repeating: 0, count: 32)
    var en = 0
    for byte in "\n===== END =====\n\n".utf8 { end[en] = CChar(byte); en += 1 }
    end.withUnsafeBufferPointer { _ = write(crashFD, $0.baseAddress, Int(en)) }

    signal(sig, SIG_DFL)
    raise(sig)
}

private let exceptionHandler: @convention(c) (NSException) -> Void = { recordException($0) }

enum CrashReporter {
    static func install(logsDirectory: URL) {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        crashFD = open(logsDirectory.appendingPathComponent("crash.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(exceptionHandler)

        signal(SIGABRT, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGFPE, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGTRAP, signalHandler)
    }
}
