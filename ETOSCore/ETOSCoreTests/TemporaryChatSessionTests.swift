// ============================================================================
// TemporaryChatSessionTests.swift
// ============================================================================

import Testing
import Combine
@testable import ETOSCore

@Suite("临时对话会话测试", .serialized)
struct TemporaryChatSessionTests {
    @Test("临时对话关闭前只保留内存快照，关闭后完整落盘")
    func temporaryMessagesPersistOnlyAfterSavingSession() throws {
        let service = ChatService()
        service.enableTemporaryChat()
        let session = try #require(service.currentSessionSubject.value)
        defer {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        let messages = [ChatMessage(role: .user, content: "只存在于内存")]
        service.persistAndPublishMessages(messages, for: session.id)

        #expect(service.isTemporaryChatEnabled(for: session.id))
        #expect(service.messagesForSessionActivation(session.id) == messages)
        #expect(Persistence.loadMessages(for: session.id).isEmpty)

        #expect(service.saveCurrentTemporaryChat())
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        #expect(!service.isTemporaryChatEnabled(for: session.id))
        #expect(Persistence.loadMessages(for: session.id) == messages)
    }
}
