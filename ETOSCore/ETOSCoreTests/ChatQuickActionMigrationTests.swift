import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ChatQuickActionMigrationTests {
    @Test("升级只补入一次模型入口，保留原选择及顺序，之后尊重用户隐藏", arguments: [
        "temporaryChat,browser,settings", "browser,settings", "browser,modelPicker,settings", "unknown", ""
    ])
    func modelEntryMigrationIsOneTime(original: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceAuxiliaryGRDBStore(
            databaseURL: directory.appendingPathComponent("config-store.sqlite"),
            loggerCategory: "快捷功能迁移测试", schedulesMaintenance: false
        )
        try store.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, updated_at) VALUES (?, ?, ?)",
                arguments: ["ui.chatQuickActionIDs", original, 1.0])
            // 使用临时库回到该迁移之前，不接触设备的真实配置。
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v25_configurable_chat_model_picker'")
        }
        try store.migrateSchemaIfNeeded()
        let migrated = try #require(store.read {
            try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'ui.chatQuickActionIDs'")
        })
        switch original {
        case "temporaryChat,browser,settings":
            #expect(migrated == "temporaryChat,modelPicker,browser,settings")
        case "browser,settings":
            #expect(migrated == "modelPicker,browser,settings")
        default:
            #expect(migrated == original)
        }
        #expect(ChatQuickActionSelection.decode(migrated).contains(.modelPicker))

        try store.write {
            try $0.execute(sql: "UPDATE app_config SET value_text = 'browser,settings' WHERE key = 'ui.chatQuickActionIDs'")
        }
        try store.migrateSchemaIfNeeded()
        let hidden = try store.read {
            try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'ui.chatQuickActionIDs'")
        }
        #expect(hidden == "browser,settings")
    }
}
