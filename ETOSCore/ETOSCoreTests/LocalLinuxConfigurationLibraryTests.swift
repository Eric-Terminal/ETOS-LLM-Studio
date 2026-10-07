import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct LocalLinuxConfigurationLibraryTests {
    @Test("变量只修整名称，保留值与备注的字面空白并拒绝重名")
    func variableWhitespaceAndDuplicateNames() throws {
        let db = try database()
        let value = LocalLinuxEnvironmentVariable(name: "  API_TOKEN\n", value: " \n私密值\n ", note: "  备注  ")
        try db.write { try LocalLinuxConfigurationStore.saveVariable(value, original: nil, in: $0) }
        let saved = try db.read { try LocalLinuxConfigurationStore.variables($0)[0] }
        #expect(saved.name == "API_TOKEN"); #expect(saved.value == value.value); #expect(saved.note == value.note)
        #expect(throws: LocalLinuxConfigurationError.self) {
            try db.write { try LocalLinuxConfigurationStore.saveVariable(LocalLinuxEnvironmentVariable(name: "api_token", value: "覆盖"), original: nil, in: $0) }
        }
        #expect(try db.read { try LocalLinuxConfigurationStore.variables($0) } == [saved])
    }

    @Test("无效变量名称和 NUL 值拒绝入库，空值仍合法")
    func invalidVariablesDoNotPersist() throws {
        let db = try database()
        for value in [LocalLinuxEnvironmentVariable(name: "1NAME", value: ""), LocalLinuxEnvironmentVariable(name: "NAME", value: "a\0b")] {
            #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveVariable(value, original: nil, in: $0) } }
        }
        #expect(try db.read { try LocalLinuxConfigurationStore.variables($0).isEmpty })
        try db.write { try LocalLinuxConfigurationStore.saveVariable(LocalLinuxEnvironmentVariable(name: "NAME", value: ""), original: nil, in: $0) }
        #expect(try db.read { try LocalLinuxConfigurationStore.variables($0)[0].value } == "")
    }

    @Test("旧变量草稿与删除确认不能覆盖新值或复活删除项")
    func staleVariableOperationsFail() throws {
        let db = try database()
        try db.write { try LocalLinuxConfigurationStore.saveVariable(LocalLinuxEnvironmentVariable(name: "TOKEN", value: "旧值"), original: nil, in: $0) }
        let original = try db.read { try LocalLinuxConfigurationStore.variables($0)[0] }
        var draft = original; draft.value = "新值"; draft.isEnabled = false
        try db.write { try LocalLinuxConfigurationStore.saveVariable(draft, original: original, in: $0) }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveVariable(original, original: original, in: $0) } }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.deleteVariable(original, in: $0) } }
        let current = try db.read { try LocalLinuxConfigurationStore.variables($0)[0] }
        try db.write { try LocalLinuxConfigurationStore.deleteVariable(current, in: $0) }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveVariable(current, original: current, in: $0) } }
        #expect(try db.read { try LocalLinuxConfigurationStore.variables($0).isEmpty })
    }

    @Test("数据库拒绝变量更新时名称、值与启用状态一起保持原件")
    func failedVariableWriteRollsBack() throws {
        let db = try database()
        try db.write { db in
            try LocalLinuxConfigurationStore.saveVariable(LocalLinuxEnvironmentVariable(name: "TOKEN", value: "私密原件"), original: nil, in: db)
            try db.execute(sql: "CREATE TRIGGER reject_variable BEFORE UPDATE ON local_linux_environment_variables BEGIN SELECT RAISE(ABORT, '测试拒绝'); END")
        }
        let original = try db.read { try LocalLinuxConfigurationStore.variables($0)[0] }
        var draft = original; draft.name = "OTHER"; draft.value = "新值"; draft.isEnabled = false
        #expect(throws: DatabaseError.self) { try db.write { try LocalLinuxConfigurationStore.saveVariable(draft, original: original, in: $0) } }
        #expect(try db.read { try LocalLinuxConfigurationStore.variables($0) } == [original])
    }

    @Test("规则校验正则，空名称使用匹配文本，新项追加且编辑保留顺序")
    func ruleValidationAndOrder() throws {
        let db = try database()
        let first = LocalLinuxCommandRule(name: "  ", pattern: "  echo  ", matchKind: .prefix, scope: .run, action: .warn, sortIndex: 99)
        let second = LocalLinuxCommandRule(name: "第二条", pattern: "^rm\\s", matchKind: .regularExpression, scope: .shell, action: .confirm)
        try db.write { db in
            try LocalLinuxConfigurationStore.saveRule(first, original: nil, in: db)
            try LocalLinuxConfigurationStore.saveRule(second, original: nil, in: db)
        }
        let original = try db.read { try LocalLinuxConfigurationStore.rules($0) }
        #expect(original.map(\.sortIndex) == [0, 1]); #expect(original[0].name == "echo"); #expect(original[0].pattern == "echo")
        var draft = original[0]; draft.sortIndex = 80; draft.action = .deny
        try db.write { try LocalLinuxConfigurationStore.saveRule(draft, original: original[0], in: $0) }
        #expect(try db.read { try LocalLinuxConfigurationStore.rules($0)[0].sortIndex } == 0)
        let invalid = LocalLinuxCommandRule(name: "错误", pattern: "[", matchKind: .regularExpression, scope: .all, action: .deny)
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveRule(invalid, original: nil, in: $0) } }
        #expect(try db.read { try LocalLinuxConfigurationStore.rules($0).count } == 2)
    }

    @Test("规则排序在单一事务完成，半途失败回滚并拒绝旧顺序和旧删除")
    func reorderingIsAtomicAndChecksOriginals() throws {
        let db = try database()
        try db.write { db in
            for pattern in ["a", "b", "c"] {
                try LocalLinuxConfigurationStore.saveRule(LocalLinuxCommandRule(name: pattern, pattern: pattern, matchKind: .suffix, scope: .all, action: .deny), original: nil, in: db)
            }
            // 交换前两项时先写 b，再让 a 失败，验证前一次 UPDATE 也会回滚。
            try db.execute(sql: "CREATE TRIGGER reject_order BEFORE UPDATE ON local_linux_command_rules WHEN OLD.name = 'a' BEGIN SELECT RAISE(ABORT, '测试拒绝'); END")
        }
        let original = try db.read { try LocalLinuxConfigurationStore.rules($0) }
        #expect(throws: DatabaseError.self) { try db.write { try LocalLinuxConfigurationStore.moveRule(id: original[0].id, offset: 1, original: original, in: $0) } }
        #expect(try db.read { try LocalLinuxConfigurationStore.rules($0) } == original)
        try db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_order")
            try LocalLinuxConfigurationStore.moveRule(id: original[0].id, offset: 1, original: original, in: db)
        }
        let reordered = try db.read { try LocalLinuxConfigurationStore.rules($0) }
        #expect(reordered.map(\.name) == ["b", "a", "c"])
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.moveRule(id: original[0].id, offset: 1, original: original, in: $0) } }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.deleteRule(original[0], in: $0) } }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveRule(original[0], original: original[0], in: $0) } }
        try db.write { try LocalLinuxConfigurationStore.deleteRule(reordered[0], in: $0) }
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveRule(reordered[0], original: reordered[0], in: $0) } }
    }

    @Test("快捷栏保留旧编码读取，保存规范 JSON 并拒绝旧编码覆盖")
    func shortcutLegacyEncodingAndConflict() throws {
        let db = try database(), legacy = "escape,controlC,tab"
        try db.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES (?, ?, 'text', 0)", arguments: [AppConfigKey.localLinuxTerminalShortcutIDs.rawValue, legacy])
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES ('unrelated', '保留', 'text', 0)")
        }
        let snapshot = try db.read { try LocalLinuxConfigurationStore.load($0) }
        #expect(snapshot.shortcutEncoding == legacy); #expect(snapshot.shortcuts.map(\.keys) == [[.escape], [.control, .c], [.tab]])
        let reordered = Array(snapshot.shortcuts.reversed())
        try db.write { try LocalLinuxConfigurationStore.saveShortcuts(reordered, expectedEncoding: legacy, in: $0) }
        let saved = try db.read { try LocalLinuxConfigurationStore.load($0) }
        #expect(saved.shortcuts == reordered); #expect(saved.shortcutEncoding.hasPrefix("["))
        #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveShortcuts([], expectedEncoding: legacy, in: $0) } }
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'unrelated'") } == "保留")
    }

    @Test("快捷栏拒绝重复身份和单独修饰键，空列表合法且失败写入保持旧值")
    func shortcutValidationAndRollback() throws {
        let db = try database(), item = LocalLinuxTerminalShortcut(keys: [.control, .c])
        let encoding = try db.read { try LocalLinuxConfigurationStore.shortcutEncoding($0) }
        for invalid in [[item, item], [LocalLinuxTerminalShortcut(keys: [.control])]] {
            #expect(throws: LocalLinuxConfigurationError.self) { try db.write { try LocalLinuxConfigurationStore.saveShortcuts(invalid, expectedEncoding: encoding, in: $0) } }
        }
        try db.write { try LocalLinuxConfigurationStore.saveShortcuts([item], expectedEncoding: encoding, in: $0) }
        let saved = try db.read { try LocalLinuxConfigurationStore.shortcutEncoding($0) }
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_shortcuts BEFORE UPDATE ON app_config BEGIN SELECT RAISE(ABORT, '测试拒绝'); END") }
        #expect(throws: DatabaseError.self) { try db.write { try LocalLinuxConfigurationStore.saveShortcuts([], expectedEncoding: saved, in: $0) } }
        #expect(try db.read { try LocalLinuxConfigurationStore.shortcutEncoding($0) } == saved)
        try db.write { db in
            try db.execute(sql: "DROP TRIGGER reject_shortcuts")
            try LocalLinuxConfigurationStore.saveShortcuts([], expectedEncoding: saved, in: db)
        }
        #expect(try db.read { try LocalLinuxConfigurationStore.load($0).shortcuts.isEmpty })
    }

    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try PersistenceAuxiliaryGRDBStore.createLocalLinuxConfigurationTables(db)
            try db.execute(sql: "CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER, type_hint TEXT NOT NULL, updated_at REAL NOT NULL)")
        }
        return db
    }
}
