import Foundation

enum LocalDebugFileAccessError: LocalizedError, Equatable {
    case invalidPath, symbolicLink, notRegularFile, invalidBase64, conflictingPaths, managedDatabase, databaseSidecar

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            NSLocalizedString("The file path must stay inside the app's Documents folder.", comment: "调试文件路径越界")
        case .symbolicLink:
            NSLocalizedString("Symbolic links cannot be followed during remote file access.", comment: "调试文件符号链接边界")
        case .notRegularFile:
            NSLocalizedString("Only regular files can be downloaded.", comment: "调试文件类型限制")
        case .invalidBase64:
            NSLocalizedString("The uploaded file data is not valid Base64.", comment: "调试上传数据格式")
        case .conflictingPaths:
            NSLocalizedString("The upload contains duplicate or conflicting file paths.", comment: "调试批量上传路径冲突")
        case .managedDatabase:
            NSLocalizedString("Active database files and their parent folders must be changed through database tools or a full restore.", comment: "调试文件写入保护")
        case .databaseSidecar:
            NSLocalizedString("Download the database file instead of its WAL, SHM, or journal files.", comment: "调试数据库侧文件下载限制")
        }
    }
}

/// 同一入口校验浏览、读取和写入路径；所有方法只由后台文件操作调用。
struct LocalDebugFileAccess: Sendable {
    struct Scan: Sendable {
        let paths: [String]
        let skippedPaths: [String]
    }

    let root: URL
    let databasePolicy: LocalDebugDatabaseFilePolicy
    private let temporaryDirectory: URL
    private let exportDatabase: @Sendable (LocalDebugManagedDatabase, URL) throws -> Void

    init(root: URL, managedDatabases: [LocalDebugManagedDatabase] = [],
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         exportDatabase: @escaping @Sendable (LocalDebugManagedDatabase, URL) throws -> Void = { try Persistence.exportDebugDatabase($0, to: $1) }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        databasePolicy = LocalDebugDatabaseFilePolicy(databases: managedDatabases)
        self.temporaryDirectory = temporaryDirectory
        self.exportDatabase = exportDatabase
    }

    func url(for path: String, allowRoot: Bool = false, allowLeafSymlink: Bool = false) throws -> URL {
        try Task.checkCancellation()
        guard !path.hasPrefix("/"), !path.contains("\0") else { throw LocalDebugFileAccessError.invalidPath }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") else { throw LocalDebugFileAccessError.invalidPath }
        let names = components.filter { $0 != "." }
        guard allowRoot || !names.isEmpty else { throw LocalDebugFileAccessError.invalidPath }
        var candidate = root
        for (index, name) in names.enumerated() {
            try Task.checkCancellation()
            candidate.appendPathComponent(name)
            // attributesOfItem 检查链接本身，悬空链接也不能冒充不存在的父目录。
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: candidate.path) }
            catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain,
                   error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { continue }
                throw error
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                guard allowLeafSymlink && index == names.count - 1 else { throw LocalDebugFileAccessError.symbolicLink }
            }
        }
        let standardized = candidate.standardizedFileURL
        guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else {
            throw LocalDebugFileAccessError.invalidPath
        }
        return standardized
    }

    func list(path: String) throws -> [[String: Any]] {
        let directory = try url(for: path.trimmingCharacters(in: .whitespaces), allowRoot: true)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let type = attributes[.type] as? FileAttributeType
            let managed: Bool, sidecar: Bool
            switch try databasePolicy.kind(of: item) {
            case .ordinary: managed = false; sidecar = false
            case .database: managed = true; sidecar = false
            case .sidecar: managed = true; sidecar = true
            }
            return [
                "name": item.lastPathComponent,
                "isDirectory": type == .typeDirectory,
                "isSymbolicLink": type == .typeSymbolicLink,
                "isManagedDatabase": managed,
                "isDatabaseSidecar": sidecar,
                "size": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                "modificationDate": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            ]
        }
    }

    func download(path: String) throws -> [String: Any] {
        let source = try url(for: path)
        let kind = try databasePolicy.kind(of: source)
        if case .sidecar = kind { throw LocalDebugFileAccessError.databaseSidecar }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalDebugFileAccessError.notRegularFile }
        try Task.checkCancellation()
        let data: Data, isSnapshot: Bool
        if case .database(let database) = kind {
            let directory = try SyncTemporaryFileCleaner.makeDirectoryURL(prefix: "ETOS-Debug-Download", temporaryDirectory: temporaryDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let exported = directory.appendingPathComponent("database.sqlite")
            try exportDatabase(database, exported)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.path)
            data = try Data(contentsOf: exported)
            isSnapshot = true
        } else {
            data = try Data(contentsOf: source)
            isSnapshot = false
        }
        try Task.checkCancellation()
        return ["path": path, "data": data.base64EncodedString(), "size": data.count, "database_snapshot": isSnapshot]
    }

    @discardableResult
    func upload(path: String, base64: String) throws -> Int {
        let destination = try url(for: path)
        try databasePolicy.validateMutation(destination)
        guard let data = Data(base64Encoded: base64) else { throw LocalDebugFileAccessError.invalidBase64 }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 原子替换普通文件，写入失败时不留下被截断的旧文件；整库恢复仍需外层协调连接。
        try data.write(to: destination, options: .atomic)
        return data.count
    }

    func delete(path: String) throws {
        // 可删除链接这个目录项，但不会递归进入它的目标；空路径和根目录始终拒绝。
        let target = try url(for: path, allowLeafSymlink: true)
        try databasePolicy.validateMutation(target)
        try FileManager.default.removeItem(at: target)
    }

    func makeDirectory(path: String) throws {
        let directory = try url(for: path.trimmingCharacters(in: .whitespaces), allowRoot: true)
        try databasePolicy.validateMutation(directory, includesAncestors: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func validateUploadPaths(_ paths: [String]) throws {
        var destinations: Set<String> = []
        for path in paths {
            let destination = try url(for: path).path
            guard destinations.insert(destination).inserted else { throw LocalDebugFileAccessError.conflictingPaths }
        }
        for destination in destinations {
            try Task.checkCancellation()
            var parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
            while parent.path != root.path {
                guard !destinations.contains(parent.path) else { throw LocalDebugFileAccessError.conflictingPaths }
                parent.deleteLastPathComponent()
            }
        }
    }

    func scan() throws -> Scan {
        var pending = [""], files: [String] = [], skipped: [String] = []
        while let relativeDirectory = pending.popLast() {
            let directory = try url(for: relativeDirectory, allowRoot: true)
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for item in contents {
                try Task.checkCancellation()
                let relativePath = relativeDirectory.isEmpty ? item.lastPathComponent : relativeDirectory + "/" + item.lastPathComponent
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeDirectory { pending.append(relativePath) }
                else if type == .typeRegular {
                    if case .sidecar = try databasePolicy.kind(of: item) { skipped.append(relativePath) }
                    else { files.append(relativePath) }
                }
                else { skipped.append(relativePath) }
            }
        }
        // 传输协议只表示普通文件；明确返回跳过项，不将链接目标内容混入备份，也不追踪循环链接。
        return Scan(paths: files.sorted(), skippedPaths: skipped.sorted())
    }
}
