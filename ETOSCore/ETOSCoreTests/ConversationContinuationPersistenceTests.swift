// ============================================================================
// ConversationContinuationPersistenceTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证续聊上下文的迁移、原子创建和来源删除语义。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Conversation Continuation Persistence Tests")
struct ConversationContinuationPersistenceTests {
    @Test func createsSessionAndContextInOneTransaction() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "原会话", isTemporary: false)
            store.saveChatSessions([source])
            let child = ChatSession(
                id: UUID(),
                name: "原会话 · 续聊",
                topicPrompt: "话题",
                lorebookIDs: [UUID()],
                isTemporary: false
            )
            let retained = [
                ChatMessage(role: .user, content: "最近问题"),
                ChatMessage(role: .assistant, content: "最近回答")
            ]
            let context = makeContext(source: source, child: child, retainedMessages: retained)

            try store.createConversationContinuationSession(session: child, context: context)

            let persistedContext = try store.loadConversationContinuationContext(for: child.id)
            #expect(store.loadChatSessions().map(\.id) == [child.id, source.id])
            try expectPersistedContext(persistedContext, matches: context)
            #expect(store.loadMessages(for: child.id).isEmpty)
            #expect(!store.sessionIDsWithoutMessageData().contains(child.id))
        }
    }

    @Test func deletingSourceKeepsChildContext() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "可删除来源", isTemporary: false)
            store.saveChatSessions([source])
            let child = ChatSession(id: UUID(), name: "续聊", isTemporary: false)
            let context = makeContext(source: source, child: child)
            try store.createConversationContinuationSession(session: child, context: context)

            store.deleteSessionArtifacts(sessionID: source.id)

            let persistedContext = try store.loadConversationContinuationContext(for: child.id)
            try expectPersistedContext(persistedContext, matches: context)
            #expect(store.loadChatSessions().contains { $0.id == child.id })
        }
    }

    @Test func deletingChildCascadesContext() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "来源", isTemporary: false)
            store.saveChatSessions([source])
            let child = ChatSession(id: UUID(), name: "续聊", isTemporary: false)
            let context = makeContext(source: source, child: child)
            try store.createConversationContinuationSession(session: child, context: context)

            store.deleteSessionArtifacts(sessionID: child.id)

            let persistedContext = try store.loadConversationContinuationContext(for: child.id)
            #expect(persistedContext == nil)
        }
    }

    @Test func duplicateTargetDoesNotOverwriteExistingSession() throws {
        try withStore { store in
            let source = ChatSession(id: UUID(), name: "来源", isTemporary: false)
            let existingChild = ChatSession(id: UUID(), name: "已有会话", isTemporary: false)
            store.saveChatSessions([existingChild, source])
            let context = makeContext(source: source, child: existingChild)

            #expect(throws: ConversationContinuationPersistenceError.targetSessionAlreadyExists) {
                try store.createConversationContinuationSession(
                    session: existingChild,
                    context: context
                )
            }
            let persistedContext = try store.loadConversationContinuationContext(for: existingChild.id)
            #expect(store.loadChatSessions().first?.name == "已有会话")
            #expect(persistedContext == nil)
        }
    }

    private func makeContext(
        source: ChatSession,
        child: ChatSession,
        retainedMessages: [ChatMessage] = []
    ) -> ConversationContinuationContext {
        ConversationContinuationContext(
            childSessionID: child.id,
            sourceSessionID: source.id,
            sourceSessionNameSnapshot: source.name,
            sourceThroughMessageID: UUID(),
            summary: "完整摘要",
            retainedMessages: retainedMessages,
            retainedRoundCount: retainedMessages.isEmpty ? 0 : 1,
            compressionModelIdentifier: "provider-model",
            sourceMessageCount: 12,
            summarizedMessageCount: 10,
            estimatedSourceTokens: 900,
            estimatedResultTokens: 120
        )
    }

    private func expectPersistedContext(
        _ persistedContext: ConversationContinuationContext?,
        matches expectedContext: ConversationContinuationContext
    ) throws {
        let persistedContext = try #require(persistedContext)
        #expect(persistedContext.id == expectedContext.id)
        #expect(persistedContext.childSessionID == expectedContext.childSessionID)
        #expect(persistedContext.sourceSessionID == expectedContext.sourceSessionID)
        #expect(persistedContext.sourceSessionNameSnapshot == expectedContext.sourceSessionNameSnapshot)
        #expect(persistedContext.sourceThroughMessageID == expectedContext.sourceThroughMessageID)
        #expect(abs(persistedContext.createdAt.timeIntervalSince(expectedContext.createdAt)) < 0.001)
        #expect(persistedContext.summary == expectedContext.summary)
        #expect(persistedContext.retainedMessages == expectedContext.retainedMessages)
        #expect(persistedContext.retainedRoundCount == expectedContext.retainedRoundCount)
        #expect(persistedContext.compressionModelIdentifier == expectedContext.compressionModelIdentifier)
        #expect(persistedContext.promptVersion == expectedContext.promptVersion)
        #expect(persistedContext.sourceMessageCount == expectedContext.sourceMessageCount)
        #expect(persistedContext.summarizedMessageCount == expectedContext.summarizedMessageCount)
        #expect(persistedContext.estimatedSourceTokens == expectedContext.estimatedSourceTokens)
        #expect(persistedContext.estimatedResultTokens == expectedContext.estimatedResultTokens)
    }

    private func withStore(_ body: (PersistenceGRDBStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-continuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        try body(store)
    }
}
