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

