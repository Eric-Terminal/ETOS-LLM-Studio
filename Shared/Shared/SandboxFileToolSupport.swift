// ============================================================================
// SandboxFileToolSupport.swift
// ============================================================================
// 沙盒文件工具辅助。
// - 仅允许访问 Documents 根目录及其子路径
// - 提供列目录、读文本、写文本能力
// ============================================================================

import Foundation

public struct SandboxFileEntry: Codable, Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: String?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SandboxFileWriteResult: Codable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let createdParentDirectories: Bool

    public init(path: String, size: Int64, createdParentDirectories: Bool) {
        self.path = path
        self.size = size
        self.createdParentDirectories = createdParentDirectories
    }
}

public struct SandboxFileEditResult: Codable, Hashable, Sendable {
    public let path: String
    public let replacements: Int
    public let size: Int64

    public init(path: String, replacements: Int, size: Int64) {
        self.path = path
        self.replacements = replacements
        self.size = size
    }
}

public struct SandboxFileDeleteResult: Codable, Hashable, Sendable {
    public let path: String
    public let wasDirectory: Bool

    public init(path: String, wasDirectory: Bool) {
        self.path = path
        self.wasDirectory = wasDirectory
    }
}

public struct SandboxFileSearchResult: Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: String?
    public let matchedByName: Bool
    public let matchedByContent: Bool

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: String?,
        matchedByName: Bool,
        matchedByContent: Bool
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.matchedByName = matchedByName
        self.matchedByContent = matchedByContent
    }
}

public struct SandboxFileChunkReadResult: Codable, Hashable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let hasMore: Bool
    public let content: String

    public init(
        path: String,
        startLine: Int,
        endLine: Int,
        totalLines: Int,
        hasMore: Bool,
        content: String
    ) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.totalLines = totalLines
        self.hasMore = hasMore
        self.content = content
    }
}

public struct SandboxFileMoveResult: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let wasDirectory: Bool
    public let createdParentDirectories: Bool
    public let overwroteDestination: Bool

    public init(
        sourcePath: String,
        destinationPath: String,
        wasDirectory: Bool,
        createdParentDirectories: Bool,
        overwroteDestination: Bool
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.wasDirectory = wasDirectory
        self.createdParentDirectories = createdParentDirectories
        self.overwroteDestination = overwroteDestination
    }
}

public struct SandboxFileCopyResult: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let wasDirectory: Bool
    public let createdParentDirectories: Bool
    public let overwroteDestination: Bool

    public init(
        sourcePath: String,
        destinationPath: String,
        wasDirectory: Bool,
        createdParentDirectories: Bool,
        overwroteDestination: Bool
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.wasDirectory = wasDirectory
        self.createdParentDirectories = createdParentDirectories
        self.overwroteDestination = overwroteDestination
    }
}

public struct SandboxDirectoryCreateResult: Codable, Hashable, Sendable {
    public let path: String
    public let created: Bool
    public let createdParentDirectories: Bool

    public init(path: String, created: Bool, createdParentDirectories: Bool) {
        self.path = path
        self.created = created
        self.createdParentDirectories = createdParentDirectories
    }
}

public struct SandboxBatchEditRule: Codable, Hashable, Sendable {
    public let oldText: String
    public let newText: String

    public init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }
}

public struct SandboxFileBatchEditResult: Codable, Hashable, Sendable {
    public let path: String
    public let replacements: Int
    public let rulesApplied: Int
    public let size: Int64

    public init(path: String, replacements: Int, rulesApplied: Int, size: Int64) {
        self.path = path
        self.replacements = replacements
        self.rulesApplied = rulesApplied
        self.size = size
    }
}

public struct SandboxFileUndoResult: Codable, Hashable, Sendable {
    public let operation: String
    public let recordedAt: String

    public init(operation: String, recordedAt: String) {
        self.operation = operation
        self.recordedAt = recordedAt
    }
}

public enum SandboxFileToolError: LocalizedError {
    case invalidPath
    case escapedSandbox
    case directoryExpected(String)
    case fileExpected(String)
    case fileNotFound(String)
    case unsupportedEncoding(String)
    case writeFailed(String)
    case emptyMatchText
    case oldTextNotFound
    case ambiguousMatch(count: Int)
    case deletingRootDirectory
    case missingSearchQuery
    case invalidChunkRange
    case destinationAlreadyExists(String)
    case cannotMoveIntoSelf
    case sourceAndDestinationSame
    case cannotCopyIntoSelf
    case emptyBatchRules
    case noUndoHistory

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return NSLocalizedString("文件路径无效。", comment: "Sandbox tool invalid path")
        case .escapedSandbox:
            return NSLocalizedString("不允许访问沙盒外部路径。", comment: "Sandbox tool escaped sandbox")
        case .directoryExpected(let path):
            return String(
                format: NSLocalizedString("路径“%@”不是目录。", comment: "Sandbox tool directory expected"),
                path
            )
        case .fileExpected(let path):
            return String(
                format: NSLocalizedString("路径“%@”是目录，不能按文件读取。", comment: "Sandbox tool file expected"),
                path
            )
        case .fileNotFound(let path):
            return String(
                format: NSLocalizedString("未找到文件“%@”。", comment: "Sandbox tool file not found"),
                path
            )
        case .unsupportedEncoding(let path):
            return String(
                format: NSLocalizedString("文件“%@”不是 UTF-8 文本，当前工具无法直接读取。", comment: "Sandbox tool unsupported encoding"),
                path
            )
        case .writeFailed(let message):
            return message
        case .emptyMatchText:
            return NSLocalizedString("要替换的旧文本不能为空。", comment: "Sandbox tool empty match text")
        case .oldTextNotFound:
            return NSLocalizedString("未在文件中找到要替换的旧文本。", comment: "Sandbox tool old text not found")
        case .ambiguousMatch(let count):
            return String(
                format: NSLocalizedString("旧文本在文件中出现了 %d 次，请改用 replace_all 或提供更精确的片段。", comment: "Sandbox tool ambiguous match"),
                count
            )
        case .deletingRootDirectory:
            return NSLocalizedString("不允许删除 Documents 根目录。", comment: "Sandbox tool deleting root directory")
        case .missingSearchQuery:
            return NSLocalizedString("请至少提供 name_query 或 content_query 其中之一。", comment: "Sandbox tool missing search query")
        case .invalidChunkRange:
            return NSLocalizedString("分块读取参数无效，请检查 start_line 和 max_lines。", comment: "Sandbox tool invalid chunk range")
        case .destinationAlreadyExists(let path):
            return String(
                format: NSLocalizedString("目标路径“%@”已存在。", comment: "Sandbox tool destination exists"),
                path
            )
        case .cannotMoveIntoSelf:
            return NSLocalizedString("不能把目录移动到其自身或子目录下。", comment: "Sandbox tool move into self")
        case .sourceAndDestinationSame:
            return NSLocalizedString("源路径与目标路径相同，无需移动。", comment: "Sandbox tool source destination same")
        case .cannotCopyIntoSelf:
            return NSLocalizedString("不能把目录复制到其自身或子目录下。", comment: "Sandbox tool copy into self")
        case .emptyBatchRules:
            return NSLocalizedString("批量编辑规则不能为空。", comment: "Sandbox tool empty batch rules")
        case .noUndoHistory:
            return NSLocalizedString("当前没有可撤销的沙盒修改记录。", comment: "Sandbox tool no undo history")
        }
    }
}

public enum SandboxFileToolSupport {
    private struct SandboxUndoEntry {
        let rootPath: String
        let operation: String
        let recordedAt: Date
        let undo: () throws -> Void
        let discard: () -> Void
    }

    private static let undoDateFormatter = ISO8601DateFormatter()
    private static let undoLock = NSLock()
    private static var undoStack: [SandboxUndoEntry] = []
    private static let maxUndoEntries = 64

    public static func listDirectory(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> [SandboxFileEntry] {
        let directoryURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }
        guard isDirectory.boolValue else {
            throw SandboxFileToolError.directoryExpected(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let formatter = ISO8601DateFormatter()
        return contents.compactMap { url in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return SandboxFileEntry(
                    path: normalizedDisplayPath(for: url, rootDirectory: rootDirectory),
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory ?? false,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate.map(formatter.string(from:))
                )
            } catch {
                return nil
            }
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func readTextFile(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        guard !isDirectory.boolValue else {
            throw SandboxFileToolError.fileExpected(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SandboxFileToolError.unsupportedEncoding(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        return content
    }

    public static func writeTextFile(
        relativePath: String,
        content: String,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileWriteResult {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        let parentDirectory = fileURL.deletingLastPathComponent()
        let displayPath = normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory)

        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory)
        var createdDirectories = false

        if parentExists {
            guard isDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法写入文件。", comment: "Sandbox tool parent path not directory"),
                        normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            createdDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox tool parent missing"),
                    normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                )
            )
        }

        var targetIsDirectory: ObjCBool = false
        let existedBeforeWrite = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &targetIsDirectory)
        if existedBeforeWrite && targetIsDirectory.boolValue {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("路径“%@”是目录，不能按文件写入。", comment: "Sandbox tool target is directory"),
                    displayPath
                )
            )
        }

        let previousData = existedBeforeWrite ? (try? Data(contentsOf: fileURL)) : nil

        let data = Data(content.utf8)
        do {
            try data.write(to: fileURL, options: [.atomic])
            StorageUtility.notifyFilesystemMutation(at: fileURL)

            if existedBeforeWrite {
                let restoreData = previousData
                pushUndoEntry(
                    rootDirectory: rootDirectory,
                    operation: "write_sandbox_file"
                ) {
                    if let restoreData {
                        try restoreData.write(to: fileURL, options: [.atomic])
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    } else if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    }
                }
            } else {
                pushUndoEntry(
                    rootDirectory: rootDirectory,
                    operation: "write_sandbox_file"
                ) {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    }
                }
            }

            return SandboxFileWriteResult(
                path: displayPath,
                size: Int64(data.count),
                createdParentDirectories: createdDirectories
            )
        } catch {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("写入文件“%@”失败：%@", comment: "Sandbox tool write failed"),
                    normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                    error.localizedDescription
                )
            )
        }
    }

    public static func diffTextFile(
        relativePath: String,
        updatedContent: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        let diff = simpleUnifiedDiff(
            original: currentContent,
            updated: updatedContent
        )
        return diff.isEmpty
            ? NSLocalizedString("内容没有变化。", comment: "Sandbox diff no changes")
            : diff
    }

    public static func replaceText(
        relativePath: String,
        oldText: String,
        newText: String,
        replaceAll: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileEditResult {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        guard !oldText.isEmpty else {
            throw SandboxFileToolError.emptyMatchText
        }

        let matchCount = occurrenceCount(of: oldText, in: currentContent)
        guard matchCount > 0 else {
            throw SandboxFileToolError.oldTextNotFound
        }
        if matchCount > 1 && !replaceAll {
            throw SandboxFileToolError.ambiguousMatch(count: matchCount)
        }

        let nextContent: String
        let replacements: Int
        if replaceAll {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText)
            replacements = matchCount
        } else {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText, options: [], range: currentContent.range(of: oldText))
            replacements = 1
        }

        let writeResult = try writeTextFile(
            relativePath: relativePath,
            content: nextContent,
            createIntermediateDirectories: true,
            rootDirectory: rootDirectory
        )
        return SandboxFileEditResult(
            path: writeResult.path,
            replacements: replacements,
            size: writeResult.size
        )
    }

    public static func deleteItem(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileDeleteResult {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Documents" || trimmed == "/" {
            throw SandboxFileToolError.deletingRootDirectory
        }

        let targetURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory))
        }

        let backupURL = try backupItem(at: targetURL)
        let displayPath = normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory)
        try FileManager.default.removeItem(at: targetURL)
        StorageUtility.notifyFilesystemMutation(at: targetURL)
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "delete_sandbox_item",
            discard: { try? FileManager.default.removeItem(at: backupURL) }
        ) {
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SandboxFileToolError.destinationAlreadyExists(displayPath)
            }
            try FileManager.default.copyItem(at: backupURL, to: targetURL)
            StorageUtility.notifyFilesystemMutation(at: targetURL)
            try? FileManager.default.removeItem(at: backupURL)
        }

        return SandboxFileDeleteResult(
            path: displayPath,
            wasDirectory: isDirectory.boolValue
        )
    }

    public static func createDirectory(
        relativePath: String,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxDirectoryCreateResult {
        let directoryURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        let displayPath = normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory)

        var isDirectory: ObjCBool = false
        let alreadyExists = FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        if alreadyExists {
            guard isDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("路径“%@”已存在且不是目录。", comment: "Sandbox create directory path exists"),
                        displayPath
                    )
                )
            }
            return SandboxDirectoryCreateResult(
                path: displayPath,
                created: false,
                createdParentDirectories: false
            )
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory)
        let createdParentDirectories = !parentExists && createIntermediateDirectories

        if parentExists {
            guard parentIsDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法创建目录。", comment: "Sandbox create directory parent not directory"),
                        normalizedDisplayPath(for: parentURL, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if !createIntermediateDirectories {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox create directory parent missing"),
                    normalizedDisplayPath(for: parentURL, rootDirectory: rootDirectory)
                )
            )
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: createIntermediateDirectories
        )
        StorageUtility.notifyFilesystemMutation(at: directoryURL)

        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "create_sandbox_directory"
        ) {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
                StorageUtility.notifyFilesystemMutation(at: directoryURL)
            }
        }

        return SandboxDirectoryCreateResult(
            path: displayPath,
            created: true,
            createdParentDirectories: createdParentDirectories
        )
    }

    public static func copyItem(
        from sourceRelativePath: String,
        to destinationRelativePath: String,
        overwrite: Bool = false,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileCopyResult {
        let sourceURL = try resolveURL(relativePath: sourceRelativePath, rootDirectory: rootDirectory, allowRoot: false)
        let destinationURL = try resolveURL(relativePath: destinationRelativePath, rootDirectory: rootDirectory, allowRoot: false)

        let sourceDisplayPath = normalizedDisplayPath(for: sourceURL, rootDirectory: rootDirectory)
        let destinationDisplayPath = normalizedDisplayPath(for: destinationURL, rootDirectory: rootDirectory)
        guard sourceURL.path != destinationURL.path else {
            throw SandboxFileToolError.sourceAndDestinationSame
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw SandboxFileToolError.fileNotFound(sourceDisplayPath)
        }

        if sourceIsDirectory.boolValue {
            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationURL.standardizedFileURL.path
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw SandboxFileToolError.cannotCopyIntoSelf
            }
        }

        let destinationParent = destinationURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &parentIsDirectory)
        var createdParentDirectories = false
        if parentExists {
            guard parentIsDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法复制。", comment: "Sandbox copy parent not directory"),
                        normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            createdParentDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox copy parent missing"),
                    normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                )
            )
        }

        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        var overwrittenBackupURL: URL?
        if destinationExists {
            guard overwrite else {
                throw SandboxFileToolError.destinationAlreadyExists(destinationDisplayPath)
            }
            overwrittenBackupURL = try backupItem(at: destinationURL)
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        StorageUtility.notifyFilesystemMutation(at: destinationURL)

        let backupURLForUndo = overwrittenBackupURL
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "copy_sandbox_item",
            discard: {
                if let backupURLForUndo {
                    try? FileManager.default.removeItem(at: backupURLForUndo)
                }
            }
        ) {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
            if let backupURLForUndo {
                try FileManager.default.copyItem(at: backupURLForUndo, to: destinationURL)
                try? FileManager.default.removeItem(at: backupURLForUndo)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
        }

        return SandboxFileCopyResult(
            sourcePath: sourceDisplayPath,
            destinationPath: destinationDisplayPath,
            wasDirectory: sourceIsDirectory.boolValue,
            createdParentDirectories: createdParentDirectories,
            overwroteDestination: destinationExists
        )
    }

    public static func batchReplaceText(
        relativePath: String,
        rules: [SandboxBatchEditRule],
        replaceAll: Bool = false,
        ignoreMissing: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileBatchEditResult {
        guard !rules.isEmpty else {
            throw SandboxFileToolError.emptyBatchRules
        }
        let originalContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        var currentContent = originalContent

        var totalReplacements = 0
        var appliedRules = 0
        for rule in rules {
            guard !rule.oldText.isEmpty else {
                throw SandboxFileToolError.emptyMatchText
            }

            let matchCount = occurrenceCount(of: rule.oldText, in: currentContent)
            if matchCount == 0 {
                if ignoreMissing {
                    continue
                }
                throw SandboxFileToolError.oldTextNotFound
            }
            if matchCount > 1 && !replaceAll {
                throw SandboxFileToolError.ambiguousMatch(count: matchCount)
            }

            if replaceAll {
                currentContent = currentContent.replacingOccurrences(of: rule.oldText, with: rule.newText)
                totalReplacements += matchCount
            } else if let firstRange = currentContent.range(of: rule.oldText) {
                currentContent = currentContent.replacingCharacters(in: firstRange, with: rule.newText)
                totalReplacements += 1
            }
            appliedRules += 1
        }

        if currentContent == originalContent {
            let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
            let data = try Data(contentsOf: fileURL)
            return SandboxFileBatchEditResult(
                path: normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                replacements: totalReplacements,
                rulesApplied: appliedRules,
                size: Int64(data.count)
            )
        }

        let writeResult = try writeTextFile(
            relativePath: relativePath,
            content: currentContent,
            createIntermediateDirectories: true,
            rootDirectory: rootDirectory
        )
        return SandboxFileBatchEditResult(
            path: writeResult.path,
            replacements: totalReplacements,
            rulesApplied: appliedRules,
            size: writeResult.size
        )
    }

    public static func undoLastMutation(
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileUndoResult {
        let rootPath = rootDirectory.standardizedFileURL.path
        guard let entry = popUndoEntry(for: rootPath) else {
            throw SandboxFileToolError.noUndoHistory
        }

        do {
            try entry.undo()
            entry.discard()
            return SandboxFileUndoResult(
                operation: entry.operation,
                recordedAt: undoDateFormatter.string(from: entry.recordedAt)
            )
        } catch {
            restoreUndoEntry(entry)
            throw error
        }
    }

    public static func searchItems(
        relativePath: String,
        nameQuery: String?,
        contentQuery: String?,
        maxResults: Int = 20,
        includeDirectories: Bool = false,
        caseSensitive: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> [SandboxFileSearchResult] {
        let baseURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: baseURL, rootDirectory: rootDirectory))
        }
        guard isDirectory.boolValue else {
            throw SandboxFileToolError.directoryExpected(normalizedDisplayPath(for: baseURL, rootDirectory: rootDirectory))
        }

        let trimmedNameQuery = nameQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContentQuery = contentQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNameQuery = !(trimmedNameQuery ?? "").isEmpty
        let hasContentQuery = !(trimmedContentQuery ?? "").isEmpty
        guard hasNameQuery || hasContentQuery else {
            throw SandboxFileToolError.missingSearchQuery
        }

        let resolvedLimit = min(max(1, maxResults), 200)
        let nameNeedle = hasNameQuery ? (trimmedNameQuery ?? "") : nil
        let contentNeedle = hasContentQuery ? (trimmedContentQuery ?? "") : nil
        let formatter = ISO8601DateFormatter()

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [SandboxFileSearchResult] = []

        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isCurrentDirectory = values.isDirectory ?? false
            if isCurrentDirectory && !includeDirectories {
                continue
            }

            let displayPath = normalizedDisplayPath(for: itemURL, rootDirectory: rootDirectory)
            let matchedByName = nameNeedle.map {
                contains(haystack: displayPath, needle: $0, caseSensitive: caseSensitive)
                || contains(haystack: itemURL.lastPathComponent, needle: $0, caseSensitive: caseSensitive)
            } ?? false
            let nameMatched = nameNeedle == nil || matchedByName

            var matchedByContent = false
            if let contentNeedle, !isCurrentDirectory {
                if let data = try? Data(contentsOf: itemURL),
                   let text = String(data: data, encoding: .utf8) {
                    matchedByContent = contains(haystack: text, needle: contentNeedle, caseSensitive: caseSensitive)
                }
            }
            let contentMatched = contentNeedle == nil || matchedByContent

            guard nameMatched && contentMatched else { continue }

            results.append(
                SandboxFileSearchResult(
                    path: displayPath,
                    name: itemURL.lastPathComponent,
                    isDirectory: isCurrentDirectory,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate.map(formatter.string(from:)),
                    matchedByName: matchedByName,
                    matchedByContent: matchedByContent
                )
            )
            if results.count >= resolvedLimit {
                break
            }
        }

        return results.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    public static func readTextFileChunk(
        relativePath: String,
        startLine: Int = 1,
        maxLines: Int = 200,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileChunkReadResult {
        guard startLine >= 1, maxLines >= 1 else {
            throw SandboxFileToolError.invalidChunkRange
        }
        let resolvedMaxLines = min(maxLines, 1000)
        let content = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        let lines = normalizedTextLines(content)
        let totalLines = lines.count
        let displayPath = normalizedDisplayPath(
            for: try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false),
            rootDirectory: rootDirectory
        )

        guard totalLines > 0 else {
            return SandboxFileChunkReadResult(
                path: displayPath,
                startLine: 1,
                endLine: 0,
                totalLines: 0,
                hasMore: false,
                content: ""
            )
        }
        guard startLine <= totalLines else {
            throw SandboxFileToolError.invalidChunkRange
        }

        let startIndex = startLine - 1
        let endExclusive = min(startIndex + resolvedMaxLines, totalLines)
        let selected = Array(lines[startIndex..<endExclusive])
        let endLine = startLine + selected.count - 1

        return SandboxFileChunkReadResult(
            path: displayPath,
            startLine: startLine,
            endLine: endLine,
            totalLines: totalLines,
            hasMore: endExclusive < totalLines,
            content: selected.joined(separator: "\n")
        )
    }

    public static func moveItem(
        from sourceRelativePath: String,
        to destinationRelativePath: String,
        overwrite: Bool = false,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileMoveResult {
        let sourceURL = try resolveURL(relativePath: sourceRelativePath, rootDirectory: rootDirectory, allowRoot: false)
        let destinationURL = try resolveURL(relativePath: destinationRelativePath, rootDirectory: rootDirectory, allowRoot: false)

        let sourceDisplayPath = normalizedDisplayPath(for: sourceURL, rootDirectory: rootDirectory)
        let destinationDisplayPath = normalizedDisplayPath(for: destinationURL, rootDirectory: rootDirectory)
        guard sourceURL.path != destinationURL.path else {
            throw SandboxFileToolError.sourceAndDestinationSame
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw SandboxFileToolError.fileNotFound(sourceDisplayPath)
        }

        if sourceIsDirectory.boolValue {
            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationURL.standardizedFileURL.path
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw SandboxFileToolError.cannotMoveIntoSelf
            }
        }

        let destinationParent = destinationURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &parentIsDirectory)
        var createdParentDirectories = false
        if parentExists {
            guard parentIsDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法移动。", comment: "Sandbox tool move parent not directory"),
                        normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            createdParentDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox tool move parent missing"),
                    normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                )
            )
        }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory)
        var overwrittenBackupURL: URL?
        if destinationExists {
            guard overwrite else {
                throw SandboxFileToolError.destinationAlreadyExists(destinationDisplayPath)
            }
            overwrittenBackupURL = try backupItem(at: destinationURL)
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        StorageUtility.notifyFilesystemMutation(at: sourceURL)
        StorageUtility.notifyFilesystemMutation(at: destinationURL)

        let backupURLForUndo = overwrittenBackupURL
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "move_sandbox_item",
            discard: {
                if let backupURLForUndo {
                    try? FileManager.default.removeItem(at: backupURLForUndo)
                }
            }
        ) {
            guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw SandboxFileToolError.destinationAlreadyExists(sourceDisplayPath)
            }
            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw SandboxFileToolError.fileNotFound(destinationDisplayPath)
            }

            try FileManager.default.moveItem(at: destinationURL, to: sourceURL)
            StorageUtility.notifyFilesystemMutation(at: destinationURL)
            StorageUtility.notifyFilesystemMutation(at: sourceURL)

            if let backupURLForUndo {
                try FileManager.default.copyItem(at: backupURLForUndo, to: destinationURL)
                try? FileManager.default.removeItem(at: backupURLForUndo)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
        }

        return SandboxFileMoveResult(
            sourcePath: sourceDisplayPath,
            destinationPath: destinationDisplayPath,
            wasDirectory: sourceIsDirectory.boolValue,
            createdParentDirectories: createdParentDirectories,
            overwroteDestination: destinationExists
        )
    }

    internal static func resolveURL(
        relativePath: String,
        rootDirectory: URL,
        allowRoot: Bool
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInput = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalizedInput.isEmpty {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        let strippedInput: String
        if normalizedInput == "Documents" {
            strippedInput = ""
        } else if normalizedInput.hasPrefix("Documents/") {
            strippedInput = String(normalizedInput.dropFirst("Documents/".count))
        } else {
            strippedInput = normalizedInput
        }

        let pathComponents = strippedInput
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !pathComponents.isEmpty else {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        guard !pathComponents.contains("..") else {
            throw SandboxFileToolError.escapedSandbox
        }

        let targetURL = pathComponents.reduce(rootDirectory) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = targetURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw SandboxFileToolError.escapedSandbox
        }

        return targetURL
    }

    internal static func normalizedDisplayPath(
        for url: URL,
        rootDirectory: URL
    ) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path

        if targetPath == rootPath {
            return "Documents"
        }

        let relative = String(targetPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "Documents" : "Documents/\(relative)"
    }

    private static func pushUndoEntry(
        rootDirectory: URL,
        operation: String,
        discard: @escaping () -> Void = {},
        undo: @escaping () throws -> Void
    ) {
        let entry = SandboxUndoEntry(
            rootPath: rootDirectory.standardizedFileURL.path,
            operation: operation,
            recordedAt: Date(),
            undo: undo,
            discard: discard
        )

        undoLock.lock()
        undoStack.append(entry)
        if undoStack.count > maxUndoEntries {
            let stale = undoStack.removeFirst()
            stale.discard()
        }
        undoLock.unlock()
    }

    private static func popUndoEntry(for rootPath: String) -> SandboxUndoEntry? {
        undoLock.lock()
        defer { undoLock.unlock() }
        guard let index = undoStack.lastIndex(where: { $0.rootPath == rootPath }) else {
            return nil
        }
        return undoStack.remove(at: index)
    }

    private static func restoreUndoEntry(_ entry: SandboxUndoEntry) {
        undoLock.lock()
        undoStack.append(entry)
        undoLock.unlock()
    }

    private static func backupItem(at url: URL) throws -> URL {
        let backupRoot = try backupRootDirectory()
        let backupURL = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    private static func backupRootDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS_LLM_Studio_SandboxToolBackups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func simpleUnifiedDiff(
        original: String,
        updated: String
    ) -> String {
        let originalLines = normalizeLines(original)
        let updatedLines = normalizeLines(updated)
        let difference = updatedLines.difference(from: originalLines)

        guard !difference.isEmpty else { return "" }

        let orderedChanges = difference.sorted { lhs, rhs in
            let lhsOffset: Int
            let rhsOffset: Int
            switch lhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                lhsOffset = offset
            }
            switch rhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                rhsOffset = offset
            }
            if lhsOffset == rhsOffset {
                switch (lhs, rhs) {
                case (.remove, .insert):
                    return true
                case (.insert, .remove):
                    return false
                default:
                    return true
                }
            }
            return lhsOffset < rhsOffset
        }

        var lines: [String] = ["--- current", "+++ proposed"]
        for change in orderedChanges {
            switch change {
            case .remove(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("-\(element)")
            case .insert(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("+\(element)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func normalizeLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func normalizedTextLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return normalizeLines(text)
    }

    private static func contains(
        haystack: String,
        needle: String,
        caseSensitive: Bool
    ) -> Bool {
        if caseSensitive {
            return haystack.range(of: needle) != nil
        }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}
