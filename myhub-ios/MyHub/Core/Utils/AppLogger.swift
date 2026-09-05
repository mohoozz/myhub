import Foundation
import OSLog

/// 文件日志：落盘 Documents/Logs/myhub-yyyy-MM-dd.log（按天滚动，保留最近 7 份），同时输出 os_log。
/// 用 Documents 目录配合 File Sharing，真机可直接导出日志给 AI 分析。
final class AppLogger {
    static let shared = AppLogger()

    enum Level: String {
        case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
    }

    private let logger = Logger(subsystem: "com.myhub.MyHub", category: "app")
    private let queue = DispatchQueue(label: "com.myhub.MyHub.AppLogger")
    private let dir: URL
    private var fileURL: URL
    private var currentDay: String
    private let maxBytes = 10 * 1024 * 1024

    private init() {
        dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        currentDay = Self.dayFormatter.string(from: Date())
        fileURL = dir.appendingPathComponent("myhub-\(currentDay).log")
        backupLogsIfNewBuild()
        cleanupOldLogs()
        CrashReporter.install(logsDirectory: dir)
    }

    var url: URL { fileURL }
    var directory: URL { dir }

    func log(_ message: String, level: Level = .info, module: String = "app") {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = "\(Self.timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(module)] \(message)\n"
        queue.async { [self] in
            rollIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
            trimIfNeeded()
        }
    }

    func tail(maxLines: Int = 300) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
            return text.components(separatedBy: "\n").suffix(maxLines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    /// 每次重新编译打包后的第一次启动：把 Logs 目录里已有的 .log 备份到 backup/ 子目录，
    /// 从零开始写新日志，避免旧构建的日志污染本次分析。
    /// 构建标识取 App 可执行文件的 mtime——每次重新编译打包都会重写可执行文件，mtime 必然变化；
    /// 同一次安装内多次启动 mtime 不变，不会误触发备份。
    private func backupLogsIfNewBuild() {
        let stamp = Self.currentBuildStamp()
        let key = "com.myhub.AppLogger.lastBuildStamp"
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: key) == stamp {
            return
        }
        defaults.set(stamp, forKey: key)

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.pathExtension == "log" }
        guard !logs.isEmpty else { return }

        let backupDir = dir.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stampText = Self.buildStampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(stamp)))
        for file in logs {
            let base = file.deletingPathExtension().lastPathComponent  // myhub-2026-09-05 / crash
            let target = backupDir.appendingPathComponent("\(base)-build-\(stampText).log")
            try? FileManager.default.moveItem(at: file, to: target)
        }
        logger.info("日志已按新构建重置：备份 \(logs.count, privacy: .public) 个旧日志到 backup/（build \(stampText, privacy: .public)）")
        cleanupBackup(in: backupDir)
    }

    private static func currentBuildStamp() -> Int {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return 0 }
        return Int(date.timeIntervalSince1970)
    }

    private func cleanupBackup(in backupDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasSuffix(".log") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        backups.dropFirst(30).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func rollIfNeeded() {
        let day = Self.dayFormatter.string(from: Date())
        guard day != currentDay else { return }
        currentDay = day
        fileURL = dir.appendingPathComponent("myhub-\(day).log")
        cleanupOldLogs()
    }

    private func cleanupOldLogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("myhub-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        logs.dropFirst(7).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return }
        try? data.suffix(maxBytes / 2).write(to: fileURL, options: .atomic)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let buildStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
