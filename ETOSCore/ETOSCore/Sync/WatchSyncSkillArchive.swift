import Foundation
import ZIPFoundation

enum WatchSyncSkillArchive {
    /// 配置库中的技能开关与 Skills 文件是一份数据，必须从同一来源导出。
    static func add(to archive: Archive, directory: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw WatchDatabaseSyncService.SyncError.invalidArchive }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw WatchDatabaseSyncService.SyncError.invalidArchive
            }
            guard values.isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(directory.path.count + 1))
            guard SnapshotBuilder.isSafeRelativePath(path) else {
                throw WatchDatabaseSyncService.SyncError.invalidArchive
            }
            try archive.addEntry(with: "Skills/\(path)", fileURL: url, compressionMethod: .deflate)
            paths.append(path)
        }
        if let enumerationError { throw enumerationError }
        return paths.sorted()
    }

    static func extract(from archive: Archive, paths: [String], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in paths {
            guard SnapshotBuilder.isSafeRelativePath(path),
                  let entry = archive["Skills/\(path)"], entry.type == .file else {
                throw WatchDatabaseSyncService.SyncError.invalidArchive
            }
            let target = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try archive.extract(entry, to: target) == entry.checksum else {
                throw WatchDatabaseSyncService.SyncError.invalidArchive
            }
        }
    }

    /// 安装库失败时恢复原技能目录；空目录也代表来源端明确选择的空技能库。
    static func install(from source: URL?, to target: URL, installDatabases: () throws -> Void) throws {
        guard let source else { try installDatabases(); return }
        let fm = FileManager.default
        let original = fm.fileExists(atPath: target.path) ? target : nil
        try SkillLibraryFileTransaction.perform(original: original, target: target) {
            if original != nil { try fm.removeItem(at: target) }
            try fm.moveItem(at: source, to: target)
            try installDatabases()
        }
    }
}
