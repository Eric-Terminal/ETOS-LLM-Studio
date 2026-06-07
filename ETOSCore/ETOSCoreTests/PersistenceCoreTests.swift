// ============================================================================
// PersistenceCoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责持久化基础读写、GRDB 轻量行为与辅助 Blob 测试。
// ============================================================================

import Testing
import Foundation
import SQLite3
@testable import ETOSCore

@Suite("Persistence Core Tests")
struct PersistenceCoreTests {
    private struct LegacySessionRecord: Decodable {
        struct SessionMeta: Decodable {
            let id: UUID
            let name: String
            let folderID: UUID?
            let lorebookIDs: [UUID]
        }

        struct SessionPrompts: Decodable {
            let topicPrompt: String?
            let enhancedPrompt: String?
        }

        let schemaVersion: Int
        let session: SessionMeta
        let prompts: SessionPrompts
        let messages: [ChatMessage]
    }

    private var chatsDirectory: URL {
        Persistence.getChatsDirectory()
    }

    private var currentSessionsDirectory: URL {
        chatsDirectory.appendingPathComponent("sessions")
    }

    private var currentIndexFileURL: URL {
        chatsDirectory.appendingPathComponent("index.json")
    }

    private var foldersFileURL: URL {
        chatsDirectory.appendingPathComponent("folders.json")
    }

    private var chatStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite")
    }

    private var memoryStoreSQLiteURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memory")
            .appendingPathComponent("memory-store.sqlite")
    }

    private func currentSessionFileURL(_ sessionID: UUID) -> URL {
        currentSessionsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func sqliteCount(_ url: URL, sql: String) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return 0
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func cleanup(sessions: [ChatSession]) {
        Persistence.saveChatSessions([])
        Persistence.clearRequestLogs()
        for session in sessions {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        removeIfExists(currentIndexFileURL)
        removeIfExists(foldersFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(chatStoreSQLiteURL)
        removeIfExists(memoryStoreSQLiteURL)
    }

    @Test("Save and Load Chat Sessions")
    func testSaveAndLoadChatSessions() {
        let session1 = ChatSession(id: UUID(), name: "Session 1", isTemporary: false)
        let session2 = ChatSession(id: UUID(), name: "Session 2", topicPrompt: "Test Topic", isTemporary: false)
        let sessionsToSave = [session1, session2]

        Persistence.saveChatSessions(sessionsToSave)
        let loadedSessions = Persistence.loadChatSessions()

        #expect(loadedSessions.count == sessionsToSave.count)
        #expect(loadedSessions.first?.id == session1.id)
        #expect(loadedSessions.last?.name == session2.name)
        #expect(loadedSessions.last?.topicPrompt == "Test Topic")
        #expect(FileManager.default.fileExists(atPath: currentIndexFileURL.path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(session1.id).path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(session2.id).path))

        cleanup(sessions: sessionsToSave)
    }

    @Test("Save and Load Session Folders with Session Assignment")
    func testSaveAndLoadSessionFoldersWithSessionAssignment() {
        let folder = SessionFolder(name: "工作")
        Persistence.saveSessionFolders([folder])

        let session = ChatSession(
            id: UUID(),
            name: "Folder Session",
            folderID: folder.id,
            isTemporary: false
        )
        Persistence.saveChatSessions([session])

        let loadedFolders = Persistence.loadSessionFolders()
        let loadedSessions = Persistence.loadChatSessions()

        #expect(loadedFolders.count == 1)
        #expect(loadedFolders.first?.id == folder.id)
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.folderID == folder.id)

        cleanup(sessions: [session])
    }

    @Test("Save and Load Messages")
    func testSaveAndLoadMessages() {
        let sessionId = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let messagesToSave = [
            ChatMessage(role: .user, content: "Hello", requestedAt: requestedAt),
            ChatMessage(role: .assistant, content: "Hi there!")
        ]

        Persistence.saveMessages(messagesToSave, for: sessionId)
        let loadedMessages = Persistence.loadMessages(for: sessionId)

        #expect(loadedMessages.count == messagesToSave.count)
        #expect(loadedMessages.first?.content == "Hello")
        #expect(loadedMessages.first?.requestedAt == requestedAt)
        #expect(loadedMessages.last?.role == .assistant)

        let sessionFileURL = currentSessionFileURL(sessionId)
        #expect(FileManager.default.fileExists(atPath: sessionFileURL.path))
        if let migratedData = try? Data(contentsOf: sessionFileURL),
           let record = try? JSONDecoder().decode(LegacySessionRecord.self, from: migratedData) {
            #expect(record.schemaVersion == 3)
            #expect(record.messages.count == 2)
            #expect(record.messages.first?.content == "Hello")
            #expect(record.messages.first?.requestedAt == requestedAt)
        } else {
            Issue.record("会话文件不存在或格式不正确。")
        }

        cleanup(sessions: [ChatSession(id: sessionId, name: "cleanup", isTemporary: false)])
    }

    @Test("GRDB backend can count messages without loading full array")
    func testGRDBMessageCount() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "GRDB Count Session", isTemporary: false)
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "A"),
            ChatMessage(role: .assistant, content: "B"),
            ChatMessage(role: .assistant, content: "C")
        ]

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)

        let messageCount = Persistence.loadMessageCount(for: session.id)
        #expect(messageCount == 3)

        cleanup(sessions: [session])
    }

    @Test("GRDB saveMessages 会保留回复尝试元数据")
    func testGRDBSaveAndLoadResponseAttemptMetadata() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "回复尝试元数据会话", isTemporary: false)
        let groupID = UUID()
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let messages = [
            ChatMessage(
                id: groupID,
                role: .user,
                content: "问题",
                selectedResponseAttemptID: secondAttemptID
            ),
            ChatMessage(
                role: .assistant,
                content: "第一次回复",
                responseGroupID: groupID,
                responseAttemptID: firstAttemptID,
                responseAttemptIndex: 0
            ),
            ChatMessage(
                role: .assistant,
                content: "第二次回复",
                responseGroupID: groupID,
                responseAttemptID: secondAttemptID,
                responseAttemptIndex: 1
            )
        ]

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)

        let loadedMessages = Persistence.loadMessages(for: session.id)
        #expect(loadedMessages.count == 3)
        #expect(loadedMessages[0].id == groupID)
        #expect(loadedMessages[0].selectedResponseAttemptID == secondAttemptID)
        #expect(loadedMessages[1].responseGroupID == groupID)
        #expect(loadedMessages[1].responseAttemptID == firstAttemptID)
        #expect(loadedMessages[1].responseAttemptIndex == 0)
        #expect(loadedMessages[2].responseGroupID == groupID)
        #expect(loadedMessages[2].responseAttemptID == secondAttemptID)
        #expect(loadedMessages[2].responseAttemptIndex == 1)

        cleanup(sessions: [session])
    }

    @Test("GRDB saveMessages 仅增量更新变更行并支持位置变化")
    func testGRDBSaveMessagesUsesIncrementalWrites() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "增量写入会话", isTemporary: false)
        let messageA = ChatMessage(id: UUID(), role: .user, content: "A")
        let messageB = ChatMessage(id: UUID(), role: .assistant, content: "B")
        let messageC = ChatMessage(id: UUID(), role: .assistant, content: "C")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([messageA, messageB, messageC], for: session.id)

        let rowidBBefore = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageB.id.uuidString)'"
        )
        let rowidCBefore = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageC.id.uuidString)'"
        )

        let updatedMessageB = ChatMessage(id: messageB.id, role: .assistant, content: "B-updated")
        Persistence.saveMessages([updatedMessageB, messageC], for: session.id)

        let rowidBAfter = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageB.id.uuidString)'"
        )
        let rowidCAfter = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageC.id.uuidString)'"
        )

        #expect(rowidBBefore > 0)
        #expect(rowidCBefore > 0)
        #expect(rowidBAfter == rowidBBefore)
        #expect(rowidCAfter == rowidCBefore)
        #expect(
            sqliteCount(
                chatStoreSQLiteURL,
                sql: "SELECT COUNT(*) FROM messages WHERE session_id = '\(session.id.uuidString)'"
            ) == 2
        )

        let loaded = Persistence.loadMessages(for: session.id)
        #expect(loaded.map(\.id) == [messageB.id, messageC.id])
        #expect(loaded.map(\.content) == ["B-updated", "C"])

        cleanup(sessions: [session])
    }

    @Test("MemoryRawStore 保存时仅增量更新 SQLite 行")
    func testMemoryRawStoreUsesIncrementalWrites() throws {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        cleanup(sessions: [])

        let memoryAID = UUID()
        let memoryBID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let store = MemoryRawStore()

        let memoryA = MemoryItem(
            id: memoryAID,
            content: "记忆-A",
            embedding: [0.1, 0.2],
            createdAt: createdAt
        )
        let memoryB = MemoryItem(
            id: memoryBID,
            content: "记忆-B",
            embedding: [0.3, 0.4],
            createdAt: createdAt.addingTimeInterval(1)
        )
        try store.saveMemories([memoryA, memoryB])

        let rowidBBefore = sqliteCount(
            memoryStoreSQLiteURL,
            sql: "SELECT rowid FROM memory_items WHERE id = '\(memoryBID.uuidString)'"
        )

        let updatedMemoryA = MemoryItem(
            id: memoryAID,
            content: "记忆-A-已更新",
            embedding: [0.9, 0.8],
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )
        try store.saveMemories([updatedMemoryA, memoryB])

        let rowidBAfter = sqliteCount(
            memoryStoreSQLiteURL,
            sql: "SELECT rowid FROM memory_items WHERE id = '\(memoryBID.uuidString)'"
        )

        #expect(rowidBBefore > 0)
        #expect(rowidBAfter == rowidBBefore)
        #expect(sqliteCount(memoryStoreSQLiteURL, sql: "SELECT COUNT(*) FROM memory_items") == 2)

        let loaded = store.loadMemories()
        #expect(loaded.contains(where: { $0.id == memoryAID && $0.content == "记忆-A-已更新" }))
        #expect(loaded.contains(where: { $0.id == memoryBID && $0.content == "记忆-B" }))
    }

    @Test("GRDB 在仅收到临时会话快照时不会误删已有会话")
    func testGRDBSaveChatSessionsTemporarySnapshotFuse() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let existingSession = ChatSession(id: UUID(), name: "Existing Session", isTemporary: false)
        let existingMessages: [ChatMessage] = [
            ChatMessage(role: .user, content: "历史消息1"),
            ChatMessage(role: .assistant, content: "历史消息2")
        ]
        let temporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)

        Persistence.saveChatSessions([existingSession])
        Persistence.saveMessages(existingMessages, for: existingSession.id)

        Persistence.saveChatSessions([temporarySession])

        let sessionsAfter = Persistence.loadChatSessions()
        #expect(sessionsAfter.contains(where: { $0.id == existingSession.id }))
        #expect(!sessionsAfter.contains(where: { $0.id == temporarySession.id }))

        let messagesAfter = Persistence.loadMessages(for: existingSession.id)
        #expect(messagesAfter.map(\.content) == existingMessages.map(\.content))

        cleanup(sessions: [existingSession])
    }

    @Test("GRDB 辅助 Blob 可读写并删除")
    func testGRDBAuxiliaryBlobLifecycle() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            _ = Persistence.removeAuxiliaryBlob(forKey: "test_auxiliary_blob")
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        cleanup(sessions: [])
        let payload: [String: Int] = ["a": 1, "b": 2]
        let key = "test_auxiliary_blob"

        #expect(Persistence.saveAuxiliaryBlob(payload, forKey: key))
        #expect(Persistence.auxiliaryBlobExists(forKey: key))

        let loaded = Persistence.loadAuxiliaryBlob([String: Int].self, forKey: key)
        #expect(loaded == payload)

        #expect(Persistence.removeAuxiliaryBlob(forKey: key))
        #expect(!Persistence.auxiliaryBlobExists(forKey: key))
    }
}
