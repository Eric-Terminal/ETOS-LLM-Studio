// ============================================================================
// SessionTagTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责会话标签模型、持久化与 ChatService 绑定行为测试。
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("会话标签测试")
struct SessionTagTests {
    private var chatsDirectory: URL {
        Persistence.getChatsDirectory()
    }

    private var chatStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite")
    }

    private var currentIndexFileURL: URL {
        chatsDirectory.appendingPathComponent("index.json")
    }

    private var currentSessionsDirectory: URL {
        chatsDirectory.appendingPathComponent("sessions")
    }

    private func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanupGRDBTagState(sessions: [ChatSession]) {
        Persistence.saveChatSessions([])
        Persistence.saveSessionTags([])
        for session in sessions {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        Persistence.resetGRDBStoreForTests()
        removeIfExists(chatStoreSQLiteURL)
    }

    private func cleanupFileTagState(sessions: [ChatSession]) {
        Persistence.saveChatSessions([])
        for session in sessions {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        removeIfExists(currentIndexFileURL)
        removeIfExists(currentSessionsDirectory)
    }

    @Test("ChatSession 会编解码标签 ID")
    func testChatSessionCodablePreservesTagIDs() throws {
        let tagID = UUID()
        let session = ChatSession(
            id: UUID(),
            name: "标签编解码会话",
            tagIDs: [tagID],
            isTemporary: false
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: encoded)

        #expect(decoded.tagIDs == [tagID])
    }

    @Test("ChatSession 兼容旧版 tagIds 字段")
    func testChatSessionDecodesLegacyTagIds() throws {
        let sessionID = UUID()
        let tagID = UUID()
        let json = """
        {
          "id": "\(sessionID.uuidString)",
          "name": "旧版标签字段会话",
          "tagIds": ["\(tagID.uuidString)"]
        }
        """

        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))

        #expect(decoded.id == sessionID)
        #expect(decoded.tagIDs == [tagID])
    }

    @Test("GRDB 会保存标签实体与会话标签绑定")
    func testGRDBPersistsSessionTagsAndAssignments() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let tagA = SessionTag(
            id: UUID(),
            name: "工作",
            color: .blue,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let tagB = SessionTag(
            id: UUID(),
            name: "灵感",
            color: .orange,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let invalidTagID = UUID()
        let session = ChatSession(
            id: UUID(),
            name: "标签绑定会话",
            tagIDs: [tagA.id, invalidTagID, tagB.id],
            isTemporary: false
        )
        defer { cleanupGRDBTagState(sessions: [session]) }

        cleanupGRDBTagState(sessions: [])
        Persistence.saveSessionTags([tagA, tagB])
        Persistence.saveChatSessions([session])

        let loadedTags = Persistence.loadSessionTags()
        let loadedSession = Persistence.loadChatSessions().first(where: { $0.id == session.id })

        #expect(Set(loadedTags.map(\.id)) == Set([tagA.id, tagB.id]))
        #expect(loadedTags.first(where: { $0.id == tagA.id })?.color == .blue)
        #expect(loadedSession?.tagIDs == [tagA.id, tagB.id])
    }

    @Test("文件会话索引会保存仅标签变化的元数据")
    func testFilePersistenceUpdatesTagOnlySessionMetadata() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = false
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let tagID = UUID()
        let session = ChatSession(
            id: UUID(),
            name: "文件标签落盘会话",
            isTemporary: false
        )
        var updatedSession = session
        updatedSession.tagIDs = [tagID]
        defer { cleanupFileTagState(sessions: [session]) }

        cleanupFileTagState(sessions: [])
        Persistence.saveChatSessions([session])
        Persistence.saveChatSessions([updatedSession])

        let loadedSession = Persistence.loadChatSessions().first(where: { $0.id == session.id })

        #expect(loadedSession?.tagIDs == [tagID])
    }
}

extension ChatServiceTests {
    @Test("删除标签会清理所有会话绑定")
    func testDeleteSessionTagRemovesSessionAssignments() async throws {
        await cleanup()
        Persistence.saveSessionTags([])
        chatService.sessionTagsSubject.send([])
        defer {
            Persistence.saveSessionTags([])
        }

        let tag = try #require(chatService.createSessionTag(name: "工作", color: .blue))
        let session = chatService.createSavedSession(name: "标签清理会话")
        defer {
            chatService.deleteSessions([session])
        }
        chatService.setSessionTags(sessionID: session.id, tagIDs: [tag.id])

        #expect(chatService.chatSessionsSubject.value.first(where: { $0.id == session.id })?.tagIDs == [tag.id])

        chatService.deleteSessionTag(tag)

        #expect(!chatService.sessionTagsSubject.value.contains(where: { $0.id == tag.id }))
        #expect(chatService.chatSessionsSubject.value.first(where: { $0.id == session.id })?.tagIDs.isEmpty == true)
        #expect(Persistence.loadChatSessions().first(where: { $0.id == session.id })?.tagIDs.isEmpty == true)
    }
}
