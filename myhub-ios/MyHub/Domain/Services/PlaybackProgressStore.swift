import Foundation
import GRDB

extension Notification.Name {
    /// 播放进度落库后广播（「正在阅读」列表自动刷新， 订阅）
    static let playbackProgressDidChange = Notification.Name("playbackProgressDidChange")
}

/// 播放进度上报落库
/// PlayerCore.onProgressReport（5s 节流 + 暂停/seek/结束/退出强制）→ ReadingProgress upsert。
final class PlaybackProgressStore {
    static let shared = PlaybackProgressStore()

    private init() {}

    /// App 启动时挂接（MyHubApp 根视图 onAppear）
    @MainActor
    func attach() {
        PlayerCore.shared.onProgressReport = { [weak self] report in
            self?.save(report)
        }
    }

 // MARK: - 已删除进度记录的抑制窗口

    /// 进度被清掉/源文件被删掉的 (连接 + 路径)：短时间忽略进度上报。
    /// 播放器退出 / 播完停播时会强制上报一次（`PlayerCore.close()`、暂停、seek），
    /// 若这次上报晚于记录删除，就会把刚删掉的记录重新插回来（表现为「删了还在」）。
    private let suppressedLock = NSLock()
    private var suppressedUntil: [String: Date] = [:]
    /// 抑制时长：只需覆盖播放器收尾上报的那几秒，过长会影响删掉后重新播放的正常落库
    private static let suppressionTTL: TimeInterval = 60

    private func suppressionKey(connectionID: Int64, path: String) -> String {
        "\(connectionID)#\(path)"
    }

    /// 抑制这些路径的进度回写（删除阅读进度 / 删除源文件后调用）
    func suppress(connectionID: Int64, paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let expiry = Date().addingTimeInterval(Self.suppressionTTL)
        suppressedLock.lock()
        for path in paths {
            suppressedUntil[suppressionKey(connectionID: connectionID, path: path)] = expiry
        }
        suppressedLock.unlock()
    }

    /// 解除抑制（用户重新打开该文件，或撤销了删除）：新会话的进度应正常落库
    func resume(connectionID: Int64, path: String) {
        suppressedLock.lock()
        suppressedUntil.removeValue(forKey: suppressionKey(connectionID: connectionID, path: path))
        suppressedLock.unlock()
    }

    private func isSuppressed(connectionID: Int64, path: String) -> Bool {
        let key = suppressionKey(connectionID: connectionID, path: path)
        suppressedLock.lock()
        defer { suppressedLock.unlock() }
        guard let expiry = suppressedUntil[key] else { return false }
        if expiry <= Date() {
            suppressedUntil.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func save(_ report: PlaybackProgressReport) {
        guard let connectionID = report.connectionID,
              !isSuppressed(connectionID: connectionID, path: report.path),
              let db = AppDatabase.shared.dbQueue else { return }
        let percent = report.duration > 0 ? min(1, max(0, report.position / report.duration)) : 0
        try? db.write { database in
            if var existing = try ReadingProgress
                .filter(Column("connectionID") == connectionID && Column("filePath") == report.path)
                .fetchOne(database) {
                existing.progressJSON = String(report.position)
                existing.percent = report.finished ? 1 : percent
                existing.finished = report.finished
                existing.title = report.title
                existing.updatedAt = Date()
                try existing.update(database)
            } else {
                let record = ReadingProgress(
                    id: nil,
                    connectionID: connectionID,
                    filePath: report.path,
                    mediaType: report.mediaType,
                    title: report.title,
                    cover: nil,
                    progressJSON: String(report.position),
                    percent: report.finished ? 1 : percent,
                    finished: report.finished,
                    updatedAt: Date()
                )
                try record.insert(database)
            }
        }
        NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
    }
}
