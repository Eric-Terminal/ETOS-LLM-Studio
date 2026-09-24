import Foundation
import GRDB
import Testing
@testable import ETOSCore

extension PersistenceTests {
    @Test("文件替换期间后台读取只能拿到已关闭的旧连接，不重开数据库", .timeLimit(.minutes(1)))
    func snapshotReplacementDoesNotReopenStores() throws {
        try #require(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        let originalChat = try #require(Persistence.activeGRDBStore())
        let originalConfig = try #require(Persistence.activeAuxiliaryStore(kind: .config))
        let originalMemory = try #require(Persistence.activeAuxiliaryStore(kind: .memory))
        let chatID = ObjectIdentifier(originalChat)
        let configID = ObjectIdentifier(originalConfig)
        let memoryID = ObjectIdentifier(originalMemory)

        try Persistence.withClosedStoresForDatabaseReplacement {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { completed.signal() }
                #expect(Persistence.activeGRDBStore().map(ObjectIdentifier.init) == chatID)
                #expect(Persistence.activeAuxiliaryStore(kind: .config).map(ObjectIdentifier.init) == configID)
                #expect(Persistence.activeAuxiliaryStore(kind: .memory).map(ObjectIdentifier.init) == memoryID)
                #expect(throws: DatabaseError.self) {
                    try Persistence.activeGRDBStore()?.dbPool.read { db in
                        try Int.fetchOne(db, sql: "SELECT 1")
                    }
                }
                #expect(throws: DatabaseError.self) {
                    try Persistence.activeAuxiliaryStore(kind: .config)?.dbPool.read { db in
                        try Int.fetchOne(db, sql: "SELECT 1")
                    }
                }
            }
            // 后台请求必须在替换区间内完成，不能靠等待整个恢复结束来避免崩溃。
            #expect(completed.wait(timeout: .now() + 5) == .success)
        }

        let reopenedChat = try #require(Persistence.activeGRDBStore())
        let reopenedConfig = try #require(Persistence.activeAuxiliaryStore(kind: .config))
        let reopenedMemory = try #require(Persistence.activeAuxiliaryStore(kind: .memory))
        #expect(reopenedChat !== originalChat)
        #expect(reopenedConfig !== originalConfig)
        #expect(reopenedMemory !== originalMemory)
        #expect(throws: DatabaseError.self) {
            try originalChat.dbPool.read { try Int.fetchOne($0, sql: "SELECT 1") }
        }
    }

    @Test("恢复失败后解除连接保护，未初始化的分库不会在替换期间创建")
    func snapshotReplacementFailureReleasesProtection() throws {
        enum ExpectedFailure: Error { case interrupted }
        try #require(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        try Persistence.closeActiveStoresForSnapshotRestore()
        #expect(throws: ExpectedFailure.self) {
            try Persistence.withClosedStoresForDatabaseReplacement {
                #expect(Persistence.activeGRDBStore() == nil)
                #expect(Persistence.activeAuxiliaryStore(kind: .config) == nil)
                #expect(Persistence.activeAuxiliaryStore(kind: .memory) == nil)
                throw ExpectedFailure.interrupted
            }
        }
        let reopened = try #require(Persistence.activeGRDBStore())
        #expect(try reopened.dbPool.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
        #expect(Persistence.activeAuxiliaryStore(kind: .config) != nil)
        #expect(Persistence.activeAuxiliaryStore(kind: .memory) != nil)
    }

    @Test("先恢复数据库备份再恢复完整备份，聊天内容和全文索引分别对应当前备份")
    func consecutiveDatabaseAndFullSnapshotRestores() throws {
        cleanup(sessions: [])
        let first = ChatSession(id: UUID(), name: "数据库备份会话", isTemporary: false)
        let second = ChatSession(id: UUID(), name: "完整备份会话", isTemporary: false)
        defer { cleanup(sessions: [first, second]) }

        Persistence.saveChatSessions([first])
        Persistence.saveMessages([ChatMessage(role: .user, content: "第一份备份")], for: first.id)
        let databaseSnapshot = try SnapshotBuilder.buildSnapshotResult(kind: .database)
        defer { removeIfExists(databaseSnapshot.fileURL) }

        Persistence.saveChatSessions([second])
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "第二份备份")], for: second.id)
        let fullSnapshot = try SnapshotBuilder.buildSnapshotResult(kind: .full)
        defer { removeIfExists(fullSnapshot.fileURL) }

        for (snapshot, session, content) in [
            (databaseSnapshot, first, "第一份备份"),
            (fullSnapshot, second, "第二份备份")
        ] {
            try SnapshotRestoreService.restorePlainSnapshot(from: snapshot.fileURL)
            #expect(Persistence.loadMessages(for: session.id).map(\.content) == [content])
            let store = try #require(Persistence.activeGRDBStore())
            let indexed = try store.dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT content FROM messages_fts WHERE session_id = ?", arguments: [session.id.uuidString])
            }
            #expect(indexed == content)
            #expect(try store.dbPool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") } == "ok")
        }
    }
}
