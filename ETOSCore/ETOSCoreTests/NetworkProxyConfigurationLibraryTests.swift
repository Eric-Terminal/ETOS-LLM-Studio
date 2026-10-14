import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct NetworkProxyConfigurationLibraryTests {
    @Test("空数据库及旧的无效类型和端口使用既有默认值")
    func legacyDefaults() throws {
        let db = try database()
        #expect(try db.read { try NetworkProxyConfigurationStore.load($0) } == NetworkProxyConfiguration())
        try db.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES ('networkProxy.global.type', 'unknown', 'text', 0)")
            try db.execute(sql: "INSERT INTO app_config (key, value_integer, type_hint, updated_at) VALUES ('networkProxy.global.port', 70000, 'integer', 0)")
        }
        let value = try db.read { try NetworkProxyConfigurationStore.load($0) }
        #expect(value.type == .http); #expect(value.port == 8080)
    }

    @Test("保存沿用六个数据库键并保留关闭状态下的凭据和空白")
    func compatibleRoundTrip() throws {
        let db = try database()
        let value = NetworkProxyConfiguration(isEnabled: false, type: .socks5, host: " proxy.local ", port: 1080, username: " user ", password: " secret \n")
        try db.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES ('unrelated', 'keep', 'text', 0)")
            try NetworkProxyConfigurationStore.save(value, original: NetworkProxyConfiguration(), in: db)
        }
        #expect(try db.read { try NetworkProxyConfigurationStore.load($0) } == value)
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'unrelated'") } == "keep")
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config WHERE key LIKE 'networkProxy.global.%'") } == 6)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT updated_at) FROM app_config WHERE key LIKE 'networkProxy.global.%'") } == 1)
    }

    @Test("只改变密码也会拒绝旧窗口的整组覆盖")
    func staleCredentials() throws {
        let db = try database()
        let original = NetworkProxyConfiguration()
        var updated = original; updated.password = "新的秘密"
        try db.write { try NetworkProxyConfigurationStore.save(updated, original: original, in: $0) }
        var stale = original; stale.host = "other.local"
        #expect(throws: NetworkProxyConfigurationError.self) {
            try db.write { try NetworkProxyConfigurationStore.save(stale, original: original, in: $0) }
        }
        #expect(try db.read { try NetworkProxyConfigurationStore.load($0) } == updated)
    }

    @Test("最后一个字段失败会回滚启用状态、主机及凭据的全部更改")
    func atomicRollback() throws {
        let db = try database()
        try db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_password BEFORE INSERT ON app_config WHEN NEW.key = 'networkProxy.global.password' BEGIN SELECT RAISE(ABORT, '测试拒绝'); END")
        }
        let value = NetworkProxyConfiguration(isEnabled: true, type: .socks5, host: "proxy.local", port: 1080, username: "user", password: "secret")
        #expect(throws: DatabaseError.self) {
            try db.write { try NetworkProxyConfigurationStore.save(value, original: NetworkProxyConfiguration(), in: $0) }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config") } == 0)
    }

    @Test("主机与端口边界验证失败不写入，关闭代理允许保留空主机")
    func validation() throws {
        let db = try database()
        for value in [NetworkProxyConfiguration(isEnabled: true, host: " \n"), NetworkProxyConfiguration(port: 0), NetworkProxyConfiguration(port: 65536)] {
            #expect(throws: NetworkProxyConfigurationError.self) {
                try db.write { try NetworkProxyConfigurationStore.save(value, original: NetworkProxyConfiguration(), in: $0) }
            }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config") } == 0)
        try NetworkProxyConfigurationLibrary.validate(NetworkProxyConfiguration(isEnabled: false, port: 1))
        try NetworkProxyConfigurationLibrary.validate(NetworkProxyConfiguration(isEnabled: true, host: "::1", port: 65535))
    }

    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER, type_hint TEXT NOT NULL, updated_at REAL NOT NULL)")
        }
        return db
    }
}
