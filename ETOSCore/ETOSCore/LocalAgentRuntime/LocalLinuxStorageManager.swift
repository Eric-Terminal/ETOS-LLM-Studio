// ============================================================================
// LocalLinuxStorageManager.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux 的宿主目录全部收拢在 Documents/Linux。System 可由内置 seed 重建，
// 因而排除系统备份；Home、Shared、Workspaces 与 Exports 保留为用户数据。
// ============================================================================

import Foundation
import ZIPFoundation

public struct LocalLinuxStorageLayout: Equatable, Sendable {
    public let root: URL
    public let system: URL
    public let rootFS: URL
    public let rootFSData: URL
    public let diagnostics: URL
    public let home: URL
    public let shared: URL
    public let workspaces: URL
    public let exports: URL

    public init(documentsDirectory: URL) {
        root = documentsDirectory.appendingPathComponent("Linux", isDirectory: true)
        system = root.appendingPathComponent("System", isDirectory: true)
        rootFS = system.appendingPathComponent("RootFS", isDirectory: true)
        rootFSData = rootFS.appendingPathComponent("data", isDirectory: true)
        diagnostics = system.appendingPathComponent("Diagnostics", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        shared = root.appendingPathComponent("Shared", isDirectory: true)
        workspaces = root.appendingPathComponent("Workspaces", isDirectory: true)
        exports = root.appendingPathComponent("Exports", isDirectory: true)
    }
}

public enum LocalLinuxSystemIntegrity: Equatable, Sendable {
    case notInstalled
    case installed(seedSHA256: String)
    case damaged(String)
}

public struct LocalLinuxStorageUsage: Equatable, Sendable {
    public let systemBytes: UInt64
    public let homeBytes: UInt64
    public let sharedBytes: UInt64
    public let workspaceBytes: UInt64
    public let exportBytes: UInt64

    public init(
        systemBytes: UInt64,
        homeBytes: UInt64,
        sharedBytes: UInt64,
        workspaceBytes: UInt64,
        exportBytes: UInt64
    ) {
        self.systemBytes = systemBytes
        self.homeBytes = homeBytes
        self.sharedBytes = sharedBytes
        self.workspaceBytes = workspaceBytes
        self.exportBytes = exportBytes
    }

    public var totalBytes: UInt64 {
        systemBytes + homeBytes + sharedBytes + workspaceBytes + exportBytes
    }
}

public struct LocalLinuxRawOutputCursor: Equatable, Hashable, Sendable {
    public let frameOffset: UInt64
    public let payloadOffset: UInt64

    public init(frameOffset: UInt64 = 0, payloadOffset: UInt64 = 0) {
        self.frameOffset = frameOffset
        self.payloadOffset = payloadOffset
    }
}

public struct LocalLinuxRawOutputPage: Equatable, Sendable {
    public let cursor: LocalLinuxRawOutputCursor
    public let text: String
    public let nextCursor: LocalLinuxRawOutputCursor?
    public let isComplete: Bool

    public init(
        cursor: LocalLinuxRawOutputCursor,
        text: String,
        nextCursor: LocalLinuxRawOutputCursor?,
        isComplete: Bool
    ) {
        self.cursor = cursor
        self.text = text
        self.nextCursor = nextCursor
        self.isComplete = isComplete
    }
}

public actor LocalLinuxStorageManager {
    public static let shared = LocalLinuxStorageManager()

    private static let receiptPrefix = "format=ish-rootfs-install-v1\nseed_archive_sha256="
    private static let damageMarkerName = "ETOS-System-Damaged.txt"
    private let fileManager: FileManager
    public nonisolated let layout: LocalLinuxStorageLayout

    public init(
        fileManager: FileManager = .default,
        documentsDirectory: URL = StorageUtility.documentsDirectory
    ) {
        self.fileManager = fileManager
        layout = LocalLinuxStorageLayout(documentsDirectory: documentsDirectory)
    }

    @discardableResult
    public func prepareLayout() throws -> LocalLinuxStorageLayout {
        for directory in [
            layout.root,
            layout.system,
            layout.diagnostics,
            layout.home,
            layout.shared,
            layout.workspaces,
            layout.exports
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var systemURL = layout.system
        try systemURL.setResourceValues(values)
        return layout
    }

    public func systemIntegrity(expectedSeedSHA256: String? = nil) -> LocalLinuxSystemIntegrity {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: layout.rootFS.path, isDirectory: &isDirectory) else {
            return .notInstalled
        }
        guard isDirectory.boolValue else {
            return .damaged(NSLocalizedString("RootFS 不是目录。", comment: "Damaged Linux RootFS reason"))
        }
        let damageMarker = layout.system.appendingPathComponent(Self.damageMarkerName, isDirectory: false)
        if let reason = try? String(contentsOf: damageMarker, encoding: .utf8), !reason.isEmpty {
            return .damaged(reason)
        }

        let requiredURLs = [
            layout.rootFS.appendingPathComponent("meta.db", isDirectory: false),
            layout.rootFSData,
            layout.rootFS.appendingPathComponent("rootfs-installation.txt", isDirectory: false)
        ]
        guard requiredURLs.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            return .damaged(NSLocalizedString("RootFS 缺少安装收据或文件系统数据。", comment: "Damaged Linux RootFS reason"))
        }

        let receiptURL = requiredURLs[2]
        guard let receipt = try? String(contentsOf: receiptURL, encoding: .utf8),
              receipt.hasPrefix(Self.receiptPrefix) else {
            return .damaged(NSLocalizedString("RootFS 安装收据无效。", comment: "Damaged Linux RootFS reason"))
        }
        let digest = receipt.dropFirst(Self.receiptPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            return .damaged(NSLocalizedString("RootFS 安装摘要无效。", comment: "Damaged Linux RootFS reason"))
        }
        if let expectedSeedSHA256,
           !expectedSeedSHA256.isEmpty,
           digest.caseInsensitiveCompare(expectedSeedSHA256) != .orderedSame {
            return .damaged(NSLocalizedString("RootFS 版本与当前内置系统不一致。", comment: "Damaged Linux RootFS reason"))
        }
        return .installed(seedSHA256: digest.lowercased())
    }

    public func workspace(sessionID: UUID, profileID: UUID? = nil) throws -> LocalAgentWorkspace {
        if var existing = Persistence.loadLocalAgentWorkspaces(sessionID: sessionID).first {
            let directory = layout.root.appendingPathComponent(existing.hostRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existing.lastUsedAt = Date()
            _ = Persistence.saveLocalAgentWorkspace(existing)
            return existing
        }

        let id = UUID()
        let component = id.uuidString.lowercased()
        let relativePath = "Workspaces/\(component)"
        let directory = layout.root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = LocalAgentWorkspace(
            id: id,
            sessionID: sessionID,
            profileID: profileID,
            guestPath: "/workspace/\(component)",
            hostRelativePath: relativePath
        )
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 工作区。", comment: "Save Linux workspace failure")
            )
        }
        return workspace
    }

    public func workspace(id: UUID) throws -> LocalAgentWorkspace {
        guard var workspace = Persistence.loadLocalAgentWorkspaces().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("找不到 Agent Run 对应的 Linux 工作区。", comment: "Missing local Agent workspace")
            )
        }
        let directory = layout.root.appendingPathComponent(workspace.hostRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace.lastUsedAt = Date()
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 工作区。", comment: "Update local Agent workspace failure")
            )
        }
        return workspace
    }

    public func workspaces() -> [LocalAgentWorkspace] {
        Persistence.loadLocalAgentWorkspaces().sorted { lhs, rhs in
            lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    public func localMCPWorkspace(serverID: UUID) throws -> LocalAgentWorkspace {
        if var existing = Persistence.loadLocalAgentWorkspaces().first(where: {
            $0.sessionID == nil && $0.profileID == serverID
        }) {
            let directory = layout.root.appendingPathComponent(existing.hostRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existing.lastUsedAt = Date()
            _ = Persistence.saveLocalAgentWorkspace(existing)
            return existing
        }

        let component = "mcp-" + serverID.uuidString.lowercased()
        let relativePath = "Workspaces/\(component)"
        try fileManager.createDirectory(
            at: layout.root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        let workspace = LocalAgentWorkspace(
            sessionID: nil,
            profileID: serverID,
            guestPath: "/workspace/\(component)",
            hostRelativePath: relativePath
        )
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 工作区。", comment: "Save local MCP workspace failure")
            )
        }
        return workspace
    }

    public func hostURL(for workspace: LocalAgentWorkspace) throws -> URL {
        let candidate = layout.root.appendingPathComponent(workspace.hostRelativePath, isDirectory: true)
        return try checkedDescendant(candidate, of: layout.workspaces)
    }

    public func browserDownloadDirectory(for workspace: LocalAgentWorkspace) throws -> URL {
        let directory = try hostURL(for: workspace)
            .appendingPathComponent("BrowserDownloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func guestURI(forHostURL url: URL, workspace: LocalAgentWorkspace) throws -> String {
        let workspaceURL = try hostURL(for: workspace)
        let resolved = try checkedDescendant(url, of: workspaceURL)
        let relativePath = String(resolved.path.dropFirst(workspaceURL.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let guestPath = relativePath.isEmpty
            ? workspace.guestPath
            : workspace.guestPath + "/" + relativePath
        return "linux://" + guestPath
    }

    public func outputURLs(jobID: UUID, workspace: LocalAgentWorkspace) throws -> (raw: URL, model: URL) {
        let workspaceURL = try hostURL(for: workspace)
        let outputDirectory = workspaceURL
            .appendingPathComponent(".etos", isDirectory: true)
            .appendingPathComponent("Outputs", isDirectory: true)
            .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return (
            outputDirectory.appendingPathComponent("raw.log", isDirectory: false),
            outputDirectory.appendingPathComponent("model.log", isDirectory: false)
        )
    }

    public func relativePath(for url: URL) throws -> String {
        let resolved = try checkedDescendant(url, of: layout.root)
        return String(resolved.path.dropFirst(layout.root.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func readOutput(relativePath: String, maximumBytes: Int) throws -> String {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(1, maximumBytes)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let visible = data.prefix(limit)
        var text = String(decoding: visible, as: UTF8.self)
        if data.count > limit {
            text.append(NSLocalizedString(
                "\n[输出已截断，完整内容保存在工作区附件中。]",
                comment: "Linux output read truncation notice"
            ))
        }
        return text
    }

    public func readRawOutput(relativePath: String, maximumBytes: Int) throws -> String {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(1, maximumBytes)
        var pending = Data()
        var preview = Data()
        var lastMarker: UInt8?

        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while pending.count >= 5 {
                let marker = pending[pending.startIndex]
                guard marker == 1 || marker == 2 || marker == 3 else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                    )
                }
                let length = pending[pending.startIndex + 1 ..< pending.startIndex + 5]
                    .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= 16 * 1_024 * 1_024 else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                    )
                }
                let frameLength = 5 + Int(length)
                guard pending.count >= frameLength else { break }
                if marker != 3, marker != lastMarker {
                    preview.append(contentsOf: (marker == 1 ? "\n[stdout]\n" : "\n[stderr]\n").utf8)
                }
                preview.append(pending[pending.startIndex + 5 ..< pending.startIndex + frameLength])
                pending.removeFirst(frameLength)
                lastMarker = marker
                if preview.count > limit {
                    preview.removeFirst(preview.count - limit)
                }
            }
        }
        return String(decoding: preview, as: UTF8.self)
    }

    /// 按原始帧位置分页，既不会为找页码解析整份日志，也不会在跨页时丢掉超大帧的尾部。
    public func readRawOutputPage(
        relativePath: String,
        cursor: LocalLinuxRawOutputCursor,
        maximumBytes: Int
    ) throws -> LocalLinuxRawOutputPage {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        // stdout/stderr 标签本身也属于页面内容；保留一个最小页宽，避免游标
        // 只写标签却无法推进 payload，导致极小分页参数反复返回同一页。
        let limit = max(16, maximumBytes)
        var frameOffset = cursor.frameOffset
        var payloadOffset = cursor.payloadOffset
        var page = Data()
        var nextCursor: LocalLinuxRawOutputCursor?
        var reachedIncompleteFrame = false

        while page.count < limit, frameOffset < fileSize {
            try handle.seek(toOffset: frameOffset)
            guard let header = try handle.read(upToCount: 5), header.count == 5 else {
                reachedIncompleteFrame = true
                break
            }
            let marker = header[header.startIndex]
            guard marker == 1 || marker == 2 || marker == 3 else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                )
            }
            let payloadLength = header[header.startIndex + 1 ..< header.startIndex + 5]
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard payloadLength <= 16 * 1_024 * 1_024, payloadOffset <= payloadLength else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                )
            }

            let frameEnd = frameOffset + 5 + payloadLength
            guard frameEnd <= fileSize else {
                reachedIncompleteFrame = true
                break
            }

            if payloadOffset == 0, marker != 3 {
                page.append(contentsOf: (marker == 1 ? "\n[stdout]\n" : "\n[stderr]\n").utf8)
            }
            let remainingPayload = payloadLength - payloadOffset
            let availablePageBytes = max(0, limit - page.count)
            let readCount = min(remainingPayload, UInt64(availablePageBytes))
            if readCount > 0 {
                try handle.seek(toOffset: frameOffset + 5 + payloadOffset)
                if let data = try handle.read(upToCount: Int(readCount)) {
                    page.append(data)
                    payloadOffset += UInt64(data.count)
                }
            }

            if payloadOffset < payloadLength {
                nextCursor = LocalLinuxRawOutputCursor(
                    frameOffset: frameOffset,
                    payloadOffset: payloadOffset
                )
                break
            }

            frameOffset = frameEnd
            payloadOffset = 0
            if page.count >= limit, frameOffset < fileSize {
                nextCursor = LocalLinuxRawOutputCursor(frameOffset: frameOffset)
            }
        }

        let complete = !reachedIncompleteFrame && nextCursor == nil && frameOffset >= fileSize
        return LocalLinuxRawOutputPage(
            cursor: cursor,
            text: String(decoding: page, as: UTF8.self),
            nextCursor: nextCursor,
            isComplete: complete
        )
    }

    public func refreshWorkspaceSize(_ workspace: LocalAgentWorkspace) throws -> LocalAgentWorkspace {
        var updated = workspace
        updated.sizeBytes = directorySize(at: try hostURL(for: workspace))
        guard Persistence.saveLocalAgentWorkspace(updated) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 工作区统计。", comment: "Update Linux workspace size failure")
            )
        }
        return updated
    }

    public func exportWorkspace(_ workspace: LocalAgentWorkspace) throws -> URL {
        let source = try hostURL(for: workspace)
        try fileManager.createDirectory(at: layout.exports, withIntermediateDirectories: true)
        let archiveURL = uniqueExportURL(baseName: "Linux-Workspace-\(workspace.id.uuidString)")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            let relativePath = String(item.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            try archive.addEntry(with: relativePath, fileURL: item, compressionMethod: .deflate)
        }
        return archiveURL
    }

    public func deleteWorkspace(_ workspace: LocalAgentWorkspace) throws {
        let url = try hostURL(for: workspace)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard Persistence.deleteLocalAgentWorkspace(id: workspace.id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除 Linux 工作区记录。", comment: "Delete Linux workspace record failure")
            )
        }
    }

    public func deleteSystem(deleteUserData: Bool) throws {
        if fileManager.fileExists(atPath: layout.system.path) {
            try fileManager.removeItem(at: layout.system)
        }
        if deleteUserData {
            for directory in [layout.home, layout.shared, layout.workspaces] where fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        try prepareLayout()
    }

    public func markSystemDamaged(reason: String) throws {
        try prepareLayout()
        let marker = layout.system.appendingPathComponent(Self.damageMarkerName, isDirectory: false)
        try Data(reason.utf8).write(to: marker, options: .atomic)
    }

    /// 迁移只推进安装收据代表的基线版本，不覆盖用户自行安装的软件包或配置。
    public func recordInstalledSeedSHA256(_ seedSHA256: String) throws {
        guard seedSHA256.count == 64, seedSHA256.allSatisfy(\.isHexDigit) else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("migration.targetSeedSHA256")
        }
        let receiptURL = layout.rootFS.appendingPathComponent("rootfs-installation.txt", isDirectory: false)
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("RootFS 缺少安装收据，无法记录系统更新。", comment: "Missing RootFS receipt during migration")
            )
        }
        let receipt = Self.receiptPrefix + seedSHA256.lowercased() + "\n"
        try Data(receipt.utf8).write(to: receiptURL, options: .atomic)
    }

    @discardableResult
    public func preserveCurrentRootFS(reason: String) throws -> URL? {
        guard fileManager.fileExists(atPath: layout.rootFS.path) else { return nil }
        let recoveryRoot = layout.system.appendingPathComponent("Recovered", isDirectory: true)
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var destination = recoveryRoot.appendingPathComponent("RootFS-\(timestamp)", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            destination = recoveryRoot.appendingPathComponent("RootFS-\(UUID().uuidString)", isDirectory: true)
        }
        try fileManager.moveItem(at: layout.rootFS, to: destination)
        let note = destination.appendingPathComponent("ETOS-Recovery-Reason.txt", isDirectory: false)
        try Data(reason.utf8).write(to: note, options: .atomic)
        let marker = layout.system.appendingPathComponent(Self.damageMarkerName, isDirectory: false)
        try? fileManager.removeItem(at: marker)
        return destination
    }

    public func storageUsage() -> LocalLinuxStorageUsage {
        LocalLinuxStorageUsage(
            systemBytes: directorySize(at: layout.system),
            homeBytes: directorySize(at: layout.home),
            sharedBytes: directorySize(at: layout.shared),
            workspaceBytes: directorySize(at: layout.workspaces),
            exportBytes: directorySize(at: layout.exports)
        )
    }

    public func iCloudLinuxDirectory() throws -> URL? {
        guard let container = fileManager.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Linux", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func checkedDescendant(_ candidate: URL, of parent: URL) throws -> URL {
        let resolvedCandidate = candidate.standardizedFileURL
        let resolvedParent = parent.standardizedFileURL
        let prefix = resolvedParent.path.hasSuffix("/") ? resolvedParent.path : resolvedParent.path + "/"
        guard resolvedCandidate.path.hasPrefix(prefix) else {
            throw LocalLinuxRuntimeError.invalidPath(candidate.path)
        }
        return resolvedCandidate
    }

    private func directorySize(at directory: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: UInt64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
        }
        return total
    }

    private func uniqueExportURL(baseName: String) -> URL {
        var candidate = layout.exports.appendingPathComponent(baseName).appendingPathExtension("zip")
        if fileManager.fileExists(atPath: candidate.path) {
            candidate = layout.exports
                .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
                .appendingPathExtension("zip")
        }
        return candidate
    }
}
