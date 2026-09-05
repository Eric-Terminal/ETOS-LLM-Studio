// ============================================================================
// ChatModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义聊天消息与响应测速核心数据结构。
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

/// 视频理解模型生成并持久化的附件语义。
public struct VideoAnalysisResult: Identifiable, Codable, Hashable, Sendable {
    public let fileName: String
    public let content: String
    public let modelIdentifier: String
    public let modelDisplayName: String
    public let generatedAt: Date

    public var id: String { fileName }

    public init(
        fileName: String,
        content: String,
        modelIdentifier: String,
        modelDisplayName: String,
        generatedAt: Date = Date()
    ) {
        self.fileName = fileName
        self.content = content
        self.modelIdentifier = modelIdentifier
        self.modelDisplayName = modelDisplayName
        self.generatedAt = generatedAt
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
    public var providerResponseMetadata: [String: JSONValue]? // 响应级协议元数据，例如 Responses 的 ID 与 output items
    public var toolCalls: [InternalToolCall]? // AI发出的工具调用指令
    public var toolCallsPlacement: ToolCallsPlacement? // 工具调用在正文前/后显示
    public var tokenUsage: MessageTokenUsage? // 最近一次调用消耗的 Token 统计
    public var modelReference: MessageModelReference? // 生成该消息时使用的模型快照
    public var costEstimate: MessageCostEstimate? // 基于本地模型价格配置计算的费用快照
    public var audioFileName: String? // 关联的音频文件名，存储在 AudioFiles 目录下
    public var imageFileNames: [String]? // 关联的图片文件名列表，存储在 ImageFiles 目录下
    /// 只在本地显示、不应作为历史图片输入发送给模型的附件文件名子集。
    public var modelExcludedImageFileNames: [String]?
    public var fileFileNames: [String]? // 关联的文件名列表，存储在 FileAttachments 目录下
    public var videoAnalysisResults: [VideoAnalysisResult]? // 视频附件的持久化语义解析结果
    public var fullErrorContent: String? // 错误消息的完整原始内容（当内容被截断时使用）
    public var sentSystemPromptSnapshot: String? // 该回复请求实际发送的 system 角色消息快照；nil 表示旧消息未记录
    public var responseMetrics: MessageResponseMetrics? // 单次请求的响应测速信息
    public var responseGroupID: UUID? // 回复组 ID，通常指向锚点 user 消息
    public var responseAttemptID: UUID? // 当前消息所属的一次回复尝试
    public var responseAttemptIndex: Int? // 当前回复尝试在组内的序号
    public var selectedResponseAttemptID: UUID? // 锚点 user 消息当前选中的回复尝试
    /// 消息在数据库中的真实作者类型；跨会话输入提交给模型时仍可映射为 user role。
    public var authorKind: ConversationMessageAuthorKind
    /// 跨会话消息的实际来源会话。
    public var sourceSessionID: UUID?
    /// 复制或转发消息在来源会话中的原消息 ID。
    public var sourceMessageID: UUID?
    /// 触发当前消息落库的持久邮箱事件。
    public var conversationEventID: UUID?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        requestedAt: Date? = nil,
        reasoningContent: String? = nil,
        reasoningProviderSpecificFields: [String: JSONValue]? = nil,
        providerResponseMetadata: [String: JSONValue]? = nil,
        toolCalls: [InternalToolCall]? = nil,
        toolCallsPlacement: ToolCallsPlacement? = nil,
        tokenUsage: MessageTokenUsage? = nil,
        modelReference: MessageModelReference? = nil,
        costEstimate: MessageCostEstimate? = nil,
        audioFileName: String? = nil,
        imageFileNames: [String]? = nil,
        modelExcludedImageFileNames: [String]? = nil,
        fileFileNames: [String]? = nil,
        videoAnalysisResults: [VideoAnalysisResult]? = nil,
        fullErrorContent: String? = nil,
        sentSystemPromptSnapshot: String? = nil,
        responseMetrics: MessageResponseMetrics? = nil,
        responseGroupID: UUID? = nil,
        responseAttemptID: UUID? = nil,
        responseAttemptIndex: Int? = nil,
        selectedResponseAttemptID: UUID? = nil,
        authorKind: ConversationMessageAuthorKind? = nil,
        sourceSessionID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        conversationEventID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.requestedAt = requestedAt
        self.contentVersions = [content]
        self.currentVersionIndex = 0
        self.reasoningContent = reasoningContent
        self.reasoningProviderSpecificFields = reasoningProviderSpecificFields
        self.providerResponseMetadata = providerResponseMetadata
        self.toolCalls = toolCalls
        self.toolCallsPlacement = toolCallsPlacement
        self.tokenUsage = tokenUsage
        self.modelReference = modelReference
        self.costEstimate = costEstimate
        self.audioFileName = audioFileName
        self.imageFileNames = imageFileNames
        self.modelExcludedImageFileNames = modelExcludedImageFileNames
        self.fileFileNames = fileFileNames
        self.videoAnalysisResults = videoAnalysisResults
        self.fullErrorContent = fullErrorContent
        self.sentSystemPromptSnapshot = sentSystemPromptSnapshot
        self.responseMetrics = responseMetrics
        self.responseGroupID = responseGroupID
        self.responseAttemptID = responseAttemptID
        self.responseAttemptIndex = responseAttemptIndex
        self.selectedResponseAttemptID = selectedResponseAttemptID
        self.authorKind = authorKind ?? ConversationMessageAuthorKind.defaultValue(for: role)
        self.sourceSessionID = sourceSessionID
        self.sourceMessageID = sourceMessageID
        self.conversationEventID = conversationEventID
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

    /// 删除正文气泡时清空所有文本版本，避免切换版本后旧正文重新出现。
    public mutating func clearContentVersions() {
        contentVersions = [""]
        currentVersionIndex = 0
    }

    /// 只有真正参与模型上下文的图片才会进入请求附件映射。
    public var modelVisibleImageFileNames: [String] {
        let excluded = Set(modelExcludedImageFileNames ?? [])
        return (imageFileNames ?? []).filter { !excluded.contains($0) }
    }

    // MARK: - Codable 支持（向后兼容）

    enum CodingKeys: String, CodingKey {
        case id, role, requestedAt, content, currentVersionIndex
        case reasoningContent, reasoningProviderSpecificFields, providerResponseMetadata, toolCalls, toolCallsPlacement, tokenUsage
        case modelReference, costEstimate
        case audioFileName, imageFileNames, modelExcludedImageFileNames, fileFileNames, videoAnalysisResults, fullErrorContent, sentSystemPromptSnapshot, responseMetrics
        case responseGroupID, responseAttemptID, responseAttemptIndex, selectedResponseAttemptID
        case authorKind, sourceSessionID, sourceMessageID, conversationEventID
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
        self.providerResponseMetadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .providerResponseMetadata)
        self.toolCalls = try container.decodeIfPresent([InternalToolCall].self, forKey: .toolCalls)
        self.toolCallsPlacement = try container.decodeIfPresent(ToolCallsPlacement.self, forKey: .toolCallsPlacement)
        self.tokenUsage = try container.decodeIfPresent(MessageTokenUsage.self, forKey: .tokenUsage)
        self.modelReference = try container.decodeIfPresent(MessageModelReference.self, forKey: .modelReference)
        self.costEstimate = try container.decodeIfPresent(MessageCostEstimate.self, forKey: .costEstimate)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        self.imageFileNames = try container.decodeIfPresent([String].self, forKey: .imageFileNames)
        self.modelExcludedImageFileNames = try container.decodeIfPresent([String].self, forKey: .modelExcludedImageFileNames)
        self.fileFileNames = try container.decodeIfPresent([String].self, forKey: .fileFileNames)
        self.videoAnalysisResults = try container.decodeIfPresent([VideoAnalysisResult].self, forKey: .videoAnalysisResults)
        self.fullErrorContent = try container.decodeIfPresent(String.self, forKey: .fullErrorContent)
        self.sentSystemPromptSnapshot = try container.decodeIfPresent(String.self, forKey: .sentSystemPromptSnapshot)
        self.responseMetrics = try container.decodeIfPresent(MessageResponseMetrics.self, forKey: .responseMetrics)
        self.responseGroupID = try container.decodeIfPresent(UUID.self, forKey: .responseGroupID)
        self.responseAttemptID = try container.decodeIfPresent(UUID.self, forKey: .responseAttemptID)
        self.responseAttemptIndex = try container.decodeIfPresent(Int.self, forKey: .responseAttemptIndex)
        self.selectedResponseAttemptID = try container.decodeIfPresent(UUID.self, forKey: .selectedResponseAttemptID)
        self.authorKind = try container.decodeIfPresent(ConversationMessageAuthorKind.self, forKey: .authorKind)
            ?? ConversationMessageAuthorKind.defaultValue(for: role)
        self.sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
        self.sourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceMessageID)
        self.conversationEventID = try container.decodeIfPresent(UUID.self, forKey: .conversationEventID)
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
        try container.encodeIfPresent(providerResponseMetadata, forKey: .providerResponseMetadata)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallsPlacement, forKey: .toolCallsPlacement)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(modelReference, forKey: .modelReference)
        try container.encodeIfPresent(costEstimate, forKey: .costEstimate)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try container.encodeIfPresent(imageFileNames, forKey: .imageFileNames)
        try container.encodeIfPresent(modelExcludedImageFileNames, forKey: .modelExcludedImageFileNames)
        try container.encodeIfPresent(fileFileNames, forKey: .fileFileNames)
        try container.encodeIfPresent(videoAnalysisResults, forKey: .videoAnalysisResults)
        try container.encodeIfPresent(fullErrorContent, forKey: .fullErrorContent)
        try container.encodeIfPresent(sentSystemPromptSnapshot, forKey: .sentSystemPromptSnapshot)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
        try container.encodeIfPresent(responseGroupID, forKey: .responseGroupID)
        try container.encodeIfPresent(responseAttemptID, forKey: .responseAttemptID)
        try container.encodeIfPresent(responseAttemptIndex, forKey: .responseAttemptIndex)
        try container.encodeIfPresent(selectedResponseAttemptID, forKey: .selectedResponseAttemptID)
        try container.encode(authorKind, forKey: .authorKind)
        try container.encodeIfPresent(sourceSessionID, forKey: .sourceSessionID)
        try container.encodeIfPresent(sourceMessageID, forKey: .sourceMessageID)
        try container.encodeIfPresent(conversationEventID, forKey: .conversationEventID)
    }
}

/// 消息所关联的一次 API 调用的 Token 统计
public struct MessageTokenUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    /// 服务商明确返回的非缓存输入量，避免对 Anthropic 的独立输入量再次扣除缓存命中。
    public var uncachedInputTokens: Int?
    public var completionTokens: Int?
    public var thinkingTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheWriteFiveMinuteTokens: Int?
    public var cacheWriteOneHourTokens: Int?
    public var cacheReadTokens: Int?
    public var totalTokens: Int?

    public init(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        thinkingTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheWriteFiveMinuteTokens: Int? = nil,
        cacheWriteOneHourTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        uncachedInputTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.completionTokens = completionTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWriteFiveMinuteTokens = cacheWriteFiveMinuteTokens
        self.cacheWriteOneHourTokens = cacheWriteOneHourTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }

    public var hasData: Bool {
        hasAnyData
    }

    public var hasAnyData: Bool {
        promptTokens != nil
            || uncachedInputTokens != nil
            || completionTokens != nil
            || thinkingTokens != nil
            || cacheWriteTokens != nil
            || cacheWriteFiveMinuteTokens != nil
            || cacheWriteOneHourTokens != nil
            || cacheReadTokens != nil
            || totalTokens != nil
    }
}
