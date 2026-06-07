// ============================================================================
// ChatModelsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 ChatModels.swift 中的消息版本、响应尝试、请求日志与会话模型辅助逻辑。
// ============================================================================

import Foundation

public struct ChatResponseAttemptVersionInfo: Equatable, Sendable {
    public let responseGroupID: UUID
    public let currentAttemptID: UUID
    public let currentIndex: Int
    public let totalCount: Int
}

public struct MessageRewriteReferenceVersion: Identifiable, Equatable, Hashable, Sendable {
    public let versionNumber: Int
    public let content: String

    public var id: Int { versionNumber }

    public init(versionNumber: Int, content: String) {
        self.versionNumber = versionNumber
        self.content = content
    }
}

public enum ChatQuickRetrySupport {
    public static func canRetryLatestMessage(in messages: [ChatMessage], isSending: Bool) -> Bool {
        guard !isSending else { return false }
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        guard visibleMessages.contains(where: { $0.role == .user }),
              let latestMessage = visibleMessages.last else {
            return false
        }

        switch latestMessage.role {
        case .error:
            return true
        case .assistant:
            return isAbnormalStoppedAssistantMessage(latestMessage)
        case .user:
            return true
        case .system, .tool:
            return false
        }
    }

    public static func isAbnormalStoppedAssistantMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !hasVisibleAssistantBodyContent(message) else { return false }
        guard !hasAssistantMediaContent(message) else { return false }

        let hasReasoning = !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasReasoning {
            return true
        }

        let hasToolCalls = !(message.toolCalls ?? []).isEmpty
        return !hasToolCalls
    }

    private static func hasVisibleAssistantBodyContent(_ message: ChatMessage) -> Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        switch trimmedContent {
        case "[图片]", "[圖片]", "[Image]", "[画像]":
            return false
        default:
            return true
        }
    }

    private static func hasAssistantMediaContent(_ message: ChatMessage) -> Bool {
        message.audioFileName != nil
            || !(message.imageFileNames ?? []).isEmpty
            || !(message.fileFileNames ?? []).isEmpty
    }
}

public enum ChatResponseAttemptSupport {
    public static func shouldMergeAdjacentAssistantTurnMessages(_ message: ChatMessage, _ nextMessage: ChatMessage) -> Bool {
        guard isAssistantTurnMessage(message),
              isAssistantTurnMessage(nextMessage) else {
            return false
        }

        let messageHasAttempt = message.responseGroupID != nil || message.responseAttemptID != nil
        let nextMessageHasAttempt = nextMessage.responseGroupID != nil || nextMessage.responseAttemptID != nil
        guard messageHasAttempt || nextMessageHasAttempt else {
            return true
        }

        guard let messageGroupID = message.responseGroupID,
              let messageAttemptID = message.responseAttemptID,
              let nextMessageGroupID = nextMessage.responseGroupID,
              let nextMessageAttemptID = nextMessage.responseAttemptID else {
            return false
        }

        return messageGroupID == nextMessageGroupID && messageAttemptID == nextMessageAttemptID
    }

    public static func visibleMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        let selectedByGroup = selectedAttemptIDsByGroup(in: messages)
        return messages.filter { message in
            guard let groupID = message.responseGroupID,
                  let attemptID = message.responseAttemptID,
                  let selectedAttemptID = selectedByGroup[groupID] else {
                return true
            }
            return attemptID == selectedAttemptID
        }
    }

    public static func versionInfo(for message: ChatMessage, in messages: [ChatMessage]) -> ChatResponseAttemptVersionInfo? {
        guard canCarryResponseAttemptVersionInfo(message),
              let groupID = message.responseGroupID,
              let attemptID = message.responseAttemptID else {
            return nil
        }

        let attempts = orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.count > 1,
              let currentIndex = attempts.firstIndex(of: attemptID) else {
            return nil
        }

        if let selectedAttemptID = selectedAttemptIDsByGroup(in: messages)[groupID],
           selectedAttemptID != attemptID {
            return nil
        }

        let visibleAttemptMessages = messages.filter {
            $0.responseGroupID == groupID && $0.responseAttemptID == attemptID
        }
        let lastCarrierID = visibleAttemptMessages.last(where: canCarryResponseAttemptVersionInfo)?.id
        guard lastCarrierID == message.id else { return nil }

        return ChatResponseAttemptVersionInfo(
            responseGroupID: groupID,
            currentAttemptID: attemptID,
            currentIndex: currentIndex,
            totalCount: attempts.count
        )
    }

    public static func selectPreviousAttempt(for message: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage]? {
        guard let info = versionInfo(for: message, in: messages), info.currentIndex > 0 else { return nil }
        return selectAttempt(attemptID: orderedAttemptIDs(for: info.responseGroupID, in: messages)[info.currentIndex - 1], groupID: info.responseGroupID, in: messages)
    }

    public static func selectNextAttempt(for message: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage]? {
        guard let info = versionInfo(for: message, in: messages), info.currentIndex + 1 < info.totalCount else { return nil }
        return selectAttempt(attemptID: orderedAttemptIDs(for: info.responseGroupID, in: messages)[info.currentIndex + 1], groupID: info.responseGroupID, in: messages)
    }

    public static func selectAttempt(attemptID: UUID, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            let shouldStoreSelection = (message.id == groupID && message.role == .user)
                || message.responseGroupID == groupID
            guard shouldStoreSelection else { return message }
            var updated = message
            updated.selectedResponseAttemptID = attemptID
            return updated
        }
    }

    public static func deleteAttempt(at index: Int, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage]? {
        let attempts = orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.indices.contains(index) else { return nil }

        let targetAttemptID = attempts[index]
        let selectedAttemptID = selectedAttemptID(for: groupID, in: messages)
        let remainingAttempts = attempts.filter { $0 != targetAttemptID }
        var updatedMessages = messages.filter {
            !($0.responseGroupID == groupID && $0.responseAttemptID == targetAttemptID)
        }

        guard selectedAttemptID == targetAttemptID else {
            return updatedMessages
        }

        let replacementIndex = max(0, min(index, remainingAttempts.count - 1))
        if remainingAttempts.indices.contains(replacementIndex) {
            return selectAttempt(
                attemptID: remainingAttempts[replacementIndex],
                groupID: groupID,
                in: updatedMessages
            )
        }

        if let anchorIndex = updatedMessages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            updatedMessages[anchorIndex].selectedResponseAttemptID = nil
        }
        return updatedMessages
    }

    public static func orderedAttemptIDs(for groupID: UUID, in messages: [ChatMessage]) -> [UUID] {
        var orderByID: [UUID: AttemptOrder] = [:]
        for (position, message) in messages.enumerated() {
            guard message.responseGroupID == groupID,
                  let attemptID = message.responseAttemptID else {
                continue
            }
            recordAttemptOrder(
                attemptID: attemptID,
                explicitIndex: message.responseAttemptIndex,
                position: position,
                in: &orderByID
            )
        }

        return orderedAttemptIDs(from: orderByID)
    }

    private struct AttemptOrder {
        let id: UUID
        let explicitIndex: Int
        let firstPosition: Int
    }

    private static func recordAttemptOrder(
        attemptID: UUID,
        explicitIndex: Int?,
        position: Int,
        in orderByID: inout [UUID: AttemptOrder]
    ) {
        let normalizedIndex = explicitIndex ?? Int.max
        if let existing = orderByID[attemptID] {
            orderByID[attemptID] = AttemptOrder(
                id: attemptID,
                explicitIndex: min(existing.explicitIndex, normalizedIndex),
                firstPosition: min(existing.firstPosition, position)
            )
        } else {
            orderByID[attemptID] = AttemptOrder(
                id: attemptID,
                explicitIndex: normalizedIndex,
                firstPosition: position
            )
        }
    }

    private static func orderedAttemptIDs(from orderByID: [UUID: AttemptOrder]) -> [UUID] {
        return orderByID.values
            .sorted {
                if $0.explicitIndex != $1.explicitIndex {
                    return $0.explicitIndex < $1.explicitIndex
                }
                return $0.firstPosition < $1.firstPosition
            }
            .map(\.id)
    }

    public static func selectedAttemptID(for groupID: UUID, in messages: [ChatMessage]) -> UUID? {
        selectedAttemptIDsByGroup(in: messages)[groupID]
    }

    private static func selectedAttemptIDsByGroup(in messages: [ChatMessage]) -> [UUID: UUID] {
        var anchorSelectionByGroup: [UUID: UUID] = [:]
        var storedSelectionByGroup: [UUID: UUID] = [:]
        var orderByGroup: [UUID: [UUID: AttemptOrder]] = [:]

        for (position, message) in messages.enumerated() {
            if message.role == .user,
               let selectedAttemptID = message.selectedResponseAttemptID {
                anchorSelectionByGroup[message.id] = selectedAttemptID
            }

            guard let groupID = message.responseGroupID else { continue }
            if (message.role == .assistant || message.role == .error),
               let selectedAttemptID = message.selectedResponseAttemptID {
                storedSelectionByGroup[groupID] = selectedAttemptID
            }

            guard let attemptID = message.responseAttemptID else { continue }
            var orderByID = orderByGroup[groupID, default: [:]]
            recordAttemptOrder(
                attemptID: attemptID,
                explicitIndex: message.responseAttemptIndex,
                position: position,
                in: &orderByID
            )
            orderByGroup[groupID] = orderByID
        }

        var selectedByGroup = anchorSelectionByGroup
        for (groupID, selectedAttemptID) in storedSelectionByGroup {
            selectedByGroup[groupID] = selectedAttemptID
        }

        for (groupID, orderByID) in orderByGroup {
            let attempts = orderedAttemptIDs(from: orderByID)
            guard let fallbackAttemptID = attempts.last else { continue }
            if let selectedAttemptID = selectedByGroup[groupID],
               attempts.contains(selectedAttemptID) {
                continue
            }
            selectedByGroup[groupID] = fallbackAttemptID
        }
        return selectedByGroup
    }

    private static func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        }
    }

    private static func canCarryResponseAttemptVersionInfo(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system, .error:
            return true
        case .user:
            return false
        }
    }
}

public enum MessageRewriteReferenceSupport {
    public static func referenceVersions(
        for message: ChatMessage,
        in messages: [ChatMessage]
    ) -> [MessageRewriteReferenceVersion] {
        if let responseAttemptReferences = responseAttemptReferenceVersions(for: message, in: messages) {
            return responseAttemptReferences
        }
        return legacyReferenceVersions(for: message)
    }

    private static func responseAttemptReferenceVersions(
        for message: ChatMessage,
        in messages: [ChatMessage]
    ) -> [MessageRewriteReferenceVersion]? {
        guard let groupID = message.responseGroupID,
              let currentAttemptID = message.responseAttemptID else {
            return nil
        }

        let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.count > 1, attempts.contains(currentAttemptID) else { return nil }

        return attempts.enumerated().compactMap { index, attemptID in
            guard attemptID != currentAttemptID,
                  let content = representativeContent(
                    forAttemptID: attemptID,
                    groupID: groupID,
                    in: messages
                  ) else {
                return nil
            }
            return MessageRewriteReferenceVersion(versionNumber: index + 1, content: content)
        }
    }

    private static func representativeContent(
        forAttemptID attemptID: UUID,
        groupID: UUID,
        in messages: [ChatMessage]
    ) -> String? {
        messages
            .reversed()
            .first {
                $0.responseGroupID == groupID
                    && $0.responseAttemptID == attemptID
                    && ($0.role == .assistant || $0.role == .error)
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?
            .content
    }

    private static func legacyReferenceVersions(for message: ChatMessage) -> [MessageRewriteReferenceVersion] {
        let currentIndex = message.getCurrentVersionIndex()
        return message.getAllVersions().enumerated().compactMap { index, content in
            guard index != currentIndex,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return MessageRewriteReferenceVersion(versionNumber: index + 1, content: content)
        }
    }
}

public enum RequestLogStatus: String, Codable, Hashable, Sendable {
    case success
    case failed
    case cancelled
}

public struct RequestLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var requestID: UUID
    public var sessionID: UUID?
    public var providerID: UUID?
    public var providerName: String
    public var modelID: String
    public var requestedAt: Date
    public var finishedAt: Date
    public var isStreaming: Bool
    public var status: RequestLogStatus
    public var tokenUsage: MessageTokenUsage?

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        sessionID: UUID?,
        providerID: UUID?,
        providerName: String,
        modelID: String,
        requestedAt: Date,
        finishedAt: Date,
        isStreaming: Bool,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.requestedAt = requestedAt
        self.finishedAt = finishedAt
        self.isStreaming = isStreaming
        self.status = status
        self.tokenUsage = tokenUsage
    }
}

public struct RequestLogQuery: Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var providerID: UUID?
    public var modelID: String?
    public var statuses: Set<RequestLogStatus>?
    public var limit: Int?

    public init(
        from: Date? = nil,
        to: Date? = nil,
        providerID: UUID? = nil,
        modelID: String? = nil,
        statuses: Set<RequestLogStatus>? = nil,
        limit: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.providerID = providerID
        self.modelID = modelID
        self.statuses = statuses
        self.limit = limit
    }
}

public struct RequestLogTokenTotals: Codable, Hashable, Sendable {
    public var sentTokens: Int
    public var receivedTokens: Int
    public var thinkingTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int

    public init(
        sentTokens: Int = 0,
        receivedTokens: Int = 0,
        thinkingTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }
}

public struct RequestLogSummaryBucket: Codable, Hashable, Sendable {
    public var key: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals

    public init(
        key: String,
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init()
    ) {
        self.key = key
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
    }
}

public struct RequestLogSummary: Codable, Hashable, Sendable {
    public var totalRequests: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var byProvider: [RequestLogSummaryBucket]
    public var byModel: [RequestLogSummaryBucket]

    public init(
        totalRequests: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init(),
        byProvider: [RequestLogSummaryBucket] = [],
        byModel: [RequestLogSummaryBucket] = []
    ) {
        self.totalRequests = totalRequests
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
        self.byProvider = byProvider
        self.byModel = byModel
    }
}

public struct ChatSession: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var topicPrompt: String?
    public var enhancedPrompt: String?
    /// 会话所属文件夹，nil 表示未分类。
    public var folderID: UUID?
    public var lorebookIDs: [UUID]
    /// 绑定到当前会话的标签 ID，标签实体由 SessionTag 单独维护。
    public var tagIDs: [UUID]
    /// 开启后，仅在当前会话已绑定世界书时生效，发送时会屏蔽记忆与工具上下文。
    public var worldbookContextIsolationEnabled: Bool
    @available(*, deprecated, message: "请改用 lorebookIDs；worldbookIDs 为兼容旧代码保留。")
    public var worldbookIDs: [UUID] {
        get { lorebookIDs }
        set { lorebookIDs = newValue }
    }
    public var isTemporary: Bool = false

    /// 仅当会话已绑定世界书且用户开启隔离时，才真正启用 RP 隔离发送。
    public var isWorldbookContextIsolationActive: Bool {
        worldbookContextIsolationEnabled && !lorebookIDs.isEmpty
    }

    public init(
        id: UUID,
        name: String,
        topicPrompt: String? = nil,
        enhancedPrompt: String? = nil,
        worldbookIDs: [UUID] = [],
        lorebookIDs: [UUID]? = nil,
        tagIDs: [UUID] = [],
        worldbookContextIsolationEnabled: Bool = false,
        folderID: UUID? = nil,
        isTemporary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
        self.folderID = folderID
        self.lorebookIDs = lorebookIDs ?? worldbookIDs
        self.tagIDs = tagIDs
        self.worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
        self.isTemporary = isTemporary
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case topicPrompt
        case enhancedPrompt
        case folderID
        case worldbookIDs
        case lorebookIDs
        case lorebookIds
        case tagIDs
        case tagIds
        case worldbookContextIsolationEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.topicPrompt = try container.decodeIfPresent(String.self, forKey: .topicPrompt)
        self.enhancedPrompt = try container.decodeIfPresent(String.self, forKey: .enhancedPrompt)
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        if let ids = try container.decodeIfPresent([UUID].self, forKey: .lorebookIDs) {
            self.lorebookIDs = ids
        } else if let ids = try container.decodeIfPresent([UUID].self, forKey: .lorebookIds) {
            self.lorebookIDs = ids
        } else if let ids = try container.decodeIfPresent([UUID].self, forKey: .worldbookIDs) {
            self.lorebookIDs = ids
        } else {
            self.lorebookIDs = []
        }
        if let ids = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) {
            self.tagIDs = ids
        } else if let ids = try container.decodeIfPresent([UUID].self, forKey: .tagIds) {
            self.tagIDs = ids
        } else {
            self.tagIDs = []
        }
        self.worldbookContextIsolationEnabled = try container.decodeIfPresent(Bool.self, forKey: .worldbookContextIsolationEnabled) ?? false
        self.isTemporary = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(topicPrompt, forKey: .topicPrompt)
        try container.encodeIfPresent(enhancedPrompt, forKey: .enhancedPrompt)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        if !lorebookIDs.isEmpty {
            try container.encode(lorebookIDs, forKey: .lorebookIDs)
            // 兼容旧版本持久化字段，避免多端混用时丢失绑定。
            try container.encode(lorebookIDs, forKey: .worldbookIDs)
        }
        if !tagIDs.isEmpty {
            try container.encode(tagIDs, forKey: .tagIDs)
        }
        if worldbookContextIsolationEnabled {
            try container.encode(worldbookContextIsolationEnabled, forKey: .worldbookContextIsolationEnabled)
        }
    }
}

public struct SessionFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// 父文件夹 ID，nil 表示根目录。
    public var parentID: UUID?
    /// 用于记录文件夹元数据最近更新时间。
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.updatedAt = updatedAt
    }
}
