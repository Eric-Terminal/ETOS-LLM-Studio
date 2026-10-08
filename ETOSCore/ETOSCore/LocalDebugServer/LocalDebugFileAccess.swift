import Foundation

enum LocalDebugFileAccessError: LocalizedError, Equatable {
    case invalidPath, symbolicLink, notRegularFile, invalidBase64, conflictingPaths

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

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
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
            return [
                "name": item.lastPathComponent,
                "isDirectory": type == .typeDirectory,
                "isSymbolicLink": type == .typeSymbolicLink,
                "size": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                "modificationDate": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            ]
        }
    }

    func download(path: String) throws -> [String: Any] {
        let source = try url(for: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalDebugFileAccessError.notRegularFile }
        try Task.checkCancellation()
        let data = try Data(contentsOf: source)
        try Task.checkCancellation()
        return ["path": path, "data": data.base64EncodedString(), "size": data.count]
    }

    @discardableResult
    func upload(path: String, base64: String) throws -> Int {
        let destination = try url(for: path)
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
        try FileManager.default.removeItem(at: target)
    }

    func makeDirectory(path: String) throws {
        let directory = try url(for: path.trimmingCharacters(in: .whitespaces), allowRoot: true)
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

    /// 原全量命令的文件删除部分；活动数据库和其他写入者的停止仍由恢复协调层负责。
    func clearContents() throws {
        try Task.checkCancellation()
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // 删除一旦开始就完成本次目录清理，不能因任务取消而假装事务已经回滚。
        for item in contents { try FileManager.default.removeItem(at: item) }
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
                else if type == .typeRegular { files.append(relativePath) }
                else { skipped.append(relativePath) }
            }
        }
        // 传输协议只表示普通文件；明确返回跳过项，不将链接目标内容混入备份，也不追踪循环链接。
        return Scan(paths: files.sorted(), skippedPaths: skipped.sorted())
    }
}
