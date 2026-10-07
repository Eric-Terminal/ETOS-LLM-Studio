import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ToolConfigurationPersistenceTests {
    @Test("默认工具迁移只启用首次出现的项目，尊重已知关闭状态")
    func defaultMigrationRespectsDisabledTools() {
        let defaults: Set<String> = ["show_widget", "ask_user_input", "get_system_time"]
        let ids = AppToolInitialState.migratedEnabledIDs(stored: ["ask_user_input", "unknown"],
                                                        knownDefaults: ["show_widget", "ask_user_input"], defaults: defaults)
        #expect(ids == ["ask_user_input", "get_system_time"])
        #expect(AppToolInitialState.migratedEnabledIDs(stored: nil, knownDefaults: defaults, defaults: defaults) == defaults)
        #expect(AppToolInitialState.migratedEnabledIDs(stored: [], knownDefaults: defaults, defaults: defaults).isEmpty)
    }

    @Test("内置工具增量保存保留其他 ID、未知 ID 与独立审批配置")
    func builtInWritesPreserveOtherSettings() throws {
        let db = try fixture()
        try db.write { database in
            try put("appTools.enabledToolIDs", text: "[\"future_tool\",\"show_widget\",\"ask_user_input\",\"echo_text\"]", in: database)
            try put("appTools.toolApprovalPolicies", text: "{\"future_tool\":\"deny\"}", in: database)
            _ = try AppToolSettingsWorker.setEnabled(false, kind: .showWidget, in: database)
            _ = try AppToolSettingsWorker.setEnabled(false, kind: .askUserInput, in: database)
            let ids = try AppToolSettingsWorker.setEnabled(true, kind: .getSystemTime, in: database)
            #expect(ids == ["future_tool", "echo_text", "get_system_time"])
            #expect(try String.fetchOne(database, sql: "SELECT value_text FROM app_config WHERE key = 'appTools.toolApprovalPolicies'") == "{\"future_tool\":\"deny\"}")
        }
    }

    @Test("损坏的旧开关数据和非内置工具请求不能覆盖数据库")
    func rejectsMalformedAndUnsupportedWrites() throws {
        let db = try fixture()
        try db.write { try put("appTools.enabledToolIDs", text: "broken-json", in: $0) }
        #expect(throws: AppToolSettingsWriteError.self) {
            try db.write { try AppToolSettingsWorker.setEnabled(true, kind: .getSystemTime, in: $0) }
        }
        #expect(throws: AppToolSettingsWriteError.self) {
            try db.write { try AppToolSettingsWorker.setEnabled(true, kind: .echoText, in: $0) }
        }
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'appTools.enabledToolIDs'") } == "broken-json")
    }

    @Test("内置工具写入失败不删除已保存开关")
    func builtInFailurePreservesValues() throws {
        let db = try fixture()
        try db.write {
            try put("appTools.enabledToolIDs", text: "[\"ask_user_input\"]", in: $0)
            try $0.execute(sql: "CREATE TRIGGER reject_write BEFORE UPDATE ON app_config BEGIN SELECT RAISE(ABORT, '拒绝测试写入'); END")
        }
        #expect(throws: DatabaseError.self) {
            try db.write { try AppToolSettingsWorker.setEnabled(true, kind: .showWidget, in: $0) }
        }
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config") } == "[\"ask_user_input\"]")
    }

    @Test("审批组合保存保持禁用列表，单工具修改保留其他项目")
    func approvalChangesPreserveIndependentFields() throws {
        let db = try fixture()
        let result = try db.write { database in
            _ = try ToolApprovalSettingsWorker.update(.disableForTool(" first ", true), in: database)
            _ = try ToolApprovalSettingsWorker.update(.disableForTool("second", true), in: database)
            _ = try ToolApprovalSettingsWorker.update(.automation(enabled: true, countdown: 12), in: database)
            return try ToolApprovalSettingsWorker.update(.disableForTool("first", false), in: database)
        }
        #expect(result.enabled && result.countdown == 12)
        #expect(result.disabledTools == ["second"])
        let cleared = try db.write { try ToolApprovalSettingsWorker.update(.clearDisabledTools, in: $0) }
        #expect(cleared.disabledTools.isEmpty && cleared.enabled && cleared.countdown == 12)
    }

    @Test("审批组合写入第二个字段失败时，第一个字段也回滚")
    func approvalBatchFailureRollsBack() throws {
        let db = try fixture()
        try db.write { database in
            _ = try ToolApprovalSettingsWorker.update(.automation(enabled: false, countdown: 8), in: database)
            try database.execute(sql: """
                CREATE TRIGGER reject_enabled BEFORE UPDATE ON app_config
                WHEN NEW.key = 'tool.permission.autoApproveEnabled'
                BEGIN SELECT RAISE(ABORT, '拒绝测试写入'); END
                """)
        }
        #expect(throws: DatabaseError.self) {
            try db.write { try ToolApprovalSettingsWorker.update(.automation(enabled: true, countdown: 3), in: $0) }
        }
        let restored = try db.read { try ToolApprovalSettingsWorker.load(from: $0) }
        #expect(!restored.enabled && restored.countdown == 8)
    }

    @Test("审批输入范围与旧配置规范化保持一致")
    func validatesCountdownAndLegacyLists() throws {
        let legacy = ToolApprovalPreferences(enabled: true, countdown: 0, disabledTools: [" a ", "a", "", " b"])
        #expect(legacy.countdown == 8 && legacy.disabledTools == ["a", "b"])
        #expect(ToolApprovalPreferences(enabled: false, countdown: 100, disabledTools: []).countdown == 30)
        let db = try fixture()
        for value in [0, -1, 31] {
            #expect(throws: ToolApprovalSettingsError.self) {
                try db.write { try ToolApprovalSettingsWorker.update(.automation(enabled: true, countdown: value), in: $0) }
            }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM app_config") } == 0)
    }

    private func fixture() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { try $0.execute(sql: """
            CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL,
                                     value_integer INTEGER, type_hint TEXT, updated_at REAL)
            """) }
        return db
    }

    private func put(_ key: String, text: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO app_config VALUES (?, ?, NULL, NULL, 'text', 0)", arguments: [key, text])
    }
}
