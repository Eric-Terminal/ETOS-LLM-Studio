import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct BrowserSessionPreferencesTests {
    @Test("偏好写入只修改目标会话，并拒绝覆盖其他页面的新值")
    func compareAndSavePreservesOtherSessions() throws {
        let db = try database(), first = UUID(), second = UUID()
        try db.write { db in
            try db.execute(sql: "INSERT INTO sessions (id) VALUES (?), (?)", arguments: [first.uuidString, second.uuidString])
            try BrowserSessionPreferencesStore.save(.persistentShared, expected: .sessionIsolated, sessionID: first, in: db)
            try BrowserSessionPreferencesStore.save(.persistentShared, expected: .sessionIsolated, sessionID: second, in: db)
        }
        #expect(throws: BrowserSessionPreferencesError.self) {
            try db.write { try BrowserSessionPreferencesStore.save(.sessionIsolated, expected: .sessionIsolated, sessionID: first, in: $0) }
        }
        try db.write { try BrowserSessionPreferencesStore.save(.sessionIsolated, expected: .persistentShared, sessionID: first, in: $0) }
        let values = try db.read { try Row.fetchAll($0, sql: "SELECT session_id, data_profile FROM browser_agent_session_preferences") }
        let profiles = Dictionary(uniqueKeysWithValues: values.map { ($0["session_id"] as String, $0["data_profile"] as String) })
        #expect(profiles[first.uuidString] == "session_isolated")
        #expect(profiles[second.uuidString] == "persistent_shared")
    }

    @Test("删除或临时会话不能因为设置偏好被重新创建")
    func missingSessionIsNotInserted() throws {
        let db = try database()
        #expect(throws: BrowserSessionPreferencesError.self) {
            try db.write { try BrowserSessionPreferencesStore.save(.persistentShared, expected: .sessionIsolated, sessionID: UUID(), in: $0) }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sessions") } == 0)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM browser_agent_session_preferences") } == 0)
    }

    @Test("数据库拒绝更新时原偏好保持完整")
    func failedWriteKeepsProfile() throws {
        let db = try database(), session = UUID()
        try db.write { db in
            try db.execute(sql: "INSERT INTO sessions (id) VALUES (?)", arguments: [session.uuidString])
            try BrowserSessionPreferencesStore.save(.persistentShared, expected: .sessionIsolated, sessionID: session, in: db)
            try db.execute(sql: "CREATE TRIGGER reject_update BEFORE UPDATE ON browser_agent_session_preferences BEGIN SELECT RAISE(ABORT, '拒绝测试更新'); END")
        }
        #expect(throws: DatabaseError.self) {
            try db.write { try BrowserSessionPreferencesStore.save(.sessionIsolated, expected: .persistentShared, sessionID: session, in: $0) }
        }
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT data_profile FROM browser_agent_session_preferences") } == "persistent_shared")
    }

    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { try $0.execute(sql: """
            CREATE TABLE sessions (id TEXT PRIMARY KEY);
            CREATE TABLE browser_agent_session_preferences (
                session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                data_profile TEXT NOT NULL, updated_at REAL NOT NULL
            );
            """) }
        return db
    }
}
