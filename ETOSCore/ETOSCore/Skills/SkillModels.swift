// ============================================================================
// SkillModels.swift
// ============================================================================
// Agent Skills 相关数据模型
// - 技能元信息
// - 技能文件索引
// - 导入结果与错误定义
// ============================================================================

import Foundation

public enum SkillExecutionPolicy: String, Codable, CaseIterable, Sendable {
    case deny
    case askEveryTime = "ask_every_time"
    case allowCurrentVersion = "allow_current_version"

    public var displayName: String {
        switch self {
        case .deny:
            return NSLocalizedString("拒绝执行", comment: "Skill execution deny policy")
        case .askEveryTime:
            return NSLocalizedString("每次询问", comment: "Skill execution ask every time policy")
        case .allowCurrentVersion:
            return NSLocalizedString("允许当前版本", comment: "Skill execution allow current version policy")
        }
    }
}

public struct SkillExecutionPolicyRecord: Codable, Equatable, Sendable {
    public let skillName: String
    public let policy: SkillExecutionPolicy
    public let approvedVersionDigest: String?
    public let updatedAt: Date

    public init(
        skillName: String,
        policy: SkillExecutionPolicy,
        approvedVersionDigest: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.skillName = skillName
        self.policy = policy
        self.approvedVersionDigest = approvedVersionDigest
        self.updatedAt = updatedAt
    }
}

public struct SkillExecutionPolicyStatus: Equatable, Sendable {
    public let record: SkillExecutionPolicyRecord
    public let currentVersionDigest: String?

    public init(record: SkillExecutionPolicyRecord, currentVersionDigest: String?) {
        self.record = record
        self.currentVersionDigest = currentVersionDigest
    }

    public var isCurrentVersionApproved: Bool {
        record.policy == .allowCurrentVersion
            && record.approvedVersionDigest != nil
            && record.approvedVersionDigest == currentVersionDigest
    }
}

public struct SkillScriptSnapshot: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let size: Int
    public let isExecutable: Bool

    public init(relativePath: String, sha256: String, size: Int, isExecutable: Bool) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.isExecutable = isExecutable
    }
}

public struct SkillRunSnapshot: Codable, Equatable, Sendable {
    public let skillID: String
    public let skillName: String
    public let versionDigest: String
    public let allowedTools: [String]
    public let scripts: [SkillScriptSnapshot]
    public let createdAt: Date

    public init(
        skillID: String,
        skillName: String,
        versionDigest: String,
        allowedTools: [String],
        scripts: [SkillScriptSnapshot],
        createdAt: Date = Date()
    ) {
        self.skillID = skillID
        self.skillName = skillName
        self.versionDigest = versionDigest
        self.allowedTools = allowedTools
        self.scripts = scripts
        self.createdAt = createdAt
    }
}

public struct SkillScriptApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let skillName: String
    public let versionDigest: String
    public let scriptPath: String
    public let scriptSHA256: String
    public let decision: String
    public let runID: UUID?
    public let toolCallID: String?
    public let approvedAt: Date

    public init(
        id: UUID = UUID(),
        skillName: String,
        versionDigest: String,
        scriptPath: String,
        scriptSHA256: String,
        decision: String,
        runID: UUID?,
        toolCallID: String?,
        approvedAt: Date = Date()
    ) {
        self.id = id
        self.skillName = skillName
        self.versionDigest = versionDigest
        self.scriptPath = scriptPath
        self.scriptSHA256 = scriptSHA256
        self.decision = decision
        self.runID = runID
        self.toolCallID = toolCallID
        self.approvedAt = approvedAt
    }
}

public enum SkillExecutionError: LocalizedError, Sendable {
    case agentContextRequired
    case skillNotFrozen
    case skillChanged
    case executionDenied
    case userDenied
    case userSupplementRequested
    case invalidScriptPath
    case scriptNotFound
    case unsupportedScript
    case missingInterpreter(command: String, recipeID: String?, recipeTitle: String?)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .agentContextRequired:
            return NSLocalizedString("Skill 脚本只能在已启用本地 Linux 的 Agent 模式中执行。", comment: "Skill script requires Agent context")
        case .skillNotFrozen:
            return NSLocalizedString("当前 Agent Run 没有冻结这个 Skill；请开始新的 Agent Run 后重试。", comment: "Skill missing from Agent run snapshot")
        case .skillChanged:
            return NSLocalizedString("Skill 已在本次 Agent Run 开始后发生变化；旧版本授权已失效，请开始新的 Agent Run。", comment: "Skill changed after run began")
        case .executionDenied:
            return NSLocalizedString("该 Skill 的脚本执行策略设为拒绝。", comment: "Skill execution policy denied")
        case .userDenied:
            return NSLocalizedString("用户拒绝执行 Skill 脚本。", comment: "Skill script permission denied")
        case .userSupplementRequested:
            return NSLocalizedString("用户希望先补充说明，Skill 脚本尚未执行。", comment: "Skill script permission awaits user supplement")
        case .invalidScriptPath:
            return NSLocalizedString("只能执行 Skill 的 scripts/ 目录内文件，且路径不能穿越目录或符号链接。", comment: "Invalid Skill script path")
        case .scriptNotFound:
            return NSLocalizedString("Skill 脚本不存在，或未包含在 Agent Run 的冻结快照中。", comment: "Skill script missing")
        case .unsupportedScript:
            return NSLocalizedString("不支持这种脚本格式；请使用有效 shebang、.sh、.py、.js/.mjs 或可执行的 AArch64 Linux 二进制文件。", comment: "Unsupported Skill script format")
        case .missingInterpreter(let command, let recipeID, let recipeTitle):
            if let recipeID, let recipeTitle {
                return String(
                    format: NSLocalizedString("本地 Linux 缺少解释器“%@”。可由用户运行环境配方“%@”（%@）安装；App 不会自动安装。", comment: "Skill interpreter missing with recipe"),
                    command,
                    recipeTitle,
                    recipeID
                )
            }
            return String(
                format: NSLocalizedString("本地 Linux 缺少解释器“%@”；App 不会自动安装。", comment: "Skill interpreter missing"),
                command
            )
        case .invalidArguments(let reason):
            return reason
        }
    }
}

public enum SkillAllowedToolPolicy {
    /// `allowed-tools` 只能收窄当前会话已经暴露的工具，绝不能借 Skill 扩权。
    public static func effectiveTools(declared: [String], sessionEnabled: Set<String>) -> Set<String> {
        guard !declared.isEmpty else { return sessionEnabled }
        return Set(declared).intersection(sessionEnabled)
    }
}

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
