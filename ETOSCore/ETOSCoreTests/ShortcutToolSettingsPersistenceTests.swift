import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ShortcutToolSettingsPersistenceTests {
    @Test("后台准备排序、显示名称别名和兼容路由，不丢失扩展字段")
    func preparedStatePreservesRouting() {
        let first = ShortcutToolDefinition(name: "z", metadata: ["displayName": .string("Alpha"), "future": .int(7)])
        let second = ShortcutToolDefinition(name: "Beta", isEnabled: true)
        let state = ShortcutToolInitialState(chatToolsEnabled: false, tools: [second, first])
        #expect(!state.chatToolsEnabled)
        #expect(state.tools.map(\.id) == [first.id, second.id])
        #expect(state.routes[ShortcutToolNaming.alias(for: first)] == first)
        #expect(state.routes["shortcut://\(second.id.uuidString)"] == second)
        #expect(state.tools.first?.metadata["future"] == .int(7))
    }

    @Test("单项设置保存保留其他工具、元数据和未修改的空描述")
    func savesOnlyEditableFields() throws {
        let database = try fixture()
        let original = try database.read { try #require(ShortcutToolStore.loadTools(from: $0).first { $0.name == "One" }) }
        let other = try database.read { try #require(ShortcutToolStore.loadTools(from: $0).first { $0.name == "Two" }) }
        #expect(original.metadata["future"] == .string("preserve"))
        let tools = try database.write {
            try #require(ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: true, runMode: .bridge, userDescription: "", in: $0))
        }
        let saved = try #require(tools.first { $0.id == original.id })
        #expect(saved.isEnabled)
        #expect(saved.runModeHint == .bridge)
        #expect(saved.userDescription == nil)
        #expect(saved.generatedDescription == original.generatedDescription)
        #expect(saved.metadata == original.metadata)
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.lastImportedAt == original.lastImportedAt)
        #expect(tools.first { $0.id == other.id } == other)
    }

    @Test("过期或已删除的原记录不能被详情草稿覆盖或复活")
    func rejectsStaleAndDeletedOriginals() throws {
        let database = try fixture()
        let original = try database.read { try #require(ShortcutToolStore.loadTools(from: $0).first) }
        _ = try database.write {
            try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: true, runMode: .bridge, userDescription: "new", in: $0)
        }
        let stale = try database.write {
            try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: false, runMode: .direct, userDescription: "old", in: $0)
        }
        #expect(stale == nil)
        try database.write { try $0.execute(sql: "DELETE FROM shortcut_tools WHERE id = ?", arguments: [original.id.uuidString]) }
        let deleted = try database.write {
            try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: true, runMode: .direct, userDescription: "resurrect", in: $0)
        }
        #expect(deleted == nil)
    }

    @Test("数据库更新失败时事务回滚，原记录与其他工具保持不变")
    func updateFailureRollsBack() throws {
        let database = try fixture()
        let originals = try database.read { try ShortcutToolStore.loadTools(from: $0) }
        let original = try #require(originals.first)
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_settings BEFORE UPDATE ON shortcut_tools
                BEGIN SELECT RAISE(ABORT, '拒绝测试写入'); END
                """)
        }
        #expect(throws: DatabaseError.self) {
            try database.write {
                try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: true, runMode: .bridge, userDescription: "new", in: $0)
            }
        }
        #expect(try database.read { try ShortcutToolStore.loadTools(from: $0) } == originals)
    }

    private func fixture() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE shortcut_tools (
                    id TEXT PRIMARY KEY, name TEXT, external_id TEXT, source TEXT, run_mode_hint TEXT,
                    is_enabled INTEGER, user_description TEXT, generated_description TEXT,
                    created_at REAL, updated_at REAL, last_imported_at REAL
                );
                CREATE TABLE shortcut_tool_metadata (
                    tool_id TEXT, meta_key TEXT, value_type TEXT, string_value TEXT, number_value REAL,
                    bool_value INTEGER, json_value_text TEXT
                );
                """)
            for name in ["One", "Two"] {
                let id = UUID().uuidString
                try db.execute(sql: """
                    INSERT INTO shortcut_tools VALUES (?, ?, 'external', 'fixture', 'direct', 0, NULL, 'generated', 1, 2, 3)
                    """, arguments: [id, name])
                try db.execute(sql: """
                    INSERT INTO shortcut_tool_metadata VALUES (?, 'future', 'string', 'preserve', NULL, NULL, NULL)
                    """, arguments: [id])
            }
        }
        return database
    }
}
