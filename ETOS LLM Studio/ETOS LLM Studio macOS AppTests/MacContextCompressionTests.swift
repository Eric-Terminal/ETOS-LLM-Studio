import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacContextCompressionTests {
    private func context(source: ChatSession, child: ChatSession, anchor: UUID = UUID(),
                         retained: [ChatMessage] = []) -> ConversationContinuationContext {
        .init(childSessionID: child.id, sourceSessionID: source.id, sourceSessionNameSnapshot: source.name,
            sourceThroughMessageID: anchor, summary: "续聊摘要", retainedMessages: retained, retainedRoundCount: 2,
            compressionModelIdentifier: "模型", sourceMessageCount: 5, summarizedMessageCount: 3)
    }

    private func state(session: ChatSession, sessions: [ChatSession], messages: [ChatMessage] = [],
                       incoming: ConversationContinuationContext? = nil,
                       outgoing: [ConversationContinuationContext] = []) -> MacContinuationPresentation {
        .init(sessionID: session.id, sessions: sessions, messages: messages, context: incoming, outgoing: outgoing,
              markdown: false, advanced: false)
    }

    @Test("压缩边界存在时索引到消息，边界消失后仍保留顶部入口")
    func outgoingLinksFollowAvailableAnchors() {
        let source = ChatSession(id: UUID(), name: "来源"), child = ChatSession(id: UUID(), name: "续聊")
        let message = ChatMessage(role: .user, content: "问题")
        let context = context(source: source, child: child, anchor: message.id)
        let anchored = state(session: source, sessions: [source, child], messages: [message], outgoing: [context])
        #expect(anchored.outgoingByMessageID[message.id]?.first?.targetID == child.id)
        #expect(anchored.unanchoredLinks.isEmpty)
        let orphaned = state(session: source, sessions: [source, child], outgoing: [context])
        #expect(orphaned.outgoingByMessageID.isEmpty)
        #expect(orphaned.unanchoredLinks.map(\.id) == [context.id])
    }

    @Test("两个方向的隐藏标记相互独立且不隐藏摘要")
    func visibilityFlagsAreDirectional() {
        let source = ChatSession(id: UUID(), name: "来源"), child = ChatSession(id: UUID(), name: "续聊")
        let context = context(source: source, child: child).hidingLink(.sourceSession)
        let incoming = state(session: child, sessions: [source, child], incoming: context)
        #expect(incoming.sourceLink == nil)
        #expect(incoming.summary?.source == context.summary)
        let outgoing = state(session: source, sessions: [source, child], outgoing: [context])
        #expect(outgoing.unanchoredLinks.count == 1)
        let hidden = state(session: source, sessions: [source, child], outgoing: [context.hidingLink(.continuationSession)])
        #expect(hidden.unanchoredLinks.isEmpty)
    }

    @Test("来源删除后保留快照名称与交接但禁用跳转")
    func deletedSourceKeepsReadableHandoff() {
        let source = ChatSession(id: UUID(), name: "已删除来源"), child = ChatSession(id: UUID(), name: "续聊")
        let context = context(source: source, child: child)
        let state = state(session: child, sessions: [child], incoming: context)
        #expect(state.sourceLink?.isAvailable == false)
        #expect(state.sourceLink?.title.contains(source.name) == true)
        #expect(state.hasContent)
        #expect(state.context == context)
    }

    @Test("其他来源的关系不会出现在当前会话")
    func excludesUnrelatedOutgoingContext() {
        let source = ChatSession(id: UUID(), name: "当前"), other = ChatSession(id: UUID(), name: "其他")
        let child = ChatSession(id: UUID(), name: "续聊")
        let state = state(session: source, sessions: [source, other, child], outgoing: [context(source: other, child: child)])
        #expect(state.outgoingByMessageID.isEmpty && state.unanchoredLinks.isEmpty)
    }

    @Test("纯交接不立即重复提醒，有新消息后重新纳入估算")
    func freshContinuationDoesNotRemindUntilNewMessages() {
        let source = ChatSession(id: UUID(), name: "来源"), child = ChatSession(id: UUID(), name: "续聊")
        let retained = [ChatMessage(role: .user, content: "必须保留的原文")]
        let context = context(source: source, child: child, retained: retained)
        let fresh = state(session: child, sessions: [child], incoming: context)
        #expect(!fresh.shouldEvaluateReminder)
        #expect(fresh.retainedMessages.first?.text.source == retained[0].content)
        let message = ChatMessage(role: .user, content: "继续")
        let updated = state(session: child, sessions: [child], messages: [message], incoming: context)
        #expect(updated.shouldEvaluateReminder)
        #expect(updated.estimatedTokens > fresh.estimatedTokens)
    }

    @Test("保留的工具调用展示完整原参数和结果，不解析或执行")
    func retainedToolContentStaysLiteral() {
        let source = ChatSession(id: UUID(), name: "来源"), child = ChatSession(id: UUID(), name: "续聊")
        let call = InternalToolCall(id: "call", toolName: "工具", arguments: "{\"path\":\"/private\"}", result: "<html>原始结果</html>")
        let message = ChatMessage(role: .assistant, content: "", toolCalls: [call])
        let context = context(source: source, child: child, retained: [message])
        let result = state(session: child, sessions: [child], incoming: context)
        #expect(result.retainedMessages.first?.tools.first?.arguments == call.arguments)
        #expect(result.retainedMessages.first?.tools.first?.result == call.result)
        #expect(result.retainedMessages.first?.tools.first?.name == call.toolName)
    }

    @Test("空白或只有错误的会话不提供压缩入口")
    func emptyAndErrorOnlyChatsHaveNoContent() {
        let session = ChatSession(id: UUID(), name: "新会话")
        #expect(!state(session: session, sessions: [session]).hasContent)
        #expect(!state(session: session, sessions: [session], messages: [.init(role: .error, content: "错误")]).hasContent)
    }

    @Test("向导快照只有标识和计数，不包含摘要与保留消息正文")
    func guideOmitsConversationContent() {
        let source = ChatSession(id: UUID(), name: "来源"), child = ChatSession(id: UUID(), name: "续聊")
        let context = context(source: source, child: child, retained: [.init(role: .assistant, content: "私有正文")])
        let result = state(session: child, sessions: [child], incoming: context)
        #expect(result.guideSummary == .dictionary([
            "session_id": .string(child.id.uuidString), "has_context": .bool(true),
            "retained_rounds": .int(2), "retained_messages": .int(1), "estimated_tokens": .int(result.estimatedTokens)
        ]))
    }

    @Test("双语文档说明草稿确认、独立隐藏和通知不自动执行")
    func guideExplainsManualBoundaries() {
        let chinese = GuideContextCompressionKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideContextCompressionKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("不能开始压缩") && chinese.contains("只隐藏当前方向"))
        #expect(english.contains("opens options only") && english.contains("Manual Create Continuation"))
        #expect(GuideDocumentCatalog.documents.contains { $0.id == "context-compression" })
    }
}
