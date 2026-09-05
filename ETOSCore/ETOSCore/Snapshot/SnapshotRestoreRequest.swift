import Foundation

/// 数据库快照不能转换成部分同步包。导入入口收到此请求后，必须展示恢复确认页。
/// 持有独立副本，避免文件选择器的授权结束或 watchOS 下载临时文件被清理后无法恢复。
public final class SnapshotRestoreRequest: Error, Identifiable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    private let directoryURL: URL

    init(copying sourceURL: URL) throws {
        let directory = try SyncTemporaryFileCleaner.makeDirectoryURL(prefix: "ETOS-Snapshot-Confirmation")
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        directoryURL = directory
        fileURL = destination
    }

    deinit {
        let directory = directoryURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
