import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("发送会话排序持久化", .serialized)
struct ChatSessionOrderingPersistenceTests {
    @Test("提升只改变排序，完整会话字段、标签、摘要与消息保持原值")
    func promotionPreservesStoredContent() async throws {
        let fixture = try SessionOrderingFixture()
        defer { fixture.close() }
        let store = fixture.store
        let folder = SessionFolder(name: "保留目录")
        let tag = SessionTag(name: "保留标签")
        store.saveSessionFolders([folder])
        store.saveSessionTags([tag])
        let a = ChatSession(id: UUID(), name: "A")
        let b = ChatSession(
            id: UUID(), name: "B", systemPrompt: "系统", topicPrompt: "主题",
            enhancedPrompt: "增强", preferredModelIdentifier: "模型",
            lorebookIDs: [UUID()], tagIDs: [tag.id], memoryContextIsolationEnabled: true,
            toolContextIsolationEnabled: true, globalSystemPromptIsolationEnabled: true,
            folderID: folder.id
        )
        let c = ChatSession(id: UUID(), name: "C")
        store.saveChatSessions([a, b, c])
        _ = try store.appendConversationMessageAtomically(ChatMessage(role: .user, content: "保留消息"), to: b.id)
        store.upsertConversationSessionSummary("保留摘要", for: b.id)
        let records = try fixture.sessionRecordsIgnoringOrder()
        let tags = try await store.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM session_tag_assignments ORDER BY session_id, sort_index")
                .map { Dictionary(uniqueKeysWithValues: $0) }
        }
        let messages = store.loadMessages(for: b.id)

        #expect(try await promote(b.id, database: store.dbPool))
        #expect(store.loadChatSessions().map(\.id) == [b.id, a.id, c.id])
        #expect(try fixture.sessionRecordsIgnoringOrder() == records)
        let storedTags = try await store.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM session_tag_assignments ORDER BY session_id, sort_index")
                .map { Dictionary(uniqueKeysWithValues: $0) }
        }
        #expect(storedTags == tags)
        #expect(store.loadMessages(for: b.id) == messages)
        let syncMetadataCount = try await store.dbPool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_database_metadata")
        }
        #expect(syncMetadataCount == 1)
    }

    @Test("旧调用者只携带 ID，后来的新增会话和元数据编辑不会被旧快照覆盖")
    func promotionUsesCurrentDatabaseRows() async throws {
        let fixture = try SessionOrderingFixture()
        defer { fixture.close() }
        let a = ChatSession(id: UUID(), name: "A")
        var b = ChatSession(id: UUID(), name: "B旧名称")
        fixture.store.saveChatSessions([a, b])
        let capturedID = b.id
        b.name = "B新名称"
        b.systemPrompt = "编辑后的提示词"
        let inserted = ChatSession(id: UUID(), name: "并发新增")
        fixture.store.saveChatSessions([inserted, a, b])
        let records = try fixture.sessionRecordsIgnoringOrder()

        #expect(try await promote(capturedID, database: fixture.store.dbPool))
        #expect(fixture.store.loadChatSessions().map(\.id) == [b.id, inserted.id, a.id])
        #expect(try fixture.sessionRecordsIgnoringOrder() == records)
    }

    @Test("已在顶部、已删除、临时与内嵌会话不写排序也不复活记录")
    func excludedOrMissingSessionsAreNoOps() async throws {
        let fixture = try SessionOrderingFixture()
        defer { fixture.close() }
        let a = ChatSession(id: UUID(), name: "A")
        let b = ChatSession(id: UUID(), name: "内嵌")
        let deleted = ChatSession(id: UUID(), name: "已删除")
        fixture.store.saveChatSessions([a, b, deleted])
        let temporaryID = UUID()
        _ = try fixture.store.appendConversationMessageAtomically(ChatMessage(role: .user, content: "临时"), to: temporaryID)
        try await fixture.store.dbPool.write {
            try $0.execute(sql: "UPDATE sessions SET container_session_id = ? WHERE id = ?", arguments: [a.id.uuidString, b.id.uuidString])
            try $0.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [deleted.id.uuidString])
        }
        let records = try fixture.sessionRecordsIgnoringOrder()
        for id in [a.id, deleted.id, temporaryID, b.id] {
            #expect(try await promote(id, database: fixture.store.dbPool) == false)
        }
        #expect(try fixture.sessionRecordsIgnoringOrder() == records)
        #expect(fixture.store.loadChatSessions().map(\.id) == [a.id])
    }

    @Test("连续提升与随后全量保存按同一 writer 的登记顺序提交")
    func promotionRegistrationPreservesWriteOrder() async throws {
        let fixture = try SessionOrderingFixture()
        defer { fixture.close() }
        let a = ChatSession(id: UUID(), name: "A")
        let b = ChatSession(id: UUID(), name: "B")
        let c = ChatSession(id: UUID(), name: "C")
        fixture.store.saveChatSessions([a, b, c])
        let results = AsyncStream<Result<Bool, Error>>.makeStream()
        for id in [b.id, c.id] {
            PersistenceGRDBStore.enqueueChatSessionPromotion(id, database: fixture.store.dbPool) {
                results.continuation.yield($0)
            }
        }
        let intermediate = AsyncStream<[String]>.makeStream()
        fixture.store.dbPool.asyncWriteWithoutTransaction { db in
            do {
                intermediate.continuation.yield(try String.fetchAll(db, sql: "SELECT id FROM sessions ORDER BY sort_index"))
            } catch { Issue.record(error) }
            intermediate.continuation.finish()
        }
        // 同步保存也使用同一 writer，必须排在上面两次提升与中间观测之后。
        fixture.store.saveChatSessions([a, c, b])
        results.continuation.finish()
        var changed = 0
        for await result in results.stream { if try result.get() { changed += 1 } }
        var observed: [String]?
        for await ids in intermediate.stream { observed = ids }
        #expect(changed == 2)
        #expect(observed == [c.id.uuidString, b.id.uuidString, a.id.uuidString])
        #expect(fixture.store.loadChatSessions().map(\.id) == [a.id, c.id, b.id])
    }

    @MainActor
    @Test("writer 被占用时登记立即返回，真实排序与回执在后台完成")
    func registrationDoesNotWaitForBusyWriter() async throws {
        let fixture = try SessionOrderingFixture()
        defer { fixture.close() }
        let a = ChatSession(id: UUID(), name: "A")
        let b = ChatSession(id: UUID(), name: "B")
        fixture.store.saveChatSessions([a, b])
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        fixture.store.dbPool.asyncWriteWithoutTransaction { _ in
            entered.continuation.yield(())
            entered.continuation.finish()
            // 仅防错误实现死锁；正确实现由主线程登记返回后立即释放，不靠定时 sleep。
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        for await _ in entered.stream { break }
        let completed = AsyncStream<Result<Bool, Error>>.makeStream()
        PersistenceGRDBStore.enqueueChatSessionPromotion(b.id, database: fixture.store.dbPool) {
            #expect(!Thread.isMainThread)
            completed.continuation.yield($0)
            completed.continuation.finish()
        }
        release.signal()
        var result: Bool?
        for await value in completed.stream { result = try value.get() }
        #expect(result == true)
        #expect(fixture.store.loadChatSessions().map(\.id) == [b.id, a.id])
    }

    @Test("已关闭的旧写入句柄失败，不重开或误写另一隔离库")
    func closedDatabaseDoesNotRetargetPromotion() async throws {
        let original = try SessionOrderingFixture()
        defer { original.close() }
        let replacement = try SessionOrderingFixture()
        defer { replacement.close() }
        let a = ChatSession(id: UUID(), name: "A")
        let b = ChatSession(id: UUID(), name: "B")
        original.store.saveChatSessions([a, b])
        replacement.store.saveChatSessions([a, b])
        try original.store.dbPool.close()
        do {
            _ = try await promote(b.id, database: original.store.dbPool)
            Issue.record("旧连接已关闭，不能继续排序或重新解析当前库")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(replacement.store.loadChatSessions().map(\.id) == [a.id, b.id])
    }

    private func promote(_ id: UUID, database: DatabasePool) async throws -> Bool {
        let result = await withCheckedContinuation { continuation in
            PersistenceGRDBStore.enqueueChatSessionPromotion(id, database: database) {
                continuation.resume(returning: $0)
            }
        }
        return try result.get()
    }
}

private struct SessionOrderingFixture {
    let directory: URL
    let store: PersistenceGRDBStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-session-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceGRDBStore(chatsDirectory: directory)
    }

    func close() {
        try? store.dbPool.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func sessionRecordsIgnoringOrder() throws -> [[String: DatabaseValue]] {
        try store.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions ORDER BY id").map {
                Dictionary(uniqueKeysWithValues: $0.filter { $0.0 != "sort_index" })
            }
        }
    }
}
