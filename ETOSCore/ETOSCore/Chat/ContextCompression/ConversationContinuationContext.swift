// ============================================================================
// ConversationContinuationContext.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义上下文压缩与续聊会话使用的稳定领域模型。
// ============================================================================

import Foundation

/// 新会话持有的续聊上下文，不作为普通聊天消息保存。
public struct ConversationContinuationContext: Identifiable, Codable, Hashable, Sendable {
    public static let currentPromptVersion = 1

    public let id: UUID
    public let childSessionID: UUID
    public let sourceSessionID: UUID
    public let sourceSessionNameSnapshot: String
    public let sourceThroughMessageID: UUID
    public let createdAt: Date
    public var summary: String
    public let retainedMessages: [ChatMessage]
    public let retainedRoundCount: Int
    public let compressionModelIdentifier: String
    public let promptVersion: Int
    public let sourceMessageCount: Int
    public let summarizedMessageCount: Int
    public let estimatedSourceTokens: Int?
    public let estimatedResultTokens: Int?

    public init(
        id: UUID = UUID(),
        childSessionID: UUID,
        sourceSessionID: UUID,
        sourceSessionNameSnapshot: String,
        sourceThroughMessageID: UUID,
        createdAt: Date = Date(),
        summary: String,
        retainedMessages: [ChatMessage],
        retainedRoundCount: Int,
        compressionModelIdentifier: String,
        promptVersion: Int = ConversationContinuationContext.currentPromptVersion,
        sourceMessageCount: Int,
        summarizedMessageCount: Int,
        estimatedSourceTokens: Int? = nil,
        estimatedResultTokens: Int? = nil
    ) {
        self.id = id
        self.childSessionID = childSessionID
        self.sourceSessionID = sourceSessionID
        self.sourceSessionNameSnapshot = sourceSessionNameSnapshot
        self.sourceThroughMessageID = sourceThroughMessageID
        self.createdAt = createdAt
        self.summary = summary
        self.retainedMessages = retainedMessages
        self.retainedRoundCount = max(0, retainedRoundCount)
        self.compressionModelIdentifier = compressionModelIdentifier
        self.promptVersion = promptVersion
        self.sourceMessageCount = max(0, sourceMessageCount)
        self.summarizedMessageCount = max(0, summarizedMessageCount)
        self.estimatedSourceTokens = estimatedSourceTokens
        self.estimatedResultTokens = estimatedResultTokens
    }
}

public struct ContextCompressionOptions: Codable, Hashable, Sendable {
    public static let defaultRetainedRoundCount = 6

    public var retainedRoundCount: Int
    public var focusInstruction: String?
    public var compressionModelIdentifier: String?

    public init(
        retainedRoundCount: Int = ContextCompressionOptions.defaultRetainedRoundCount,
        focusInstruction: String? = nil,
        compressionModelIdentifier: String? = nil
    ) {
        self.retainedRoundCount = max(0, retainedRoundCount)
        self.focusInstruction = focusInstruction
        self.compressionModelIdentifier = compressionModelIdentifier
    }
}

public struct ContextCompressionProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preparing
        case summarizing(completed: Int, total: Int)
        case synthesizing(level: Int)
        case saving
    }

    public let phase: Phase

    public init(phase: Phase) {
        self.phase = phase
    }
}

public enum ContextCompressionAttachmentKind: String, Codable, Hashable, Sendable {
    case audio
    case image
    case file
}

/// 附件经过转写、OCR 或文本提取后参与压缩的完整语义内容。
public struct ContextCompressionAttachmentContent: Codable, Hashable, Sendable {
    public let identifier: String
    public let kind: ContextCompressionAttachmentKind
    public let content: String

    public init(identifier: String, kind: ContextCompressionAttachmentKind, content: String) {
        self.identifier = identifier
        self.kind = kind
        self.content = content
    }
}

public enum ContextCompressionError: LocalizedError, Equatable {
    case noCompressibleMessages
    case invalidInputBudget(Int)
    case unsupportedAttachments(messageID: UUID, identifiers: [String])
    case minimalTextUnitExceedsBudget(messageID: UUID, estimatedTokens: Int, budget: Int)
    case incompleteCoverage(messageID: UUID)
    case emptySummary
    case sourceSessionNotFound
    case compressionModelNotFound
    case unableToReduceSummaries

    public var errorDescription: String? {
        switch self {
        case .noCompressibleMessages:
            return NSLocalizedString("当前会话没有可以压缩的对话内容。", comment: "Context compression empty conversation error")
        case .invalidInputBudget(let budget):
            return String(
                format: NSLocalizedString("上下文压缩的单次输入预算无效：%d。", comment: "Context compression invalid input budget error"),
                budget
            )
        case .unsupportedAttachments(_, let identifiers):
            return String(
                format: NSLocalizedString("以下附件尚未获得完整的可读内容，无法在不遗漏信息的情况下压缩：%@", comment: "Context compression unsupported attachments error"),
                identifiers.joined(separator: ", ")
            )
        case .minimalTextUnitExceedsBudget(_, let estimatedTokens, let budget):
            return String(
                format: NSLocalizedString("单个 Unicode 字素的预估大小（%d）超过压缩输入预算（%d），无法安全分片。", comment: "Context compression grapheme exceeds budget error"),
                estimatedTokens,
                budget
            )
        case .incompleteCoverage:
            return NSLocalizedString("压缩分块没有完整覆盖源对话，已停止创建续聊会话。", comment: "Context compression incomplete coverage error")
        case .emptySummary:
            return NSLocalizedString("模型返回了空的续聊摘要，未创建新会话。", comment: "Context compression empty summary error")
        case .sourceSessionNotFound:
            return NSLocalizedString("找不到要压缩的原会话。", comment: "Context compression source session missing error")
        case .compressionModelNotFound:
            return NSLocalizedString("找不到可用于上下文压缩的聊天模型。", comment: "Context compression model missing error")
        case .unableToReduceSummaries:
            return NSLocalizedString("模型多次归并后仍无法形成单一续聊摘要，未创建新会话。", comment: "Context compression synthesis reduction error")
        }
    }
}
