// ============================================================================
// ChatModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义聊天消息、响应尝试、请求日志、会话与会话文件夹模型。
// ============================================================================

import Foundation

// MARK: - 核心消息与会话模型 (已重构)

/// 聊天消息的角色，使用枚举确保类型安全
public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
    case error
}

/// 工具调用展示顺序（相对于正文）
public enum ToolCallsPlacement: String, Codable, Sendable {
    case afterReasoning
    case afterContent
}

/// 单次 API 请求的响应测速信息
public struct MessageResponseMetrics: Codable, Hashable, Sendable {
    /// 流式速度采样点（按秒记录 token/s）。
    public struct SpeedSample: Codable, Hashable, Sendable {
        public var elapsedSecond: Int
        public var tokenPerSecond: Double

        public init(elapsedSecond: Int, tokenPerSecond: Double) {
            self.elapsedSecond = max(0, elapsedSecond)
            self.tokenPerSecond = max(0, tokenPerSecond)
        }
    }

    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var requestStartedAt: Date?
    public var responseCompletedAt: Date?
    public var totalResponseDuration: TimeInterval?
    public var timeToFirstToken: TimeInterval?
    public var reasoningStartedAt: Date?
    public var reasoningCompletedAt: Date?
    public var completionTokensForSpeed: Int?
    public var tokenPerSecond: Double?
    public var isTokenPerSecondEstimated: Bool
    public var reasoningSummary: String?
    public var speedSamples: [SpeedSample]?

    public var reasoningDuration: TimeInterval? {
        guard let reasoningStartedAt else { return nil }
        let completedAt = reasoningCompletedAt ?? responseCompletedAt
        guard let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(reasoningStartedAt))
    }

    public init(
        schemaVersion: Int = MessageResponseMetrics.currentSchemaVersion,
        requestStartedAt: Date? = nil,
        responseCompletedAt: Date? = nil,
        totalResponseDuration: TimeInterval? = nil,
        timeToFirstToken: TimeInterval? = nil,
        reasoningStartedAt: Date? = nil,
        reasoningCompletedAt: Date? = nil,
        completionTokensForSpeed: Int? = nil,
        tokenPerSecond: Double? = nil,
        isTokenPerSecondEstimated: Bool = false,
        reasoningSummary: String? = nil,
        speedSamples: [SpeedSample]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestStartedAt = requestStartedAt
        self.responseCompletedAt = responseCompletedAt
        self.totalResponseDuration = totalResponseDuration
        self.timeToFirstToken = timeToFirstToken
        self.reasoningStartedAt = reasoningStartedAt
        self.reasoningCompletedAt = reasoningCompletedAt
        self.completionTokensForSpeed = completionTokensForSpeed
        self.tokenPerSecond = tokenPerSecond
        self.isTokenPerSecondEstimated = isTokenPerSecondEstimated
        self.reasoningSummary = reasoningSummary
        self.speedSamples = speedSamples
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestStartedAt
        case responseCompletedAt
        case totalResponseDuration
        case timeToFirstToken
        case reasoningStartedAt
        case reasoningCompletedAt
        case completionTokensForSpeed
        case tokenPerSecond
        case isTokenPerSecondEstimated
        case reasoningSummary
        case speedSamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? MessageResponseMetrics.currentSchemaVersion
        self.requestStartedAt = try container.decodeIfPresent(Date.self, forKey: .requestStartedAt)
        self.responseCompletedAt = try container.decodeIfPresent(Date.self, forKey: .responseCompletedAt)
        self.totalResponseDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .totalResponseDuration)
        self.timeToFirstToken = try container.decodeIfPresent(TimeInterval.self, forKey: .timeToFirstToken)
        self.reasoningStartedAt = try container.decodeIfPresent(Date.self, forKey: .reasoningStartedAt)
        self.reasoningCompletedAt = try container.decodeIfPresent(Date.self, forKey: .reasoningCompletedAt)
        self.completionTokensForSpeed = try container.decodeIfPresent(Int.self, forKey: .completionTokensForSpeed)
        self.tokenPerSecond = try container.decodeIfPresent(Double.self, forKey: .tokenPerSecond)
        self.isTokenPerSecondEstimated = try container.decodeIfPresent(Bool.self, forKey: .isTokenPerSecondEstimated) ?? false
        self.reasoningSummary = try container.decodeIfPresent(String.self, forKey: .reasoningSummary)
        // 流式曲线采样属于临时内存数据，解码时主动丢弃，避免历史会话回放占用内存。
        self.speedSamples = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(requestStartedAt, forKey: .requestStartedAt)
        try container.encodeIfPresent(responseCompletedAt, forKey: .responseCompletedAt)
        try container.encodeIfPresent(totalResponseDuration, forKey: .totalResponseDuration)
        try container.encodeIfPresent(timeToFirstToken, forKey: .timeToFirstToken)
        try container.encodeIfPresent(reasoningStartedAt, forKey: .reasoningStartedAt)
        try container.encodeIfPresent(reasoningCompletedAt, forKey: .reasoningCompletedAt)
        try container.encodeIfPresent(completionTokensForSpeed, forKey: .completionTokensForSpeed)
        try container.encodeIfPresent(tokenPerSecond, forKey: .tokenPerSecond)
        try container.encode(isTokenPerSecondEstimated, forKey: .isTokenPerSecondEstimated)
        try container.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
        // 不编码 speedSamples，保证该数据只驻留内存。
    }
}

/// 聊天消息数据结构 (App的"官方语言")
/// 这是一个纯粹的数据模型，不包含任何UI状态
/// 支持多版本历史记录功能 - 重试时保留旧版本，用户可在版本间切换
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var requestedAt: Date? // 对应请求的发起时间（用于会话 JSON 落盘）

    // MARK: - 多版本内容存储
    /// 所有版本的内容数组（内部存储）
    private var contentVersions: [String]
    /// 当前显示的版本索引（基于0）
    private var currentVersionIndex: Int

    /// 当前显示的内容（计算属性，向后兼容）
    public var content: String {
        get {
            guard !contentVersions.isEmpty else { return "" }
            let index = min(max(0, currentVersionIndex), contentVersions.count - 1)
            return contentVersions[index]
        }
        set {
            if contentVersions.isEmpty {
                contentVersions = [newValue]
                currentVersionIndex = 0
            } else {
                let index = min(max(0, currentVersionIndex), contentVersions.count - 1)
                contentVersions[index] = newValue
            }
        }
    }

    /// 是否有多个版本
    public var hasMultipleVersions: Bool {
        contentVersions.count > 1
    }

    /// 获取所有版本
    public func getAllVersions() -> [String] {
        return contentVersions
    }

    /// 获取当前版本索引
    public func getCurrentVersionIndex() -> Int {
        return currentVersionIndex
    }

    public var reasoningContent: String? // 用于存放推理过程等附加信息
    public var reasoningProviderSpecificFields: [String: JSONValue]? // 推理延续所需的协议元数据
    public var toolCalls: [InternalToolCall]? // AI发出的工具调用指令
    public var toolCallsPlacement: ToolCallsPlacement? // 工具调用在正文前/后显示
    public var tokenUsage: MessageTokenUsage? // 最近一次调用消耗的 Token 统计
    public var audioFileName: String? // 关联的音频文件名，存储在 AudioFiles 目录下
    public var imageFileNames: [String]? // 关联的图片文件名列表，存储在 ImageFiles 目录下
    public var fileFileNames: [String]? // 关联的文件名列表，存储在 FileAttachments 目录下
    public var fullErrorContent: String? // 错误消息的完整原始内容（当内容被截断时使用）
    public var responseMetrics: MessageResponseMetrics? // 单次请求的响应测速信息
    public var responseGroupID: UUID? // 回复组 ID，通常指向锚点 user 消息
    public var responseAttemptID: UUID? // 当前消息所属的一次回复尝试
    public var responseAttemptIndex: Int? // 当前回复尝试在组内的序号
    public var selectedResponseAttemptID: UUID? // 锚点 user 消息当前选中的回复尝试

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        requestedAt: Date? = nil,
        reasoningContent: String? = nil,
        reasoningProviderSpecificFields: [String: JSONValue]? = nil,
        toolCalls: [InternalToolCall]? = nil,
        toolCallsPlacement: ToolCallsPlacement? = nil,
        tokenUsage: MessageTokenUsage? = nil,
        audioFileName: String? = nil,
        imageFileNames: [String]? = nil,
        fileFileNames: [String]? = nil,
        fullErrorContent: String? = nil,
        responseMetrics: MessageResponseMetrics? = nil,
        responseGroupID: UUID? = nil,
        responseAttemptID: UUID? = nil,
        responseAttemptIndex: Int? = nil,
        selectedResponseAttemptID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.requestedAt = requestedAt
        self.contentVersions = [content]
        self.currentVersionIndex = 0
        self.reasoningContent = reasoningContent
        self.reasoningProviderSpecificFields = reasoningProviderSpecificFields
        self.toolCalls = toolCalls
        self.toolCallsPlacement = toolCallsPlacement
        self.tokenUsage = tokenUsage
        self.audioFileName = audioFileName
        self.imageFileNames = imageFileNames
        self.fileFileNames = fileFileNames
        self.fullErrorContent = fullErrorContent
        self.responseMetrics = responseMetrics
        self.responseGroupID = responseGroupID
        self.responseAttemptID = responseAttemptID
        self.responseAttemptIndex = responseAttemptIndex
        self.selectedResponseAttemptID = selectedResponseAttemptID
    }

    // MARK: - 版本管理方法

    /// 添加新版本到历史记录
    public mutating func addVersion(_ newContent: String) {
        contentVersions.append(newContent)
        currentVersionIndex = contentVersions.count - 1
    }

    /// 删除指定版本
    public mutating func removeVersion(at index: Int) {
        guard contentVersions.indices.contains(index), contentVersions.count > 1 else { return }

        contentVersions.remove(at: index)

        // 调整当前索引
        if currentVersionIndex >= index {
            currentVersionIndex = max(0, currentVersionIndex - 1)
        }
        // 确保索引在有效范围内
        currentVersionIndex = min(currentVersionIndex, contentVersions.count - 1)
    }

    /// 删除指定版本并返回删除后的当前索引
    public mutating func removeVersionAndReturnCurrentIndex(at index: Int) -> Int? {
        guard contentVersions.indices.contains(index), contentVersions.count > 1 else { return nil }

        removeVersion(at: index)
        return currentVersionIndex
    }

    /// 切换到指定版本
    public mutating func switchToVersion(_ index: Int) {
        if contentVersions.indices.contains(index) {
            currentVersionIndex = index
        }
    }

    // MARK: - Codable 支持（向后兼容）

    enum CodingKeys: String, CodingKey {
        case id, role, requestedAt, content, currentVersionIndex
        case reasoningContent, reasoningProviderSpecificFields, toolCalls, toolCallsPlacement, tokenUsage
        case audioFileName, imageFileNames, fileFileNames, fullErrorContent, responseMetrics
        case responseGroupID, responseAttemptID, responseAttemptIndex, selectedResponseAttemptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt)

        // 读取 content 字段：可能是字符串（旧版）或数组（新版）
        if let contentArray = try? container.decode([String].self, forKey: .content) {
            // 新版：数组格式
            self.contentVersions = contentArray.isEmpty ? [""] : contentArray
            self.currentVersionIndex = (try? container.decode(Int.self, forKey: .currentVersionIndex)) ?? 0
            // 确保索引有效
            self.currentVersionIndex = min(max(0, self.currentVersionIndex), self.contentVersions.count - 1)
        } else if let singleContent = try? container.decode(String.self, forKey: .content) {
            // 旧版：字符串格式
            self.contentVersions = [singleContent]
            self.currentVersionIndex = 0
        } else {
            // 默认空内容
            self.contentVersions = [""]
            self.currentVersionIndex = 0
        }

        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.reasoningProviderSpecificFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .reasoningProviderSpecificFields)
        self.toolCalls = try container.decodeIfPresent([InternalToolCall].self, forKey: .toolCalls)
        self.toolCallsPlacement = try container.decodeIfPresent(ToolCallsPlacement.self, forKey: .toolCallsPlacement)
        self.tokenUsage = try container.decodeIfPresent(MessageTokenUsage.self, forKey: .tokenUsage)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        self.imageFileNames = try container.decodeIfPresent([String].self, forKey: .imageFileNames)
        self.fileFileNames = try container.decodeIfPresent([String].self, forKey: .fileFileNames)
        self.fullErrorContent = try container.decodeIfPresent(String.self, forKey: .fullErrorContent)
        self.responseMetrics = try container.decodeIfPresent(MessageResponseMetrics.self, forKey: .responseMetrics)
        self.responseGroupID = try container.decodeIfPresent(UUID.self, forKey: .responseGroupID)
        self.responseAttemptID = try container.decodeIfPresent(UUID.self, forKey: .responseAttemptID)
        self.responseAttemptIndex = try container.decodeIfPresent(Int.self, forKey: .responseAttemptIndex)
        self.selectedResponseAttemptID = try container.decodeIfPresent(UUID.self, forKey: .selectedResponseAttemptID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(requestedAt, forKey: .requestedAt)

        // 保存 content：如果只有一个版本，保存为字符串；多个版本保存为数组
        if contentVersions.count == 1 {
            try container.encode(contentVersions[0], forKey: .content)
        } else {
            try container.encode(contentVersions, forKey: .content)
            try container.encode(currentVersionIndex, forKey: .currentVersionIndex)
        }

        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(reasoningProviderSpecificFields, forKey: .reasoningProviderSpecificFields)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallsPlacement, forKey: .toolCallsPlacement)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try container.encodeIfPresent(imageFileNames, forKey: .imageFileNames)
        try container.encodeIfPresent(fileFileNames, forKey: .fileFileNames)
        try container.encodeIfPresent(fullErrorContent, forKey: .fullErrorContent)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
        try container.encodeIfPresent(responseGroupID, forKey: .responseGroupID)
        try container.encodeIfPresent(responseAttemptID, forKey: .responseAttemptID)
        try container.encodeIfPresent(responseAttemptIndex, forKey: .responseAttemptIndex)
        try container.encodeIfPresent(selectedResponseAttemptID, forKey: .selectedResponseAttemptID)
    }
}

public struct ChatResponseAttemptVersionInfo: Equatable, Sendable {
    public let responseGroupID: UUID
    public let currentAttemptID: UUID
    public let currentIndex: Int
    public let totalCount: Int
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
        guard (message.role == .assistant || message.role == .error),
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
        let lastDisplayableID = visibleAttemptMessages.last(where: { $0.role == .assistant || $0.role == .error })?.id
        guard lastDisplayableID == message.id else { return nil }

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
            guard message.id == groupID, message.role == .user else { return message }
            var updated = message
            updated.selectedResponseAttemptID = attemptID
            return updated
        }
    }

    public static func deleteAttempt(at index: Int, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage]? {
        let attempts = orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.indices.contains(index) else { return nil }

        let targetAttemptID = attempts[index]
        let selectedAttemptID = messages.first { $0.id == groupID && $0.role == .user }?.selectedResponseAttemptID
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
        struct AttemptOrder {
            let id: UUID
            let explicitIndex: Int
            let firstPosition: Int
        }

        var orderByID: [UUID: AttemptOrder] = [:]
        for (position, message) in messages.enumerated() {
            guard message.responseGroupID == groupID,
                  let attemptID = message.responseAttemptID else {
                continue
            }
            let explicitIndex = message.responseAttemptIndex ?? Int.max
            if let existing = orderByID[attemptID] {
                orderByID[attemptID] = AttemptOrder(
                    id: attemptID,
                    explicitIndex: min(existing.explicitIndex, explicitIndex),
                    firstPosition: min(existing.firstPosition, position)
                )
            } else {
                orderByID[attemptID] = AttemptOrder(
                    id: attemptID,
                    explicitIndex: explicitIndex,
                    firstPosition: position
                )
            }
        }

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
        var selectedByGroup: [UUID: UUID] = [:]
        for message in messages where message.role == .user {
            if let selectedAttemptID = message.selectedResponseAttemptID {
                selectedByGroup[message.id] = selectedAttemptID
            }
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
}

/// 消息所关联的一次 API 调用的 Token 统计
public struct MessageTokenUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var thinkingTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheReadTokens: Int?
    public var totalTokens: Int?

    public init(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        thinkingTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheReadTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }

    public var hasData: Bool {
        hasAnyData
    }

    public var hasAnyData: Bool {
        promptTokens != nil
            || completionTokens != nil
            || thinkingTokens != nil
            || cacheWriteTokens != nil
            || cacheReadTokens != nil
            || totalTokens != nil
    }
}

/// 请求日志状态
public enum RequestLogStatus: String, Codable, Hashable, Sendable {
    case success
    case failed
    case cancelled
}

/// 单次模型请求日志
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

/// 请求日志查询条件
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

/// 请求日志 Token 汇总值
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

/// 请求日志分组统计
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

/// 请求日志汇总
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

/// 聊天会话数据结构
public struct ChatSession: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var topicPrompt: String?
    public var enhancedPrompt: String?
    /// 会话所属文件夹，nil 表示未分类。
    public var folderID: UUID?
    public var lorebookIDs: [UUID]
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
        if worldbookContextIsolationEnabled {
            try container.encode(worldbookContextIsolationEnabled, forKey: .worldbookContextIsolationEnabled)
        }
    }
}

/// 会话文件夹数据结构
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
