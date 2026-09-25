import Foundation

/// 共享目录的磁盘操作与 File Provider 回调分离，供后台请求和回归测试使用。
public struct ETOSSharedWorkspaceFiles {
    public static let didChangeNotification = Notification.Name("ETOSSharedWorkspaceFiles.didChange")

    public static func notifyChange() {
        #if os(iOS)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        #endif
    }

    public let layout: ETOSSharedStorageLayout
    private let fileManager: FileManager

    public init(layout: ETOSSharedStorageLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// 不在扩展初始化时访问磁盘；临时不可用的目录可以在下一次请求时重新准备。
    public func prepare() throws {
        try layout.prepare(fileManager: fileManager)
    }

    public func children(of directory: URL) throws -> [URL] {
        let prefix = layout.container.standardizedFileURL.path + "/"
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
        _ = try ETOSSharedWorkspacePathValidator.components(for: String(path.dropFirst(prefix.count)))
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            // 深度边界与按 ID 读取保持一致，不能让一个超深目录阻断整个工作集同步。
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            guard (try? ETOSSharedWorkspacePathValidator.components(for: relative)) != nil else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            // Linux 可能创建 socket/FIFO；单个不支持的节点不能使整个文件夹无法打开。
            return values.isSymbolicLink != true && (values.isDirectory == true || values.isRegularFile == true)
        }
    }

    /// 未单独跟踪系统已下载的文件，因此工作集必须包含全部公开目录及其后代。
    public func workingSet() throws -> [URL] {
        var items = [layout.shared, layout.exports]
        var directories = items
        while let directory = directories.popLast() {
            let children = try children(of: directory)
            items.append(contentsOf: children)
            for child in children {
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    directories.append(child)
                }
            }
        }
        return items
    }

    public func copyContents(at source: URL, toTemporaryDirectory directory: URL) throws -> URL {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let destination = directory.appendingPathComponent(UUID().uuidString)
        do {
            // 系统会接管并删除交付的文件，只能给它副本，不能交出 Shared/Exports 中的原件。
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
