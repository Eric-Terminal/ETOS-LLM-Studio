import Foundation

public struct ChatMessageRenderConfiguration: Equatable, Sendable {
    public var hasRoleplay: Bool
    public var rendersHTML: Bool

    public init(hasRoleplay: Bool = false, rendersHTML: Bool = false) {
        self.hasRoleplay = hasRoleplay
        self.rendersHTML = rendersHTML
    }

    /// 绑定查询可能等待配置数据库，只在消息预处理队列调用。
    public static func load(sessionID: UUID?) -> Self {
        guard let sessionID, let binding = RoleplayStore.shared.binding(sessionID: sessionID) else {
            return Self()
        }
        return Self(hasRoleplay: !binding.characterIDs.isEmpty, rendersHTML: binding.htmlRenderingEnabled)
    }
}

/// 在串行后台队列准备消息差异、版本与工具索引，主线程只应用当前窗口中的变化。
public struct ChatMessageListSnapshot: Sendable {
    public struct Change: Sendable {
        public let message: ChatMessage
        public let isTextOnly: Bool
    }

    public let sessionID: UUID?
    public let revision: Int
    public let baseRevision: Int?
    public let messages: [ChatMessage]
    public let visibleMessages: [ChatMessage]
    public let visibleIDs: Set<UUID>
    public let historyIndex: ChatHistoryWindowIndex
    public let hasSameMessageIdentity: Bool
    public let historyStructureChanged: Bool
    public let changes: [Change]
    public let versionIndex: [UUID: ChatResponseAttemptVersionInfo]
    public let versionRevision: Int
    public let latestAssistantMessage: ChatMessage?
    public let toolCallResultIDs: Set<String>
    public let existingToolCallIDs: Set<String>
    public let agentToolPreview: AgentToolExecutionPreviewSnapshot?
    public let renderConfiguration: ChatMessageRenderConfiguration
    public let forceRendering: Bool
    public let canQuickRetry: Bool
    public let userContentPreviews: [UUID: ChatUserMessagePreview]
    private let previewCharacterLimit: Int
    private let visualRules: [MessageRegexRule]
    private let userPreviewSources: [UUID: String]
    private let visiblePositions: [Int]

    public init(
        messages: [ChatMessage], sessionID: UUID?, previous: Self? = nil,
        renderConfiguration: ChatMessageRenderConfiguration = .init(), forceRendering: Bool = false,
        previewCharacterLimit: Int = ChatUserMessagePreview.defaultCharacterLimit,
        visualRules: [MessageRegexRule] = []
    ) {
        self.messages = messages
        self.sessionID = sessionID
        revision = (previous?.revision ?? 0) &+ 1
        let previous = previous?.sessionID == sessionID ? previous : nil
        self.renderConfiguration = renderConfiguration
        self.forceRendering = forceRendering || previous?.renderConfiguration != renderConfiguration
            || previous?.previewCharacterLimit != previewCharacterLimit || previous?.visualRules != visualRules
        baseRevision = previous?.revision
        let oldMessages = previous?.messages ?? []
        hasSameMessageIdentity = previous != nil && oldMessages.count == messages.count
            && zip(oldMessages, messages).allSatisfy { $0.id == $1.id }

        var changes: [Change] = []
        var topologyChanged = !hasSameMessageIdentity
        var toolsChanged = !hasSameMessageIdentity
        if hasSameMessageIdentity {
            for (old, new) in zip(oldMessages, messages) where old != new {
                changes.append(Change(
                    message: new,
                    isTextOnly: ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: old, to: new)
                ))
                topologyChanged = topologyChanged || old.role != new.role
                    || old.responseGroupID != new.responseGroupID
                    || old.responseAttemptID != new.responseAttemptID
                    || old.responseAttemptIndex != new.responseAttemptIndex
                    || old.selectedResponseAttemptID != new.selectedResponseAttemptID
                toolsChanged = toolsChanged || old.toolCalls != new.toolCalls
            }
        }
        self.changes = changes
        historyStructureChanged = topologyChanged

        if let previous, !topologyChanged {
            // Token 和倒计时不改变分支选择，复用可见位置和版本索引。
            visiblePositions = previous.visiblePositions
            visibleIDs = previous.visibleIDs
            visibleMessages = visiblePositions.map { messages[$0] }
            historyIndex = previous.historyIndex
            versionIndex = previous.versionIndex
            versionRevision = previous.versionRevision
        } else {
            let visible = ChatResponseAttemptSupport.visibleMessages(from: messages)
            let ids = Set(visible.map(\.id))
            visibleMessages = visible
            visibleIDs = ids
            visiblePositions = messages.indices.filter { ids.contains(messages[$0].id) }
            historyIndex = ChatHistoryWindowIndex(messages: visible)
            versionIndex = ChatResponseAttemptSupport.versionInfoByMessageID(in: messages)
            versionRevision = (previous?.versionRevision ?? 0) &+ 1
        }
        latestAssistantMessage = visibleMessages.last { $0.role == .assistant }
        self.previewCharacterLimit = previewCharacterLimit
        self.visualRules = visualRules
        let canReusePreviews = previous?.previewCharacterLimit == previewCharacterLimit
            && previous?.visualRules == visualRules && !self.forceRendering
            && (!renderConfiguration.hasRoleplay || !topologyChanged)
        // 角色上下文只解析一次，不能为每条历史用户消息重复扫描整个会话。
        let resolvedRoleplay = renderConfiguration.hasRoleplay ? sessionID.flatMap {
            RoleplayRuntime.resolve(sessionID: $0, messages: messages, store: .shared)
        } : nil
        var previews: [UUID: ChatUserMessagePreview] = [:]
        var previewSources: [UUID: String] = [:]
        // 与消息身份一起发布，避免主线程先插入省略号气泡，再等待第二轮后台任务。
        for (position, message) in visibleMessages.enumerated() where message.role == .user {
            previewSources[message.id] = message.content
            if canReusePreviews, previous?.userPreviewSources[message.id] == message.content,
               let cached = previous?.userContentPreviews[message.id] {
                previews[message.id] = cached
                continue
            }
            var visual = ChatService.visualMessage(from: message, rules: visualRules)
            if let resolvedRoleplay {
                visual.content = RoleplayRuntime.visualContent(
                    visual.content, resolved: resolvedRoleplay, placement: .userInput,
                    depth: max(0, messages.count - visiblePositions[position] - 1)
                )
            }
            previews[message.id] = ChatUserMessagePreview(content: visual.content, characterLimit: previewCharacterLimit)
        }
        userContentPreviews = previews
        userPreviewSources = previewSources
        canQuickRetry = ChatQuickRetrySupport.canRetryLatestMessage(
            visibleMessages.last, hasUserMessage: visibleMessages.contains { $0.role == .user }
        )

        if let previous, !topologyChanged, !toolsChanged {
            toolCallResultIDs = previous.toolCallResultIDs
            existingToolCallIDs = previous.existingToolCallIDs
            agentToolPreview = previous.agentToolPreview
        } else {
            var resultIDs = Set<String>()
            var callIDs = Set<String>()
            var preview = AgentToolExecutionPreviewAccumulator()
            for message in messages {
                for call in message.toolCalls ?? [] {
                    callIDs.insert("\(message.id.uuidString)#\(call.id)")
                }
            }
            for message in visibleMessages {
                if message.role != .tool {
                    for call in message.toolCalls ?? [] where !(call.result ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resultIDs.insert(call.id)
                    }
                }
                preview.append(message)
            }
            toolCallResultIDs = resultIDs
            existingToolCallIDs = callIDs
            agentToolPreview = preview.preferred
        }
    }
}
