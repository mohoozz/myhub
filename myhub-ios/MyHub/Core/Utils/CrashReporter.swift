import Darwin
import Foundation

// 崩溃捕获：NSException + 致命信号，直写 Documents/Logs/crash.log
// crash.log 不参与按天滚动/体积裁剪/新构建备份，也不随「清空日志」删除

private let crashFileName = "crash.log"
private var crashFD: Int32 = -1

private let scratchCapacity = 8192
private let frameCapacity = 96
private var scratch: UnsafeMutablePointer<CChar> = .allocate(capacity: scratchCapacity)
private var decBuf: UnsafeMutablePointer<CChar> = .allocate(capacity: 32)
private var frameBuf: UnsafeMutablePointer<UnsafeMutableRawPointer?> = .allocate(capacity: frameCapacity)

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

// MARK: - 写入

/// 普通上下文写入（NSException / 启动头，可用 Swift 字符串）
private func writeRaw(_ text: String) {
    guard crashFD >= 0 else { return }
    text.utf8CString.withUnsafeBytes { buffer in
        _ = write(crashFD, buffer.baseAddress, max(0, buffer.count - 1))
    }
}

private func appendText(_ n: inout Int, _ s: String) {
    for byte in s.utf8 {
        guard n < scratchCapacity - 1 else { return }
        scratch[n] = CChar(bitPattern: byte)
        n += 1
    }
}

private func appendDecimal(_ n: inout Int, _ value: UInt) {
    if value == 0 {
        appendText(&n, "0")
        return
    }
    var v = value
    var d = 0
    while v > 0 {
        decBuf[d] = CChar(48 + Int(v % 10))
        d += 1
        v /= 10
    }
    while d > 0 {
        d -= 1
        guard n < scratchCapacity - 1 else { return }
        scratch[n] = decBuf[d]
        n += 1
    }
}

private func appendHex(_ n: inout Int, _ value: UInt) {
    appendText(&n, "0x")
    if value == 0 {
        appendText(&n, "0")
        return
    }
    var v = value
    var d = 0
    while v > 0 {
        let digit = Int(v & 0xF)
        decBuf[d] = CChar(digit < 10 ? 48 + digit : 87 + digit)
        d += 1
        v >>= 4
    }
    while d > 0 {
        d -= 1
        guard n < scratchCapacity - 1 else { return }
        scratch[n] = decBuf[d]
        n += 1
    }
}

private func appendCString(_ n: inout Int, _ ptr: UnsafePointer<CChar>?, limit: Int = 120) {
    guard let ptr else { return }
    var i = 0
    while i < limit, ptr[i] != 0 {
        guard n < scratchCapacity - 1 else { return }
        scratch[n] = ptr[i]
        n += 1
        i += 1
    }
}

/// 镜像名只取最后一段（完整路径太长）
private func appendImageName(_ n: inout Int, _ ptr: UnsafePointer<CChar>?) {
    guard let ptr else { return }
    var last = 0
    var i = 0
    while i < 512, ptr[i] != 0 {
        if ptr[i] == 47 { last = i + 1 }
        i += 1
    }
    var j = last
    var written = 0
    while j < 512, written < 80, ptr[j] != 0 {
        guard n < scratchCapacity - 1 else { return }
        scratch[n] = ptr[j]
        n += 1
        j += 1
        written += 1
    }
}

private func appendFrame(_ n: inout Int, index: Int, address: UnsafeMutableRawPointer) {
    var info = Dl_info()
    guard dladdr(address, &info) != 0 else {
        appendText(&n, "  #")
        appendDecimal(&n, UInt(index))
        appendText(&n, " ")
        appendHex(&n, UInt(bitPattern: address))
        appendText(&n, "\n")
        return
    }
    appendText(&n, "  #")
    appendDecimal(&n, UInt(index))
    appendText(&n, " ")
    if info.dli_sname != nil {
        appendCString(&n, info.dli_sname)
    } else {
        appendImageName(&n, info.dli_fname)
    }
    let addressValue = UInt(bitPattern: address)
    let basePtr: UnsafeMutableRawPointer? = info.dli_saddr ?? info.dli_fbase
    let baseValue = basePtr.map { UInt(bitPattern: $0) } ?? 0
    appendText(&n, " + ")
    appendHex(&n, addressValue >= baseValue ? addressValue - baseValue : addressValue)
    appendText(&n, "\n")
}

private func flushScratch(_ n: Int) {
    guard crashFD >= 0, n > 0 else { return }
    _ = write(crashFD, scratch, n)
}

// MARK: - 记录

private func signalName(_ sig: Int32) -> String {
    switch sig {
    case SIGABRT: return "SIGABRT"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    default: return "unknown"
    }
}

/// 信号上下文：只做 buffer 填充与 write，不分配内存
private let signalHandler: @convention(c) (Int32) -> Void = { sig in
    var n = 0
    appendText(&n, "\n===== CRASH (signal ")
    appendDecimal(&n, UInt(bitPattern: Int(sig)))
    appendText(&n, " / ")
    appendText(&n, signalName(sig))
    appendText(&n, ") =====\n")
    appendText(&n, "time_epoch=")
    appendDecimal(&n, UInt(max(0, time(nil))))
    appendText(&n, " pid=")
    appendDecimal(&n, UInt(getpid()))
    appendText(&n, " thread=")
    appendDecimal(&n, UInt(pthread_mach_thread_np(pthread_self())))
    appendText(&n, "\nraw frames:\n")
    flushScratch(n)

    let count = backtrace(frameBuf, Int32(frameCapacity))
    // 先落原始地址：即使符号解析卡住，调用栈也已写入
    for i in 0..<Int(count) {
        var raw = 0
        appendText(&raw, "  #")
        appendDecimal(&raw, UInt(i))
        appendText(&raw, " ")
        appendHex(&raw, UInt(bitPattern: frameBuf[i]))
        appendText(&raw, "\n")
        flushScratch(raw)
    }

    var header = 0
    appendText(&header, "symbolicated (image + offset，可用 atos -o MyHub.app/MyHub -arch arm64 还原):\n")
    flushScratch(header)
    for i in 0..<Int(count) {
        guard let address = frameBuf[i] else { continue }
        var line = 0
        appendFrame(&line, index: i, address: address)
        flushScratch(line)
    }

    var tail = 0
    appendText(&tail, "===== END =====\n\n")
    flushScratch(tail)

    signal(sig, SIG_DFL)
    raise(sig)
}

private func recordException(_ exception: NSException) {
    var text = "\n===== CRASH (NSException) \(timestampFormatter.string(from: Date())) =====\n"
    text += "name: \(exception.name.rawValue)\n"
    text += "reason: \(exception.reason ?? "-")\n"
    if let userInfo = exception.userInfo, !userInfo.isEmpty {
        text += "userInfo: \(userInfo)\n"
    }
    text += "exception stack:\n"
    text += exception.callStackSymbols.joined(separator: "\n")
    text += "\nthread stack:\n"
    text += Thread.callStackSymbols.joined(separator: "\n")
    text += "\nrecent logs:\n"
    let recent = AppLogger.shared.recentLines
    text += recent.isEmpty ? "(none)\n" : recent.joined(separator: "\n") + "\n"
    text += "===== END =====\n\n"
    writeRaw(text)
}

private let exceptionHandler: @convention(c) (NSException) -> Void = { recordException($0) }

// MARK: - 安装

enum CrashReporter {
    static let fileName = crashFileName

    static var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var hasCrashLog: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    private static var installed = false

    static func install(logsDirectory: URL) {
        guard !installed else { return }
        installed = true
        // 预初始化 handler 用到的缓冲，避免崩溃时首次分配
        scratch.initialize(repeating: 0, count: scratchCapacity)
        decBuf.initialize(repeating: 0, count: 32)
        frameBuf.initialize(repeating: nil, count: frameCapacity)

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let url = logsDirectory.appendingPathComponent(fileName)
        trimIfNeeded(url)
        crashFD = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        writeSessionHeader(logsDirectory: logsDirectory)
        writePreviousExitIfAny()

        NSSetUncaughtExceptionHandler(exceptionHandler)

        signal(SIGABRT, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGFPE, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGTRAP, signalHandler)
    }

    /// App 正常退出时清除会话标记（未清除即上次会话异常结束）
    static func markCleanExit() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    private static let sessionKey = "com.myhub.CrashReporter.sessionStart"

    /// 上限 4MB：超出后只留最近一半（必须在 open 之前处理，否则 fd 指向被替换的旧文件）
    private static func trimIfNeeded(_ url: URL) {
        let limit = 4 * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > limit,
              let data = try? Data(contentsOf: url) else { return }
        var slice = data.suffix(limit / 2)
        if let newline = slice.firstIndex(of: 0x0A) {
            slice = slice[slice.index(after: newline)...]
        }
        try? Data(slice).write(to: url, options: .atomic)
    }

    private static func writeSessionHeader(logsDirectory: URL) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let memory = ProcessInfo.processInfo.physicalMemory / 1024 / 1024
        var uts = utsname()
        uname(&uts)
        let device = withUnsafeBytes(of: &uts.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let text = """

        ===== SESSION START \(timestampFormatter.string(from: Date())) =====
        version=\(version) build=\(build) os=\(os) device=\(device) memory=\(memory)MB
        logs=\(logsDirectory.path)

        """
        writeRaw(text)
    }

    /// 上次启动写下的标记未清除 → 上次会话没有走到正常退出（崩溃 / 被系统终止 / 上滑杀进程）
    private static func writePreviousExitIfAny() {
        let defaults = UserDefaults.standard
        if let previous = defaults.object(forKey: sessionKey) as? Date {
            let text = """

            ===== PREVIOUS SESSION NOT CLOSED =====
            last_start=\(timestampFormatter.string(from: previous))
            说明：上次会话未收到正常退出标记，可能为崩溃、OOM、watchdog 或用户上滑杀进程；上滑杀进程也会命中，仅作参考。

            """
            writeRaw(text)
        }
        defaults.set(Date(), forKey: sessionKey)
    }

    /// 崩溃文件内容（查看/分享用）
    static func logText() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
