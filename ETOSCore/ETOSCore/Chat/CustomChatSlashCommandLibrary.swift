import Foundation
import GRDB

public struct CustomChatSlashCommandSnapshot: Equatable, Sendable {
    public let commands: [CustomChatSlashCommand]
    /// 原始值区分不存在、空值与不同编码，事务不能覆盖读取后发生的同步修改。
    public let rawValue: String?
    public init(commands: [CustomChatSlashCommand], rawValue: String?) {
        self.commands = commands; self.rawValue = rawValue
    }
}

public enum CustomChatSlashCommandError: LocalizedError {
    case changed, unavailable, invalidTrigger, reservedTrigger, duplicateTrigger, emptyPrompt, duplicateID
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: NSLocalizedString("无法保存配置。", comment: "")
        case .invalidTrigger: NSLocalizedString("指令只能包含字母、数字、短横线和下划线。", comment: "")
        case .reservedTrigger: NSLocalizedString("该指令与内建命令重复。", comment: "")
        case .duplicateTrigger: NSLocalizedString("已有同名的自定义指令。", comment: "")
        case .emptyPrompt: NSLocalizedString("提示词不能为空。", comment: "")
        case .duplicateID: NSLocalizedString("配置包含重复标识。", comment: "")
        }
    }
}

/// 复用移动端 JSON 与配置键，在后台事务内校验整份原件；不维护另一份命令数据库。
public actor CustomChatSlashCommandLibrary {
    public static let shared = CustomChatSlashCommandLibrary()
    public nonisolated static let didChangeNotification = Notification.Name("com.ETOS.slashCommandLibrary.didChange")

    public func snapshot() throws -> CustomChatSlashCommandSnapshot {
        try Task.checkCancellation()
        guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw CustomChatSlashCommandError.unavailable }
        return try store.read { try CustomChatSlashCommandTransaction.snapshot(in: $0) }
    }

    public func replace(_ commands: [CustomChatSlashCommand], original: CustomChatSlashCommandSnapshot) throws -> CustomChatSlashCommandSnapshot {
        guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw CustomChatSlashCommandError.unavailable }
        let saved: CustomChatSlashCommandSnapshot
        do {
            saved = try store.write { try CustomChatSlashCommandTransaction.replace(commands, original: original, in: $0) }
        } catch let error as CustomChatSlashCommandError { throw error }
        catch { throw CustomChatSlashCommandError.unavailable }
        // 已提交的事务总是返回写入原文，只有首次读取空库的快照可能没有原文。
        AppConfigStore.publishPersistedValue(.text(saved.rawValue!), for: .customChatSlashCommands)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return saved
    }

    public nonisolated static func validated(_ commands: [CustomChatSlashCommand]) throws -> [CustomChatSlashCommand] {
        var triggers: Set<String> = [], ids: Set<UUID> = []
        return try commands.map { command in
            var result = command
            result.trigger = CustomChatSlashCommandStore.canonicalTrigger(command.trigger)
            guard CustomChatSlashCommandStore.isValidTrigger(result.trigger) else { throw CustomChatSlashCommandError.invalidTrigger }
            guard !ChatSlashCommandParser.isReservedTrigger(result.trigger) else { throw CustomChatSlashCommandError.reservedTrigger }
            guard triggers.insert(result.trigger).inserted else { throw CustomChatSlashCommandError.duplicateTrigger }
            guard ids.insert(result.id).inserted else { throw CustomChatSlashCommandError.duplicateID }
            guard !result.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CustomChatSlashCommandError.emptyPrompt }
            // 提示词可能有 Markdown 缩进或结尾换行，校验空白不等于修剪正文。
            return result
        }
    }
}

enum CustomChatSlashCommandTransaction {
    static func snapshot(in db: Database) throws -> CustomChatSlashCommandSnapshot {
        let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                                      arguments: [AppConfigKey.customChatSlashCommands.rawValue])
        let decoded = raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([CustomChatSlashCommand].self, from: $0) } ?? []
        return CustomChatSlashCommandSnapshot(commands: CustomChatSlashCommandStore.normalizedCommands(decoded), rawValue: raw)
    }

    static func replace(_ commands: [CustomChatSlashCommand], original: CustomChatSlashCommandSnapshot,
                        in db: Database) throws -> CustomChatSlashCommandSnapshot {
        guard try snapshot(in: db).rawValue == original.rawValue else { throw CustomChatSlashCommandError.changed }
        let validated = try CustomChatSlashCommandLibrary.validated(commands)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = String(decoding: try encoder.encode(validated), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, NULL, NULL, 'text', ?)
            ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text, value_real = NULL,
                value_integer = NULL, type_hint = 'text', updated_at = excluded.updated_at
            """, arguments: [AppConfigKey.customChatSlashCommands.rawValue, raw, Date().timeIntervalSince1970])
        return CustomChatSlashCommandSnapshot(commands: validated, rawValue: raw)
    }
}
