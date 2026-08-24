import Foundation
import OSLog

/// 轻量文件日志（关于页可查看/分享/清空，TODO §10）。
/// 落盘 Application Support/Logs/myhub.log，超 512KB 自动截断保留尾部；同时输出到 os_log。
final class AppLogger {
    static let shared = AppLogger()

    private let logger = Logger(subsystem: "com.myhub.MyHub", category: "app")
    private let queue = DispatchQueue(label: "com.myhub.MyHub.AppLogger")
    private let fileURL: URL
    private let maxBytes = 512 * 1024

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("myhub.log")
    }

    /// 日志文件地址（供分享）
    var url: URL { fileURL }

    func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(Self.timestampFormatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
            self.trimIfNeeded()
        }
    }

    /// 尾部若干行（关于页查看）
    func tail(maxLines: Int = 300) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
            return text.components(separatedBy: "\n").suffix(maxLines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 超过上限时保留尾部一半，防止日志无限增长
    private func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return }
        try? data.suffix(maxBytes / 2).write(to: fileURL, options: .atomic)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
