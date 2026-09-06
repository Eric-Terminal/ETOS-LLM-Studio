// ============================================================================
// MemoryTransferService.swift
// ETOS LLM Studio
// ============================================================================

import CryptoKit
import Foundation
import ZIPFoundation

public enum MemoryTransferError: LocalizedError, Equatable {
    case archiveTooLarge
    case tooManyEntries
    case expandedPayloadTooLarge
    case entryTooLarge(String)
    case invalidPath(String)
    case duplicatePath(String)
    case missingManifest
    case invalidManifest
    case unsupportedVersion(Int)
    case duplicateMemoryID(UUID)
    case invalidChecksum(String)
    case archiveChanged
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .archiveTooLarge:
            return NSLocalizedString("导入失败：记忆归档文件超过 64 MB。", comment: "Memory archive compressed size error")
        case .tooManyEntries:
            return NSLocalizedString("导入失败：记忆归档包含过多文件。", comment: "Memory archive entry count error")
        case .expandedPayloadTooLarge:
            return NSLocalizedString("导入失败：记忆归档展开后超过 128 MB。", comment: "Memory archive expanded size error")
        case .entryTooLarge(let path):
            return String(format: NSLocalizedString("导入失败：归档条目 %@ 过大。", comment: "Memory archive entry too large error"), path)
        case .invalidPath(let path):
            return String(format: NSLocalizedString("导入失败：归档路径 %@ 不安全。", comment: "Memory archive unsafe path error"), path)
        case .duplicatePath(let path):
            return String(format: NSLocalizedString("导入失败：归档路径 %@ 重复。", comment: "Memory archive duplicate path error"), path)
        case .missingManifest:
            return NSLocalizedString("导入失败：归档缺少 manifest.json。", comment: "Memory archive missing manifest error")
        case .invalidManifest:
            return NSLocalizedString("导入失败：文件内容不是有效的记忆归档。", comment: "Memory archive invalid manifest error")
        case .unsupportedVersion(let version):
            return String(format: NSLocalizedString("导入失败：不支持记忆归档版本 %d。", comment: "Memory archive unsupported version error"), version)
        case .duplicateMemoryID(let id):
            return String(format: NSLocalizedString("导入失败：记忆 ID %@ 重复。", comment: "Memory archive duplicate ID error"), id.uuidString)
        case .invalidChecksum(let path):
            return String(format: NSLocalizedString("导入失败：%@ 的完整性校验不匹配。", comment: "Memory archive checksum error"), path)
        case .archiveChanged:
            return NSLocalizedString("导入文件在预览后发生变化，请重新预览。", comment: "Memory archive changed after preview error")
        case .writeFailed:
            return NSLocalizedString("无法写入记忆导出文件。", comment: "Memory export write error")
        }
    }
}

public struct MemoryArchiveManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let memories: [MemoryArchiveEntry]

    public init(exportedAt: Date, memories: [MemoryArchiveEntry]) {
        format = "com.ericterminal.els.memory-archive"
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.memories = memories
    }
}

public struct MemoryArchiveEntry: Codable, Equatable, Sendable {
    public let snapshot: MemoryVersionSnapshot
    public let markdownPath: String
    public let markdownSHA256: String

    public init(snapshot: MemoryVersionSnapshot, markdownPath: String, markdownSHA256: String) {
        self.snapshot = snapshot
        self.markdownPath = markdownPath
        self.markdownSHA256 = markdownSHA256
    }
}

public enum MemoryImportDisposition: String, Codable, Sendable {
    case added
    case updated
    case unchanged
    case conflict
}

public struct MemoryImportPreviewItem: Identifiable, Equatable, Sendable {
    public var id: UUID { incoming.id }
    public let incoming: MemoryVersionSnapshot
    public let existing: MemoryVersionSnapshot?
    public let disposition: MemoryImportDisposition
}

public struct MemoryImportPreview: Equatable, Identifiable, Sendable {
    public let sourceURL: URL
    public let sourceSHA256: String
    public let exportedAt: Date
    public let items: [MemoryImportPreviewItem]

    public var id: String { sourceSHA256 }

    public var addedCount: Int { items.count { $0.disposition == .added } }
    public var updatedCount: Int { items.count { $0.disposition == .updated } }
    public var conflictCount: Int { items.count { $0.disposition == .conflict } }
    public var archivedCount: Int {
        items.count { $0.incoming.isArchived && [.added, .updated].contains($0.disposition) }
    }
}

public struct MemoryImportResult: Equatable, Sendable {
    public let receipt: MemoryTransferReceipt
    public let importedCount: Int
}

public final class MemoryTransferService: @unchecked Sendable {
    private static let maximumArchiveBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumExpandedBytes: UInt64 = 128 * 1_024 * 1_024
    private static let maximumEntryBytes: UInt64 = 8 * 1_024 * 1_024
    private static let maximumEntryCount = 10_000
    private static let stableFileDate = Date(timeIntervalSince1970: 315_532_800)

    private let memoryManager: MemoryManager
    private let fileManager: FileManager
    private let exportRoot: URL
    private let now: @Sendable () -> Date

    public init(
        memoryManager: MemoryManager = .shared,
        exportRoot: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.memoryManager = memoryManager
        self.fileManager = fileManager
        self.exportRoot = exportRoot ?? Self.defaultExportRoot(fileManager: fileManager)
        self.now = now
    }

    /// 按日期和类型生成便于阅读、可被 Files 暴露的 Markdown 目录。
    public func exportMarkdownDirectory() async throws -> URL {
        let memories = await memoryManager.getAllMemories()
        return try await performOffMain {
            let exportedAt = self.now()
            let directory = self.exportRoot.appendingPathComponent(
                "Memory-Markdown-\(Self.fileTimestamp(exportedAt))-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try self.prepareEmptyDirectory(directory)
            for memory in memories.sorted(by: Self.stableMemoryOrder) {
                let relativePath = Self.markdownRelativePath(for: memory)
                let fileURL = directory.appendingPathComponent(relativePath, isDirectory: false)
                try self.fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.markdownData(for: MemoryVersionSnapshot(memory: memory)).write(
                    to: fileURL,
                    options: [.atomic, .completeFileProtection]
                )
                try self.fileManager.setAttributes([.modificationDate: Self.stableFileDate], ofItemAtPath: fileURL.path)
            }
            let digest = try Self.directoryDigest(at: directory, fileManager: self.fileManager)
            let receipt = MemoryTransferReceipt(
                kind: .markdownExport,
                fileName: directory.lastPathComponent,
                payloadSHA256: digest,
                addedCount: memories.count,
                archivedCount: memories.count(where: \.isArchived),
                createdAt: exportedAt
            )
            guard self.memoryManager.saveTransferReceipt(receipt) else { throw MemoryTransferError.writeFailed }
            return directory
        }
    }

    /// 生成包含版本化 manifest 与逐条 Markdown 的完整可恢复归档。
    public func exportArchive() async throws -> URL {
        let memories = await memoryManager.getAllMemories()
        return try await performOffMain {
            try self.fileManager.createDirectory(at: self.exportRoot, withIntermediateDirectories: true)
            let exportedAt = self.now()
            let staging = self.exportRoot.appendingPathComponent(".memory-export-\(UUID().uuidString)", isDirectory: true)
            try self.prepareEmptyDirectory(staging)
            defer { try? self.fileManager.removeItem(at: staging) }

            var entries: [MemoryArchiveEntry] = []
            for memory in memories.sorted(by: Self.stableMemoryOrder) {
                let snapshot = MemoryVersionSnapshot(memory: memory)
                let path = "memories/\(memory.id.uuidString.lowercased()).md"
                let data = Self.markdownData(for: snapshot)
                let fileURL = staging.appendingPathComponent(path, isDirectory: false)
                try self.fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                try self.fileManager.setAttributes([.modificationDate: Self.stableFileDate], ofItemAtPath: fileURL.path)
                entries.append(
                    MemoryArchiveEntry(
                        snapshot: snapshot,
                        markdownPath: path,
                        markdownSHA256: Self.sha256(data)
                    )
                )
            }

            let manifest = MemoryArchiveManifest(exportedAt: exportedAt, memories: entries)
            let manifestURL = staging.appendingPathComponent("manifest.json", isDirectory: false)
            try Self.makeEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
            try self.fileManager.setAttributes([.modificationDate: Self.stableFileDate], ofItemAtPath: manifestURL.path)

            let archiveURL = self.exportRoot.appendingPathComponent(
                "Memory-Archive-\(Self.fileTimestamp(exportedAt))-\(UUID().uuidString.lowercased()).etosmemory",
                isDirectory: false
            )
            let archive = try Archive(url: archiveURL, accessMode: .create)
            try archive.addEntry(with: "manifest.json", fileURL: manifestURL, compressionMethod: .deflate)
            for entry in entries {
                try archive.addEntry(
                    with: entry.markdownPath,
                    fileURL: staging.appendingPathComponent(entry.markdownPath),
                    compressionMethod: .deflate
                )
            }
            let payload = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            let receipt = MemoryTransferReceipt(
                kind: .archiveExport,
                fileName: archiveURL.lastPathComponent,
                payloadSHA256: Self.sha256(payload),
                addedCount: memories.count,
                archivedCount: memories.count(where: \.isArchived),
                createdAt: exportedAt
            )
            guard self.memoryManager.saveTransferReceipt(receipt) else { throw MemoryTransferError.writeFailed }
            return archiveURL
        }
    }

    /// 只读取并验证归档，不修改记忆库。
    public func previewImport(from sourceURL: URL) async throws -> MemoryImportPreview {
        let existing = await memoryManager.getAllMemories()
        return try await performOffMain {
            let payload = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            guard UInt64(payload.count) <= Self.maximumArchiveBytes else { throw MemoryTransferError.archiveTooLarge }
            let manifest = try self.validatedManifest(from: payload)
            return Self.makePreview(
                sourceURL: sourceURL,
                sourceSHA256: Self.sha256(payload),
                manifest: manifest,
                existingMemories: existing
            )
        }
    }

    /// 应用已经验证过的预览；冲突保留本地版本，稳定 ID 的较新条目才会更新。
    public func applyImport(_ preview: MemoryImportPreview) async throws -> MemoryImportResult {
        let currentData = try await performOffMain {
            try Data(contentsOf: preview.sourceURL, options: .mappedIfSafe)
        }
        guard Self.sha256(currentData) == preview.sourceSHA256 else {
            throw MemoryTransferError.archiveChanged
        }
        let current = await memoryManager.getAllMemories()
        let refreshed = Self.makePreview(
            sourceURL: preview.sourceURL,
            sourceSHA256: preview.sourceSHA256,
            manifest: MemoryArchiveManifest(
                exportedAt: preview.exportedAt,
                memories: preview.items.map {
                    MemoryArchiveEntry(snapshot: $0.incoming, markdownPath: "", markdownSHA256: "")
                }
            ),
            existingMemories: current
        )
        let receiptID = UUID()
        var importedCount = 0
        for item in refreshed.items where item.disposition == .added || item.disposition == .updated {
            let restored = await memoryManager.restoreMemory(
                item.incoming.memoryItem,
                context: MemoryMutationContext(origin: .imported, transferReceiptID: receiptID)
            )
            if restored { importedCount += 1 }
        }
        let receipt = MemoryTransferReceipt(
            id: receiptID,
            kind: .archiveImport,
            fileName: preview.sourceURL.lastPathComponent,
            payloadSHA256: preview.sourceSHA256,
            addedCount: refreshed.addedCount,
            updatedCount: refreshed.updatedCount,
            conflictCount: refreshed.conflictCount,
            archivedCount: refreshed.archivedCount,
            createdAt: now()
        )
        let didSaveReceipt = try await performOffMain {
            self.memoryManager.saveTransferReceipt(receipt)
        }
        guard didSaveReceipt else { throw MemoryTransferError.writeFailed }
        return MemoryImportResult(receipt: receipt, importedCount: importedCount)
    }

    static func makePreview(
        sourceURL: URL,
        sourceSHA256: String,
        manifest: MemoryArchiveManifest,
        existingMemories: [MemoryItem]
    ) -> MemoryImportPreview {
        let existingByID = Dictionary(uniqueKeysWithValues: existingMemories.map { ($0.id, $0) })
        let items = manifest.memories
            .sorted { $0.snapshot.id.uuidString < $1.snapshot.id.uuidString }
            .map { entry -> MemoryImportPreviewItem in
                let incoming = entry.snapshot
                guard let existingMemory = existingByID[incoming.id] else {
                    return MemoryImportPreviewItem(incoming: incoming, existing: nil, disposition: .added)
                }
                let existing = MemoryVersionSnapshot(memory: existingMemory)
                if incoming.digest == existing.digest {
                    return MemoryImportPreviewItem(incoming: incoming, existing: existing, disposition: .unchanged)
                }
                let incomingDate = incoming.updatedAt ?? incoming.createdAt
                let existingDate = existing.updatedAt ?? existing.createdAt
                let disposition: MemoryImportDisposition = incomingDate > existingDate ? .updated : .conflict
                return MemoryImportPreviewItem(incoming: incoming, existing: existing, disposition: disposition)
            }
        return MemoryImportPreview(
            sourceURL: sourceURL,
            sourceSHA256: sourceSHA256,
            exportedAt: manifest.exportedAt,
            items: items
        )
    }

    func validatedManifest(from data: Data) throws -> MemoryArchiveManifest {
        let archive = try Archive(data: data, accessMode: .read)
        var paths = Set<String>()
        var totalSize: UInt64 = 0
        var entryCount = 0
        var manifestData: Data?
        var markdownData: [String: Data] = [:]
        for entry in archive {
            entryCount += 1
            guard entryCount <= Self.maximumEntryCount else { throw MemoryTransferError.tooManyEntries }
            let path = entry.path
            guard Self.isAllowedArchivePath(path), entry.type == .file else {
                throw MemoryTransferError.invalidPath(path)
            }
            guard paths.insert(path).inserted else { throw MemoryTransferError.duplicatePath(path) }
            let entrySize = UInt64(entry.uncompressedSize)
            guard entrySize <= Self.maximumEntryBytes else { throw MemoryTransferError.entryTooLarge(path) }
            totalSize += entrySize
            guard totalSize <= Self.maximumExpandedBytes else { throw MemoryTransferError.expandedPayloadTooLarge }
            var output = Data()
            _ = try archive.extract(entry) { chunk in output.append(chunk) }
            if path == "manifest.json" {
                manifestData = output
            } else {
                markdownData[path] = output
            }
        }
        guard let manifestData else { throw MemoryTransferError.missingManifest }
        let manifest = try Self.makeDecoder().decode(MemoryArchiveManifest.self, from: manifestData)
        guard manifest.format == "com.ericterminal.els.memory-archive" else {
            throw MemoryTransferError.invalidManifest
        }
        guard manifest.version == MemoryArchiveManifest.currentVersion else {
            throw MemoryTransferError.unsupportedVersion(manifest.version)
        }
        var memoryIDs = Set<UUID>()
        for entry in manifest.memories {
            guard memoryIDs.insert(entry.snapshot.id).inserted else {
                throw MemoryTransferError.duplicateMemoryID(entry.snapshot.id)
            }
            let expectedPath = "memories/\(entry.snapshot.id.uuidString.lowercased()).md"
            guard entry.markdownPath == expectedPath,
                  Self.isMemoryMarkdownPath(entry.markdownPath),
                  let data = markdownData[entry.markdownPath] else {
                throw MemoryTransferError.invalidPath(entry.markdownPath)
            }
            guard
                  !entry.snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0...1).contains(entry.snapshot.importance),
                  (0...1).contains(entry.snapshot.confidence) else {
                throw MemoryTransferError.invalidManifest
            }
            guard Self.sha256(data) == entry.markdownSHA256 else {
                throw MemoryTransferError.invalidChecksum(entry.markdownPath)
            }
        }
        let declaredPaths = Set(manifest.memories.map(\.markdownPath)).union(["manifest.json"])
        guard declaredPaths == paths else {
            throw MemoryTransferError.invalidPath(paths.subtracting(declaredPaths).sorted().first ?? "")
        }
        return manifest
    }

    private func prepareEmptyDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func performOffMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility, operation: operation).value
    }

    private static func markdownData(for snapshot: MemoryVersionSnapshot) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func scalar(_ value: String) -> String {
            let data = try? JSONEncoder().encode(value)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        func date(_ value: Date?) -> String { value.map { scalar(formatter.string(from: $0)) } ?? "null" }
        let entities = snapshot.entities.map(scalar).joined(separator: ", ")
        let lines = [
            "---",
            "id: \(scalar(snapshot.id.uuidString.lowercased()))",
            "kind: \(scalar(snapshot.kind.rawValue))",
            "source: \(scalar(snapshot.source.rawValue))",
            "created_at: \(date(snapshot.createdAt))",
            "updated_at: \(date(snapshot.updatedAt))",
            "archived: \(snapshot.isArchived)",
            "importance: \(snapshot.importance)",
            "confidence: \(snapshot.confidence)",
            "valid_from: \(date(snapshot.validFrom))",
            "valid_until: \(date(snapshot.validUntil))",
            "source_session_id: \(snapshot.sourceSessionID.map { scalar($0.uuidString.lowercased()) } ?? "null")",
            "access_count: \(snapshot.accessCount)",
            "last_accessed_at: \(date(snapshot.lastAccessedAt))",
            "entities: [\(entities)]",
            "---",
            "",
            snapshot.content,
            ""
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func markdownRelativePath(for memory: MemoryItem) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: memory.createdAt)
        return String(
            format: "%04d/%02d/%@/%@.md",
            components.year ?? 1970,
            components.month ?? 1,
            memory.kind.rawValue,
            memory.id.uuidString.lowercased()
        )
    }

    private static func isAllowedArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return false }
        return path == "manifest.json" || isMemoryMarkdownPath(path)
    }

    private static func isMemoryMarkdownPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "memories",
              components[1].hasSuffix(".md") else { return false }
        let idText = String(components[1].dropLast(3))
        return UUID(uuidString: idText) != nil
    }

    private static func stableMemoryOrder(_ lhs: MemoryItem, _ rhs: MemoryItem) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func directoryDigest(at root: URL, fileManager: FileManager) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { throw MemoryTransferError.writeFailed }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: keys).isRegularFile == true {
                files.append(url)
            }
        }
        var payload = Data()
        for url in files.sorted(by: { $0.path < $1.path }) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            payload.append(Data(relative.utf8))
            payload.append(0)
            payload.append(try Data(contentsOf: url))
        }
        return sha256(payload)
    }

    private static func defaultExportRoot(fileManager: FileManager) -> URL {
#if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ericterminal.els") {
            return container.appendingPathComponent("Exports/Memory", isDirectory: true)
        }
#endif
        return StorageUtility.documentsDirectory.appendingPathComponent("Exports/Memory", isDirectory: true)
    }
}
