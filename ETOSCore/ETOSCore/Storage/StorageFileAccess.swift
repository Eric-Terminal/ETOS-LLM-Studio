import Foundation

public enum StorageFileAccessError: LocalizedError {
    case outsideRoot, managedDatabase, changed
    public var errorDescription: String? {
        switch self {
        case .outsideRoot: NSLocalizedString("此项目不在应用数据目录内。", comment: "")
        case .managedDatabase: NSLocalizedString("正在使用的数据库及其所在目录不能在文件浏览器中删除。", comment: "")
        case .changed: NSLocalizedString("文件已发生变化，请刷新后重新选择。", comment: "")
        }
    }
}

/// 文件浏览只操作应用目录；符号链接可作为条目删除，但不能借它读取外部文件。
public struct StorageFileAccess: Sendable {
    public let root: URL
    public let managedDatabases: [URL]

    public init(root: URL, managedDatabases: [URL]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.managedDatabases = managedDatabases.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    public static func application() -> Self {
        let databases = Persistence.snapshotRestoreTargetURLs()
        return Self(root: StorageUtility.documentsDirectory,
            managedDatabases: [databases.chatStoreURL, databases.configStoreURL, databases.memoryStoreURL])
    }

    public func readableURL(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolved.path) else { throw StorageFileAccessError.outsideRoot }
        return resolved
    }

    public func validateDeletion(_ url: URL) throws {
        let entry = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL
        guard entry.path != root.path, contains(entry.path) else { throw StorageFileAccessError.outsideRoot }
        // 不能只删 WAL，也不能递归删除仍由 GRDB 持有的主库目录。
        for database in managedDatabases {
            let path = database.path
            guard entry.path != path, entry.path != path + "-wal", entry.path != path + "-shm",
                  !path.hasPrefix(entry.path + "/") else { throw StorageFileAccessError.managedDatabase }
        }
    }

    private func contains(_ path: String) -> Bool { path == root.path || path.hasPrefix(root.path + "/") }
}
