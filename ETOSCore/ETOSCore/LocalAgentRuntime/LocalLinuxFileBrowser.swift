import Foundation

/// 用户文件浏览沿用 guest 路径语义；与 Agent 的 no-follow 文件工具分开。
protocol LocalLinuxBrowsingFileSystem: Sendable {
    func statGuestFile(path: String, requestID: UInt64, noFollow: Bool) async throws -> LocalLinuxGuestFileInfo
    func listGuestDirectory(path: String, requestID: UInt64, cursor: UInt64, maximumEntryCount: UInt32, noFollow: Bool) async throws -> LocalLinuxGuestDirectoryPage
    func readGuestFile(path: String, requestID: UInt64, offset: UInt64, maximumByteCount: UInt32, noFollow: Bool) async throws -> LocalLinuxGuestFileReadResult
    func writeGuestFile(path: String, requestID: UInt64, data: Data, mode: UInt32, noFollow: Bool) async throws
    func removeGuestFile(path: String, requestID: UInt64, recursive: Bool, noFollow: Bool) async throws
}

extension iSHAppleBridgeAdapter: LocalLinuxBrowsingFileSystem { }

public struct LocalLinuxBrowserNode: Sendable, Equatable {
    public let path: String
    public let info: LocalLinuxGuestFileInfo
    public init(path: String, info: LocalLinuxGuestFileInfo) { self.path = path; self.info = info }
}

public struct LocalLinuxBrowserDirectory: Sendable {
    public let node: LocalLinuxBrowserNode
    public let resolvedInfo: LocalLinuxGuestFileInfo
    public let page: LocalLinuxGuestDirectoryPage
}

public struct LocalLinuxBrowserPreview: Sendable {
    public enum ReadOnlyReason: Equatable, Sendable { case large, binary, invalidUTF8, special }
    public let node: LocalLinuxBrowserNode
    public let resolvedInfo: LocalLinuxGuestFileInfo
    public let content: String
    public let readOnlyReason: ReadOnlyReason?
    // 完整文本原字节仅用于保存前比较，不发给页面向导或写入历史。
    let originalData: Data
    public var isEditable: Bool { readOnlyReason == nil }
}

public enum LocalLinuxBrowserSelection: Sendable {
    case directory(String)
    case file(LocalLinuxBrowserPreview)
}

public enum LocalLinuxFileBrowserError: LocalizedError {
    case changed, readOnly, busy
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("Linux 文件已变化，请刷新后重试。", comment: "")
        case .readOnly: NSLocalizedString("此文件预览不可编辑。", comment: "")
        case .busy: NSLocalizedString("文件操作正在进行，请稍后重试。", comment: "")
        }
    }
}

public actor LocalLinuxFileBrowser {
    public static let shared = LocalLinuxFileBrowser(fileSystem: iSHAppleBridgeAdapter.shared)
    public static let previewByteLimit: UInt32 = 262_144
    private let fileSystem: any LocalLinuxBrowsingFileSystem
    private var mutating = false
    private var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    init(fileSystem: any LocalLinuxBrowsingFileSystem) { self.fileSystem = fileSystem }

    public func directory(path: String, cursor: UInt64 = 0, original: LocalLinuxBrowserDirectory? = nil) async throws -> LocalLinuxBrowserDirectory {
        try Task.checkCancellation()
        let node = try await node(path)
        let resolved = try await fileSystem.statGuestFile(path: path, requestID: requestID(), noFollow: false)
        if let original {
            try Self.requireSame(node, original.node)
            guard Self.sameRevision(resolved, original.resolvedInfo) else { throw LocalLinuxFileBrowserError.changed }
        }
        let page = try await fileSystem.listGuestDirectory(path: path, requestID: requestID(), cursor: cursor, maximumEntryCount: 256, noFollow: false)
        try Task.checkCancellation()
        try Self.requireSame(try await self.node(path), node)
        let after = try await fileSystem.statGuestFile(path: path, requestID: requestID(), noFollow: false)
        guard Self.sameRevision(after, resolved) else { throw LocalLinuxFileBrowserError.changed }
        guard page.isComplete || page.nextCursor != cursor else { throw LocalLinuxFileBrowserError.changed }
        return LocalLinuxBrowserDirectory(node: node, resolvedInfo: resolved, page: page)
    }

    public func open(path: String) async throws -> LocalLinuxBrowserSelection {
        try Task.checkCancellation()
        let node = try await node(path)
        let resolved = try await fileSystem.statGuestFile(path: path, requestID: requestID(), noFollow: false)
        if resolved.isDirectory { return .directory(path) }
        // FIFO、设备和 socket 不能按普通文件读取，否则等待数据可能拖住内核收尾。
        guard resolved.isRegularFile else {
            return .file(LocalLinuxBrowserPreview(node: node, resolvedInfo: resolved, content: "", readOnlyReason: .special, originalData: Data()))
        }
        let result = try await fileSystem.readGuestFile(path: path, requestID: requestID(), offset: 0, maximumByteCount: Self.previewByteLimit, noFollow: false)
        try Task.checkCancellation()
        try Self.requireSame(try await self.node(path), node)
        let after = try await fileSystem.statGuestFile(path: path, requestID: requestID(), noFollow: false)
        guard Self.sameRevision(after, resolved) else { throw LocalLinuxFileBrowserError.changed }
        let reason: LocalLinuxBrowserPreview.ReadOnlyReason?
        let content: String
        if result.data.contains(0) { reason = .binary; content = "" }
        else if !result.isComplete { reason = .large; content = String(decoding: result.data, as: UTF8.self) }
        // Foundation 解码可能移除 UTF-8 BOM；校验通过后用 Swift 解码保留原有标记。
        else if String(data: result.data, encoding: .utf8) != nil { reason = nil; content = String(decoding: result.data, as: UTF8.self) }
        else { reason = .invalidUTF8; content = String(decoding: result.data, as: UTF8.self) }
        return .file(LocalLinuxBrowserPreview(node: node, resolvedInfo: resolved, content: content,
            readOnlyReason: reason, originalData: reason == nil ? result.data : Data()))
    }

    public func save(_ original: LocalLinuxBrowserPreview, content: String) async throws {
        guard !mutating else { throw LocalLinuxFileBrowserError.busy }
        guard original.isEditable else { throw LocalLinuxFileBrowserError.readOnly }
        mutating = true; defer { mutating = false }
        try Task.checkCancellation()
        guard case .file(let current) = try await open(path: original.node.path), current.isEditable,
              Self.sameRevision(current.resolvedInfo, original.resolvedInfo), current.originalData == original.originalData else {
            throw LocalLinuxFileBrowserError.changed
        }
        try Self.requireSame(current.node, original.node)
        try Task.checkCancellation()
        // 核对阻止已发生的外部修改；guest 进程仍可在核对与实际写入间操作文件，不能宣称文件锁或快照事务。
        try await fileSystem.writeGuestFile(path: original.node.path, requestID: requestID(), data: Data(content.utf8),
            mode: original.resolvedInfo.mode & 0o7777, noFollow: false)
    }

    public func remove(_ original: LocalLinuxBrowserNode) async throws {
        guard !mutating else { throw LocalLinuxFileBrowserError.busy }
        mutating = true; defer { mutating = false }
        try Task.checkCancellation()
        try Self.requireSame(try await node(original.path), original)
        try Task.checkCancellation()
        // 删除符号链接只移除链接本身；递归目录删除仍由 guest 的权限和挂载语义决定。
        try await fileSystem.removeGuestFile(path: original.path, requestID: requestID(), recursive: original.info.isDirectory, noFollow: false)
    }

    public nonisolated static func isCriticalSystemPath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.isEmpty || (components.count == 1 && ["bin", "etc", "lib", "sbin", "usr"].contains(String(components[0])))
    }

    static func sameRevision(_ lhs: LocalLinuxGuestFileInfo, _ rhs: LocalLinuxGuestFileInfo) -> Bool {
        // 读取会更新 atime；目录回调的 name 也不属于 inode 的版本身份。
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size && lhs.mode == rhs.mode &&
        lhs.linkCount == rhs.linkCount && lhs.userID == rhs.userID && lhs.groupID == rhs.groupID &&
        lhs.modificationTime == rhs.modificationTime && lhs.statusChangeTime == rhs.statusChangeTime
    }

    private static func requireSame(_ lhs: LocalLinuxBrowserNode, _ rhs: LocalLinuxBrowserNode) throws {
        guard lhs.path == rhs.path, sameRevision(lhs.info, rhs.info) else { throw LocalLinuxFileBrowserError.changed }
    }
    private func node(_ path: String) async throws -> LocalLinuxBrowserNode {
        LocalLinuxBrowserNode(path: path, info: try await fileSystem.statGuestFile(path: path, requestID: requestID(), noFollow: true))
    }
    private func requestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }
}
