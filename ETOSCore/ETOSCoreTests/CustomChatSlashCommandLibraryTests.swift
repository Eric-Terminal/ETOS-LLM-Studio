import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct CustomChatSlashCommandLibraryTests {
    @Test("事务沿用移动端配置键及 JSON，规范触发词但保留提示词字面空白")
    func compatibleEncodingAndLiteralPrompt() throws {
        let database = try database()
        let original = try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) }
        let command = CustomChatSlashCommand(trigger: " /SK ", prompt: "    缩进代码\n\n")
        let saved = try database.write { try CustomChatSlashCommandTransaction.replace([command], original: original, in: $0) }
        #expect(saved.commands.first?.trigger == "sk")
        #expect(saved.commands.first?.prompt == command.prompt)
        let raw = try #require(saved.rawValue)
        let decoded = try JSONDecoder().decode([CustomChatSlashCommand].self, from: Data(raw.utf8))
        #expect(decoded == saved.commands)
        #expect(try database.read { try String.fetchOne($0, sql: "SELECT key FROM app_config") } == "chat.slashCommands.custom")
    }

    @Test("完整列表更新可排序或清空，旧草稿与旧删除不能覆盖后来写入")
    func replacementOrderAndStaleWrites() throws {
        let database = try database()
        let empty = try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) }
        let a = CustomChatSlashCommand(trigger: "alpha", prompt: "甲"), b = CustomChatSlashCommand(trigger: "beta", prompt: "乙")
        let initial = try database.write { try CustomChatSlashCommandTransaction.replace([a, b], original: empty, in: $0) }
        let reordered = try database.write { try CustomChatSlashCommandTransaction.replace([b, a], original: initial, in: $0) }
        #expect(reordered.commands.map(\.id) == [b.id, a.id])
        #expect(throws: CustomChatSlashCommandError.self) {
            try database.write { try CustomChatSlashCommandTransaction.replace([], original: initial, in: $0) }
        }
        #expect(try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) } == reordered)
        let cleared = try database.write { try CustomChatSlashCommandTransaction.replace([], original: reordered, in: $0) }
        #expect(cleared.commands.isEmpty && cleared.rawValue == "[]")
    }

    @Test("非法触发词、内建名称及别名、重复名称或标识和空正文均拒绝写入")
    func invalidInputsNeverOverwrite() throws {
        let database = try database()
        let original = try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) }
        let a = CustomChatSlashCommand(trigger: "alpha", prompt: "甲")
        let invalid: [[CustomChatSlashCommand]] = [
            [CustomChatSlashCommand(trigger: "two words", prompt: "正文")],
            [CustomChatSlashCommand(trigger: "new", prompt: "正文")],
            [CustomChatSlashCommand(trigger: "history", prompt: "正文")],
            [a, CustomChatSlashCommand(trigger: "ALPHA", prompt: "乙")],
            [a, CustomChatSlashCommand(id: a.id, trigger: "beta", prompt: "乙")],
            [CustomChatSlashCommand(trigger: "blank", prompt: " \n ")]
        ]
        for commands in invalid {
            #expect(throws: CustomChatSlashCommandError.self) {
                try database.write { try CustomChatSlashCommandTransaction.replace(commands, original: original, in: $0) }
            }
            #expect(try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) } == original)
        }
    }

    @Test("数据库写入失败保持原件，不发布部分列表")
    func databaseFailureRollsBack() throws {
        let database = try database()
        let original = try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) }
        try database.write { try $0.execute(sql: "CREATE TRIGGER reject_command BEFORE INSERT ON app_config BEGIN SELECT RAISE(ABORT, '测试拒绝'); END") }
        #expect(throws: DatabaseError.self) {
            try database.write { try CustomChatSlashCommandTransaction.replace([CustomChatSlashCommand(trigger: "alpha", prompt: "甲")], original: original, in: $0) }
        }
        #expect(try database.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) } == original)
    }

    @Test("加载沿用旧数据过滤规则并去除重复标识，避免桌面列表身份冲突")
    func legacyNormalizationKeepsFirstValidIdentity() {
        let a = CustomChatSlashCommand(trigger: " /ALPHA ", prompt: "甲")
        let commands = [a, CustomChatSlashCommand(id: a.id, trigger: "beta", prompt: "乙"),
            CustomChatSlashCommand(trigger: "beta", prompt: "丙"), CustomChatSlashCommand(trigger: "stop", prompt: "内建")]
        let normalized = CustomChatSlashCommandStore.normalizedCommands(commands)
        #expect(normalized.map(\.trigger) == ["alpha", "beta"])
        #expect(normalized.map(\.prompt) == ["甲", "丙"])
    }

    private func database() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { try $0.execute(sql: """
            CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER,
                type_hint TEXT NOT NULL, updated_at REAL NOT NULL)
            """) }
        return database
    }
}
