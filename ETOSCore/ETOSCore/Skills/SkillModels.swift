// ============================================================================
// SkillModels.swift
// ============================================================================
// Agent Skills 相关数据模型
// - 技能元信息
// - 技能文件索引
// - 导入结果与错误定义
// ============================================================================

import Foundation

public struct SkillMetadata: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var description: String
    public var compatibility: String?
    public var allowedTools: [String]
    public var updatedAt: Date

    public var id: String { name }

    public init(
        name: String,
        description: String,
        compatibility: String? = nil,
        allowedTools: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.description = description
        self.compatibility = compatibility
        self.allowedTools = allowedTools
        self.updatedAt = updatedAt
    }
}

public struct SkillFileReference: Hashable, Identifiable, Sendable {
    public var relativePath: String
    public var size: Int64
    public var modificationDate: Date?
    public var isReadableText: Bool
    public var readOnlyReason: String?

    public var id: String { relativePath }

    public init(
        relativePath: String,
        size: Int64,
        modificationDate: Date? = nil,
        isReadableText: Bool = true,
        readOnlyReason: String? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
        self.isReadableText = isReadableText
        self.readOnlyReason = readOnlyReason
    }
}

public struct SkillImportResult: Sendable {
    public var skillName: String
    public var files: [String: Data]

    public init(skillName: String, files: [String: Data]) {
        self.skillName = skillName
        self.files = files
    }
}

public struct SkillTextResourceChunk: Sendable {
    public var relativePath: String
    public var startLine: Int
    public var endLine: Int
    public var totalLines: Int
    public var hasMore: Bool
    public var content: String

    public init(
        relativePath: String,
        startLine: Int,
        endLine: Int,
        totalLines: Int,
        hasMore: Bool,
        content: String
    ) {
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.totalLines = totalLines
        self.hasMore = hasMore
        self.content = content
    }
}

public enum SkillStoreError: LocalizedError, Sendable {
    case invalidSkillName
    case invalidSkillContent
    case missingSkillFile
    case invalidPath
    case fileNotFound
    case networkError(String)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkillName:
            return NSLocalizedString("技能名称不合法。", comment: "Invalid skill name")
        case .invalidSkillContent:
            return NSLocalizedString("技能内容格式不合法，缺少可解析的技能名称。", comment: "Invalid skill content")
        case .missingSkillFile:
            return NSLocalizedString("缺少 SKILL.md 文件。", comment: "Missing SKILL.md")
        case .invalidPath:
            return NSLocalizedString("文件路径不合法。", comment: "Invalid skill file path")
        case .fileNotFound:
            return NSLocalizedString("目标文件不存在。", comment: "Skill file not found")
        case .networkError(let reason):
            return String(
                format: NSLocalizedString("网络请求失败：%@", comment: "Skill network request failure"),
                reason
            )
        case .saveFailed(let reason):
            return String(
                format: NSLocalizedString("保存失败：%@", comment: "Skill save failure"),
                reason
            )
        }
    }
}
