import Foundation
import GRDB
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @MainActor
    @Test("界面删除在后台执行数据库操作，连续删除保留其他会话与选择", .timeLimit(.minutes(1)))
    func asynchronousSessionDeletionKeepsOtherSessions() async throws {
        let first = chatService.createSavedSession(name: "删除一")
        let second = chatService.createSavedSession(name: "删除二")
        let retained = chatService.createSavedSession(name: "保留会话")
        defer { chatService.deleteSessions([first, second, retained]) }
        let store = try #require(Persistence.activeGRDBStore())
        try await store.dbPool.write { db in
            db.add(function: DatabaseFunction("deletion_is_main_thread", argumentCount: 0, pure: false) { _ in
                Thread.isMainThread
            })
            try db.execute(sql: """
                CREATE TEMP TABLE deletion_thread_audit (was_main_thread INTEGER NOT NULL);
                CREATE TEMP TRIGGER audit_session_deletion BEFORE DELETE ON sessions BEGIN
                    INSERT INTO deletion_thread_audit VALUES (deletion_is_main_thread());
                END;
                """)
        }
        defer {
            try? store.dbPool.write { db in
                try db.execute(sql: "DROP TRIGGER audit_session_deletion; DROP TABLE deletion_thread_audit")
            }
        }

        async let deletingFirst: Void = chatService.deleteSessionsAsync([first])
        async let deletingSecond: Void = chatService.deleteSessionsAsync([second])
        _ = await (deletingFirst, deletingSecond)

        #expect(chatService.chatSessionsSubject.value.filter { !$0.isTemporary }.map(\.id) == [retained.id])
        #expect(chatService.currentSessionSubject.value?.id == retained.id)
        #expect(Persistence.loadChatSessions().map(\.id) == [retained.id])
        // TEMP 表与 SQL 函数属于 writer 连接，不能从池中的其他 reader 查询。
        let mainThreadFlags = try await store.dbPool.write { db in
            try Int.fetchAll(db, sql: "SELECT was_main_thread FROM deletion_thread_audit")
        }
        #expect(mainThreadFlags == [0, 0])
    }

    @MainActor
    @Test("删除等待数据库时主线程仍可处理选择，完成后不覆盖较新的会话元数据", .timeLimit(.minutes(1)))
    func deletionDoesNotReplayOldSessionSnapshot() async throws {
        let retained = chatService.createSavedSession(name: "原名称")
        let deleted = chatService.createSavedSession(name: "删除目标")
        defer { chatService.deleteSessions([retained, deleted]) }
        let store = try #require(Persistence.activeGRDBStore())
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); signal.finish() }
        try await store.dbPool.write { db in
            db.add(function: DatabaseFunction("wait_for_deletion_ui", argumentCount: 0) { _ in
                signal.yield()
                // 旧实现在主线程等待时会超时并记录失败，避免回归测试永久挂起。
                return release.wait(timeout: .now() + 5) == .success
            })
            try db.execute(sql: """
                CREATE TEMP TABLE deletion_ui_audit (ui_responded INTEGER NOT NULL);
                CREATE TEMP TRIGGER wait_for_session_deletion BEFORE DELETE ON sessions BEGIN
                    INSERT INTO deletion_ui_audit VALUES (wait_for_deletion_ui());
                END;
                """)
        }
        defer {
            try? store.dbPool.write { db in
                try db.execute(sql: "DROP TRIGGER wait_for_session_deletion; DROP TABLE deletion_ui_audit")
            }
        }

        let deleting = Task { await chatService.deleteSessionsAsync([deleted]) }
        for await _ in entered { break }
        var renamed = retained
        renamed.name = "删除期间的新名称"
        chatService.chatSessionsSubject.send([deleted, renamed])
        chatService.currentSessionSubject.send(renamed)
        release.signal()
        await deleting.value

        #expect(chatService.chatSessionsSubject.value == [renamed])
        #expect(chatService.currentSessionSubject.value == renamed)
        #expect(Persistence.loadChatSessions() == [renamed])
        let responded = try await store.dbPool.write { db in
            try Int.fetchAll(db, sql: "SELECT ui_responded FROM deletion_ui_audit")
        }
        #expect(responded == [1])
    }
}
