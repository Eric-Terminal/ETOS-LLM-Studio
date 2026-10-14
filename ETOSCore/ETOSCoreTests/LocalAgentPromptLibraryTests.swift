import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct LocalAgentPromptLibraryTests {
    @Test("补建默认提示词不覆盖已有自定义内容")
    func bootstrapPreservesEditedDefault() throws {
        let db = try database()
        try db.write { db in
            #expect(try LocalAgentPromptLibraryStore.ensureBuiltIn(in: db))
            let original = try LocalAgentPromptLibraryStore.load(from: db).profiles[0]
            var draft = original; draft.content = "自定义说明"
            try LocalAgentPromptLibraryStore.save(draft, original: original, in: db)
            #expect(try !LocalAgentPromptLibraryStore.ensureBuiltIn(in: db))
            #expect(try LocalAgentPromptLibraryStore.load(from: db).profiles[0].content == "自定义说明")
        }
    }

    @Test("正文保留空白、名称修整且编辑不影响其他记录")
    func partialSavePreservesContent() throws {
        let db = try database(), first = LocalAgentPromptProfile(title: "  第一项  ", content: "\n 内容 \n")
        let second = LocalAgentPromptProfile(title: "第二项", content: "保留")
        try db.write { db in
            try LocalAgentPromptLibraryStore.save(first, original: nil, in: db)
            try LocalAgentPromptLibraryStore.save(second, original: nil, in: db)
            let original = try LocalAgentPromptLibraryStore.load(from: db).profiles.first { $0.id == first.id }!
            #expect(original.title == "第一项"); #expect(original.content == first.content)
            var draft = original; draft.content = ""; draft.isEnabled = false
            try LocalAgentPromptLibraryStore.save(draft, original: original, in: db)
            let result = try LocalAgentPromptLibraryStore.load(from: db)
            #expect(result.profiles.first { $0.id == first.id }?.content == "")
            #expect(result.profiles.first { $0.id == second.id }?.content == second.content)
        }
    }

    @Test("过期草稿和删除确认不能覆盖新内容或复活已删除记录")
    func staleEditsAndDeletesAreRejected() throws {
        let db = try database(), initial = LocalAgentPromptProfile(title: "原件", content: "旧值")
        try db.write { try LocalAgentPromptLibraryStore.save(initial, original: nil, in: $0) }
        let original = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles[0] }
        var draft = original; draft.content = "新值"
        try db.write { try LocalAgentPromptLibraryStore.save(draft, original: original, in: $0) }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.save(original, original: original, in: $0) } }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.delete(original, in: $0) } }
        let current = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles[0] }
        try db.write { try LocalAgentPromptLibraryStore.delete(current, in: $0) }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.save(current, original: current, in: $0) } }
        #expect(try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles.isEmpty })
    }

    @Test("选用检查目标版本、启用状态和原选择")
    func selectionChecksBothOriginals() throws {
        let db = try database()
        let a = LocalAgentPromptProfile(title: "A", content: ""), b = LocalAgentPromptProfile(title: "B", content: "")
        let disabled = LocalAgentPromptProfile(title: "停用", content: "", isEnabled: false)
        try db.write { db in
            for profile in [a, b, disabled] { try LocalAgentPromptLibraryStore.save(profile, original: nil, in: db) }
        }
        let profiles = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles }
        let first = profiles.first { $0.id == a.id }!, second = profiles.first { $0.id == b.id }!
        let off = profiles.first { $0.id == disabled.id }!
        try db.write { try LocalAgentPromptLibraryStore.select(first, expectedSelection: "", in: $0) }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.select(second, expectedSelection: "", in: $0) } }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.select(off, expectedSelection: a.id.uuidString, in: $0) } }
        var changed = second; changed.content = "另一页面的新操作要求"
        try db.write { try LocalAgentPromptLibraryStore.save(changed, original: second, in: $0) }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.select(second, expectedSelection: a.id.uuidString, in: $0) } }
        let latest = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles.first { $0.id == b.id }! }
        try db.write { try LocalAgentPromptLibraryStore.select(latest, expectedSelection: a.id.uuidString, in: $0) }
        #expect(try db.read { try LocalAgentPromptLibraryStore.load(from: $0).effectiveProfileID } == b.id)
    }

    @Test("删除选用项与恢复默认在同一事务，失败时两者都回滚")
    func deletionAndSelectionAreAtomic() throws {
        let db = try database(), profile = LocalAgentPromptProfile(title: "当前", content: "说明")
        try db.write { try LocalAgentPromptLibraryStore.save(profile, original: nil, in: $0) }
        let original = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles[0] }
        try db.write { db in
            try LocalAgentPromptLibraryStore.select(original, expectedSelection: "", in: db)
            try db.execute(sql: "CREATE TRIGGER reject_selection BEFORE UPDATE ON app_config BEGIN SELECT RAISE(ABORT, '拒绝测试更新'); END")
        }
        #expect(throws: DatabaseError.self) { try db.write { try LocalAgentPromptLibraryStore.delete(original, in: $0) } }
        let unchanged = try db.read { try LocalAgentPromptLibraryStore.load(from: $0) }
        #expect(unchanged.profiles == [original]); #expect(unchanged.selectedProfileID == original.id.uuidString)
        try db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_selection")
            try LocalAgentPromptLibraryStore.delete(original, in: db)
        }
        let result = try db.read { try LocalAgentPromptLibraryStore.load(from: $0) }
        #expect(result.profiles.isEmpty); #expect(result.selectedProfileID.isEmpty)
        #expect(result.effectiveProfileID == LocalAgentPromptStore.builtInProfileID)
    }

    @Test("删除未选用项保持其他选择且内置项不能删除或伪造")
    func immutableIdentityAndUnrelatedSelection() throws {
        let db = try database()
        try db.write { db in
            _ = try LocalAgentPromptLibraryStore.ensureBuiltIn(in: db)
            try LocalAgentPromptLibraryStore.save(LocalAgentPromptProfile(title: "其他", content: ""), original: nil, in: db)
        }
        let profiles = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles }
        let builtin = profiles.first { $0.isBuiltIn }!, other = profiles.first { !$0.isBuiltIn }!
        try db.write { db in
            try LocalAgentPromptLibraryStore.select(builtin, expectedSelection: "", in: db)
            try LocalAgentPromptLibraryStore.delete(other, in: db)
        }
        #expect(try db.read { try LocalAgentPromptLibraryStore.selection(in: $0) } == builtin.id.uuidString)
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.delete(builtin, in: $0) } }
        var forged = builtin; forged.isBuiltIn = false
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.save(forged, original: builtin, in: $0) } }
        #expect(throws: LocalAgentPromptLibraryError.self) { try db.write { try LocalAgentPromptLibraryStore.save(LocalAgentPromptProfile(title: "伪造", content: "", isBuiltIn: true), original: nil, in: $0) } }
    }

    @Test("数据库拒绝正文更新时不改变启用状态与正文")
    func failedSavePreservesRecord() throws {
        let db = try database()
        try db.write { db in
            try LocalAgentPromptLibraryStore.save(LocalAgentPromptProfile(title: "原件", content: "保留"), original: nil, in: db)
            try db.execute(sql: "CREATE TRIGGER reject_prompt BEFORE UPDATE ON local_agent_prompt_profiles BEGIN SELECT RAISE(ABORT, '拒绝测试更新'); END")
        }
        let original = try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles[0] }
        var draft = original; draft.content = "覆盖"; draft.isEnabled = false
        #expect(throws: DatabaseError.self) { try db.write { try LocalAgentPromptLibraryStore.save(draft, original: original, in: $0) } }
        #expect(try db.read { try LocalAgentPromptLibraryStore.load(from: $0).profiles } == [original])
    }

    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try PersistenceAuxiliaryGRDBStore.createLocalLinuxConfigurationTables(db)
            try db.execute(sql: """
                CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER,
                    type_hint TEXT NOT NULL, updated_at REAL NOT NULL);
                """)
        }
        return db
    }
}
