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

    public var id: String { relativePath }

    public init(relativePath: String, size: Int64, modificationDate: Date? = nil) {
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
    }
}

public struct SkillImportResult: Sendable {
    public var skillName: String
    public var files: [String: String]

    public init(skillName: String, files: [String: String]) {
        self.skillName = skillName
        self.files = files
    }
}

public enum SkillStoreError: LocalizedError {
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
            return "技能名称不合法。"
        case .invalidSkillContent:
            return "技能内容格式不合法，缺少可解析的 name/description。"
        case .missingSkillFile:
            return "缺少 SKILL.md 文件。"
        case .invalidPath:
            return "文件路径不合法。"
        case .fileNotFound:
            return "目标文件不存在。"
        case .networkError(let reason):
            return "网络请求失败：\(reason)"
        case .saveFailed(let reason):
            return "保存失败：\(reason)"
        }
    }
}
