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
    public static let currentPromptVersion = 2

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
    /// 是否隐藏续聊会话中指向原会话的独立跳转气泡。
    public var isSourceSessionLinkHidden: Bool
    /// 是否隐藏原会话中指向续聊会话的独立跳转气泡。
    public var isContinuationSessionLinkHidden: Bool

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
        estimatedResultTokens: Int? = nil,
        isSourceSessionLinkHidden: Bool = false,
        isContinuationSessionLinkHidden: Bool = false
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
        self.isSourceSessionLinkHidden = isSourceSessionLinkHidden
        self.isContinuationSessionLinkHidden = isContinuationSessionLinkHidden
    }

    public func hidingLink(_ kind: ConversationContinuationLinkKind) -> Self {
        var context = self
        switch kind {
        case .sourceSession:
            context.isSourceSessionLinkHidden = true
        case .continuationSession:
            context.isContinuationSessionLinkHidden = true
        }
        return context
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case childSessionID
        case sourceSessionID
        case sourceSessionNameSnapshot
        case sourceThroughMessageID
        case createdAt
        case summary
        case retainedMessages
        case retainedRoundCount
        case compressionModelIdentifier
        case promptVersion
        case sourceMessageCount
        case summarizedMessageCount
        case estimatedSourceTokens
        case estimatedResultTokens
        case isSourceSessionLinkHidden
        case isContinuationSessionLinkHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        childSessionID = try container.decode(UUID.self, forKey: .childSessionID)
        sourceSessionID = try container.decode(UUID.self, forKey: .sourceSessionID)
        sourceSessionNameSnapshot = try container.decode(String.self, forKey: .sourceSessionNameSnapshot)
        sourceThroughMessageID = try container.decode(UUID.self, forKey: .sourceThroughMessageID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        summary = try container.decode(String.self, forKey: .summary)
        retainedMessages = try container.decode([ChatMessage].self, forKey: .retainedMessages)
        retainedRoundCount = max(0, try container.decode(Int.self, forKey: .retainedRoundCount))
        compressionModelIdentifier = try container.decode(String.self, forKey: .compressionModelIdentifier)
        promptVersion = try container.decode(Int.self, forKey: .promptVersion)
        sourceMessageCount = max(0, try container.decode(Int.self, forKey: .sourceMessageCount))
        summarizedMessageCount = max(0, try container.decode(Int.self, forKey: .summarizedMessageCount))
        estimatedSourceTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedSourceTokens)
        estimatedResultTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedResultTokens)
        isSourceSessionLinkHidden = try container.decodeIfPresent(
            Bool.self,
            forKey: .isSourceSessionLinkHidden
        ) ?? false
        isContinuationSessionLinkHidden = try container.decodeIfPresent(
            Bool.self,
            forKey: .isContinuationSessionLinkHidden
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(childSessionID, forKey: .childSessionID)
        try container.encode(sourceSessionID, forKey: .sourceSessionID)
        try container.encode(sourceSessionNameSnapshot, forKey: .sourceSessionNameSnapshot)
        try container.encode(sourceThroughMessageID, forKey: .sourceThroughMessageID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(summary, forKey: .summary)
        try container.encode(retainedMessages, forKey: .retainedMessages)
        try container.encode(retainedRoundCount, forKey: .retainedRoundCount)
        try container.encode(compressionModelIdentifier, forKey: .compressionModelIdentifier)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(sourceMessageCount, forKey: .sourceMessageCount)
        try container.encode(summarizedMessageCount, forKey: .summarizedMessageCount)
        try container.encodeIfPresent(estimatedSourceTokens, forKey: .estimatedSourceTokens)
        try container.encodeIfPresent(estimatedResultTokens, forKey: .estimatedResultTokens)
        try container.encode(isSourceSessionLinkHidden, forKey: .isSourceSessionLinkHidden)
        try container.encode(isContinuationSessionLinkHidden, forKey: .isContinuationSessionLinkHidden)
    }
}

public enum ConversationContinuationLinkKind: String, Codable, Hashable, Sendable {
    case sourceSession
    case continuationSession
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
        case summarizing
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
    case unsupportedAttachments(messageID: UUID, identifiers: [String])
    case emptySummary
    case sourceSessionNotFound
    case compressionModelNotFound

    public var errorDescription: String? {
        switch self {
        case .noCompressibleMessages:
            return NSLocalizedString("当前会话没有可以压缩的对话内容。", comment: "Context compression empty conversation error")
        case .unsupportedAttachments(_, let identifiers):
            return String(
                format: NSLocalizedString("以下附件尚未获得完整的可读内容，无法在不遗漏信息的情况下压缩：%@", comment: "Context compression unsupported attachments error"),
                identifiers.joined(separator: ", ")
            )
        case .emptySummary:
            return NSLocalizedString("模型返回了空的续聊摘要，未创建新会话。", comment: "Context compression empty summary error")
        case .sourceSessionNotFound:
            return NSLocalizedString("找不到要压缩的原会话。", comment: "Context compression source session missing error")
        case .compressionModelNotFound:
            return NSLocalizedString("找不到可用于上下文压缩的聊天模型。", comment: "Context compression model missing error")
        }
    }
}
