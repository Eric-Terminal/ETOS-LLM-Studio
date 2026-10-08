import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("单会话插入事务")
struct SessionInsertionTests {
    @Test("插入保留其他会话、摘要和消息，新会话元数据及标签完整回读")
    func insertionPreservesCurrentDirectory() throws {
        let fixture = try SessionInsertionFixture()
        defer { fixture.close() }
        let store = fixture.store
        let previous = ChatSession(id: UUID(), name: "其他窗口已保存")
        try store.insertChatSession(previous, messages: [ChatMessage(role: .user, content: "保留消息")])
        store.upsertConversationSessionSummary("保留摘要", for: previous.id)
        let previousMessages = store.loadMessages(for: previous.id)
        let previousRows = try fixture.records(excluding: nil)
        let folder = SessionFolder(name: "目录"), tag = SessionTag(name: "标签")
        store.saveSessionFolders([folder]); store.saveSessionTags([tag])
        let inserted = ChatSession(id: UUID(), name: "捕获请求", systemPrompt: "系统", topicPrompt: "主题",
            enhancedPrompt: "增强", preferredModelIdentifier: "模型", lorebookIDs: [UUID()], tagIDs: [tag.id],
            memoryContextIsolationEnabled: true, toolContextIsolationEnabled: true,
            globalSystemPromptIsolationEnabled: true, folderID: folder.id)
        let messages = [ChatMessage(role: .user, content: "问题"), ChatMessage(role: .assistant, content: "回答")]

        try store.insertChatSession(inserted, messages: messages)

        #expect(store.loadChatSessions() == [inserted, previous])
        #expect(store.loadMessages(for: inserted.id).map(\.content) == ["问题", "回答"])
        #expect(store.loadMessages(for: previous.id) == previousMessages)
        #expect(try fixture.records(excluding: inserted.id) == previousRows)
    }

    @Test("同一会话标识不能覆盖已有会话，临时及内嵌会话不能进入顶层目录")
    func rejectsInvalidAndDuplicateSessions() throws {
        let fixture = try SessionInsertionFixture()
        defer { fixture.close() }
        let original = ChatSession(id: UUID(), name: "原名称")
        try fixture.store.insertChatSession(original, messages: [])
        var duplicate = original
        duplicate.name = "不能覆盖"
        #expect(throws: SessionInsertionError.alreadyExists) {
            try fixture.store.insertChatSession(duplicate, messages: [ChatMessage(role: .user, content: "不能插入")])
        }
        let temporary = ChatSession(id: UUID(), name: "临时", isTemporary: true)
        let embedded = ChatSession(id: UUID(), name: "子会话", containerSessionID: original.id)
        for invalid in [temporary, embedded] {
            #expect(throws: SessionInsertionError.invalidSession) { try fixture.store.insertChatSession(invalid, messages: []) }
        }
        #expect(fixture.store.loadChatSessions() == [original])
        #expect(fixture.store.loadMessages(for: original.id).isEmpty)
    }

    @Test("第二条消息失败时回滚目录排序、新会话和第一条消息")
    func messageFailureRollsBackEntireInsertion() throws {
        let fixture = try SessionInsertionFixture()
        defer { fixture.close() }
        let existing = ChatSession(id: UUID(), name: "原会话")
        try fixture.store.insertChatSession(existing, messages: [ChatMessage(role: .user, content: "原消息")])
        try fixture.store.dbPool.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_fixture_message BEFORE INSERT ON messages WHEN NEW.content = '拒绝写入' BEGIN SELECT RAISE(ABORT, '测试写入失败'); END")
        }
        let inserted = ChatSession(id: UUID(), name: "不能部分保存")
        #expect(throws: (any Error).self) {
            try fixture.store.insertChatSession(inserted, messages: [
                ChatMessage(role: .user, content: "第一条"), ChatMessage(role: .assistant, content: "拒绝写入")
            ])
        }
        #expect(fixture.store.loadChatSessions() == [existing])
        #expect(fixture.store.loadMessages(for: inserted.id).isEmpty)
        #expect(fixture.store.loadMessages(for: existing.id).map(\.content) == ["原消息"])
        let sortIndices = try fixture.store.dbPool.read { try Int.fetchAll($0, sql: "SELECT sort_index FROM sessions") }
        #expect(sortIndices == [0])
    }

    @Test("重复消息标识重新分配，不能夺走其他会话的消息或相互覆盖")
    func messageIdentifiersRemainUnique() throws {
        let fixture = try SessionInsertionFixture()
        defer { fixture.close() }
        let existing = ChatSession(id: UUID(), name: "原会话"), inserted = ChatSession(id: UUID(), name: "新会话")
        let foreignID = UUID(), repeatedID = UUID()
        try fixture.store.insertChatSession(existing, messages: [ChatMessage(id: foreignID, role: .user, content: "原消息")])
        try fixture.store.insertChatSession(inserted, messages: [
            ChatMessage(id: foreignID, role: .user, content: "跨会话重复"),
            ChatMessage(id: repeatedID, role: .assistant, content: "首次"),
            ChatMessage(id: repeatedID, role: .assistant, content: "同会话重复")
        ])
        let messages = fixture.store.loadMessages(for: inserted.id)
        #expect(messages.map(\.content) == ["跨会话重复", "首次", "同会话重复"])
        #expect(Set(messages.map(\.id)).count == 3)
        #expect(!messages.contains { $0.id == foreignID })
        #expect(fixture.store.loadMessages(for: existing.id).map(\.id) == [foreignID])
    }
}

private struct SessionInsertionFixture {
    let directory: URL
    let store: PersistenceGRDBStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-session-insert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceGRDBStore(chatsDirectory: directory)
    }

    func close() {
        try? store.dbPool.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func records(excluding id: UUID?) throws -> [[String: DatabaseValue]] {
        try store.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE id != ? ORDER BY id", arguments: [id?.uuidString ?? ""])
                .map { Dictionary(uniqueKeysWithValues: $0.filter { $0.0 != "sort_index" }) }
        }
    }
}
