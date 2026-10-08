import Foundation

struct LocalDebugManagedDatabase: Sendable {
    enum Kind: Sendable { case chat, config, memory, vectors }
    let kind: Kind
    let url: URL
}

/// 文件接口对受管理库只提供导出和整体恢复；文件名大小写和硬链接都不能绕过限制。
struct LocalDebugDatabaseFilePolicy: Sendable {
    enum FileKind {
        case ordinary
        case database(LocalDebugManagedDatabase)
        case sidecar
    }

    let databases: [LocalDebugManagedDatabase]
    private let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    init(databases: [LocalDebugManagedDatabase]) { self.databases = databases }

    func kind(of url: URL) throws -> FileKind {
        let candidate = normalizedPath(url)
        for database in databases {
            let primary = normalizedPath(database.url)
            if candidate == primary { return .database(database) }
            if sidecarSuffixes.contains(where: { candidate == primary + $0 }) { return .sidecar }
        }
        guard !databases.isEmpty, let identity = try fileIdentity(url, requiresMultipleLinks: true) else { return .ordinary }
        for database in databases {
            if try fileIdentity(database.url) == identity { return .database(database) }
            for suffix in sidecarSuffixes {
                if try fileIdentity(URL(fileURLWithPath: database.url.path + suffix)) == identity { return .sidecar }
            }
        }
        return .ordinary
    }

    func validateMutation(_ url: URL, includesAncestors: Bool = true) throws {
        let candidate = normalizedPath(url)
        for database in databases {
            let primary = normalizedPath(database.url)
            for protected in [primary] + sidecarSuffixes.map({ primary + $0 }) {
                guard candidate != protected,
                      !candidate.hasPrefix(protected + "/"),
                      !includesAncestors || !protected.hasPrefix(candidate + "/") else {
                    throw LocalDebugFileAccessError.managedDatabase
                }
            }
        }
        switch try kind(of: url) {
        case .ordinary: return
        case .database, .sidecar: throw LocalDebugFileAccessError.managedDatabase
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        // 应用的固定库名均为 ASCII；在区分大小写的卷上也保留相同的受保护名字空间。
        url.standardizedFileURL.path.lowercased()
    }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private func fileIdentity(_ url: URL, requiresMultipleLinks: Bool = false) throws -> Identity? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return nil }
            throw error
        }
        // 链接本身的删除不会修改目标；路径访问层另外禁止追踪链接。
        // 普通单链接文件不可能是另一路径的数据库别名，避免每项都重复读取所有库的属性。
        if requiresMultipleLinks, let links = attributes[.referenceCount] as? NSNumber, links.intValue <= 1 { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }
}
