import ETOSCore
import Foundation

/// 关系索引、摘要排版与 Token 估算只在后台构造，聊天行只查询当前消息的入口。
struct MacContinuationPresentation: Sendable {
    struct Link: Identifiable, Sendable {
        let context: ConversationContinuationContext
        let kind: ConversationContinuationLinkKind
        let targetID: UUID
        let title: String
        let isAvailable: Bool
        var id: UUID { context.id }
        var ownerSessionID: UUID { kind == .sourceSession ? context.childSessionID : context.sourceSessionID }
    }

    struct RetainedMessage: Identifiable, Sendable {
        struct Tool: Identifiable, Sendable {
            let id: Int
            let name: String
            let arguments: String
            let result: String?
        }
        let id: UUID
        let role: String
        let text: MacPreparedMessageText
        let tools: [Tool]
    }

    let sessionID: UUID
    let context: ConversationContinuationContext?
    let sourceLink: Link?
    let outgoingByMessageID: [UUID: [Link]]
    let unanchoredLinks: [Link]
    let summary: MacPreparedMessageText?
    let retainedMessages: [RetainedMessage]
    let estimatedTokens: Int
    let shouldEvaluateReminder: Bool
    let hasContent: Bool
    let guideSummary: JSONValue

    init(sessionID: UUID, sessions: [ChatSession], messages: [ChatMessage],
         context: ConversationContinuationContext?, outgoing: [ConversationContinuationContext],
         markdown: Bool, advanced: Bool) {
        self.sessionID = sessionID
        self.context = context
        let names = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.name) })
        if let context, !context.isSourceSessionLinkHidden {
            sourceLink = Link(context: context, kind: .sourceSession, targetID: context.sourceSessionID,
                title: String(format: NSLocalizedString("续接自“%@”", comment: ""), names[context.sourceSessionID] ?? context.sourceSessionNameSnapshot),
                isAvailable: names[context.sourceSessionID] != nil)
        } else { sourceLink = nil }
        let visible = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let messageIDs = Set(visible.map(\.id))
        var anchored: [UUID: [Link]] = [:], unanchored: [Link] = []
        for item in outgoing where item.sourceSessionID == sessionID && !item.isContinuationSessionLinkHidden {
            let name = names[item.childSessionID] ?? String(format: NSLocalizedString("%@ · 续聊", comment: ""), item.sourceSessionNameSnapshot)
            let link = Link(context: item, kind: .continuationSession, targetID: item.childSessionID,
                title: String(format: NSLocalizedString("已压缩为“%@”", comment: ""), name), isAvailable: names[item.childSessionID] != nil)
            if messageIDs.contains(item.sourceThroughMessageID) { anchored[item.sourceThroughMessageID, default: []].append(link) }
            else { unanchored.append(link) }
        }
        outgoingByMessageID = anchored; unanchoredLinks = unanchored
        summary = context.map { MacPreparedMessageText($0.summary, markdown: markdown, advanced: advanced) }
        retainedMessages = (context?.retainedMessages ?? []).map { message in
            let role: String
            switch message.role {
            case .system: role = NSLocalizedString("系统", comment: "")
            case .user: role = NSLocalizedString("用户", comment: "")
            case .assistant: role = NSLocalizedString("助手", comment: "")
            case .tool: role = NSLocalizedString("工具", comment: "")
            case .error: role = NSLocalizedString("错误", comment: "")
            }
            return RetainedMessage(id: message.id, role: role,
                text: MacPreparedMessageText(message.content, markdown: markdown && message.role != .user, advanced: advanced),
                tools: (message.toolCalls ?? []).enumerated().map {
                    RetainedMessage.Tool(id: $0.offset, name: $0.element.toolName, arguments: $0.element.arguments, result: $0.element.result)
                })
        }
        estimatedTokens = ContextCompressionReminderEstimator.estimate(messages: messages, continuationContext: context)
        shouldEvaluateReminder = ContextCompressionReminderPolicy.shouldEvaluateReminder(messageCount: messages.count,
            currentSessionID: sessionID, continuationContext: context)
        hasContent = context != nil || visible.contains { $0.role != .error }
        guideSummary = .dictionary([
            "session_id": .string(sessionID.uuidString), "has_context": .bool(context != nil),
            "retained_rounds": .int(context?.retainedRoundCount ?? 0),
            "retained_messages": .int(context?.retainedMessages.count ?? 0), "estimated_tokens": .int(estimatedTokens)
        ])
    }
}
