import Foundation
import GRDB

public enum ToolApprovalPreferenceChange: Sendable {
    case enabled(Bool)
    case countdown(Int)
    case automation(enabled: Bool?, countdown: Int?)
    case disableForTool(String, Bool)
    case clearDisabledTools
}

public enum ToolApprovalSettingsError: LocalizedError {
    case invalidValue, persistenceFailed
    public var errorDescription: String? { NSLocalizedString("工具审批设置更新失败，请重试。", comment: "") }
}

struct ToolApprovalPreferences: Sendable, Equatable {
    enum Keys {
        static let autoApproveEnabled = "tool.permission.autoApproveEnabled"
        static let autoApproveCountdownSeconds = "tool.permission.autoApproveCountdownSeconds"
        static let disabledAutoApproveTools = "tool.permission.disabledAutoApproveTools"
    }
    let enabled: Bool
    let countdown: Int
    let disabledTools: [String]
    let disabledSet: Set<String>

    init(enabled: Bool, countdown: Int, disabledTools: [String]) {
        self.enabled = enabled
        self.countdown = countdown > 0 ? min(30, countdown) : 8
        disabledSet = Set(disabledTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        self.disabledTools = disabledSet.sorted()
    }
}

struct ToolApprovalSettingsResult: Sendable {
    let revision: UInt64
    let preferences: ToolApprovalPreferences
}

actor ToolApprovalSettingsWorker {
    private var revision: UInt64 = 0
    private let read: @Sendable () throws -> ToolApprovalPreferences
    private let save: @Sendable (ToolApprovalPreferenceChange) throws -> ToolApprovalPreferences

    init(
        read: @escaping @Sendable () throws -> ToolApprovalPreferences = {
            guard let preferences = Persistence.withConfigDatabaseRead({ try ToolApprovalSettingsWorker.load(from: $0) }) else {
                throw ToolApprovalSettingsError.persistenceFailed
            }
            return preferences
        },
        save: @escaping @Sendable (ToolApprovalPreferenceChange) throws -> ToolApprovalPreferences = { change in
            guard let preferences = Persistence.withConfigDatabaseWrite({ try ToolApprovalSettingsWorker.update(change, in: $0) }) else {
                throw ToolApprovalSettingsError.persistenceFailed
            }
            return preferences
        }
    ) {
        self.read = read; self.save = save
    }

    func load() throws -> ToolApprovalSettingsResult {
        result(try read())
    }

    func update(_ change: ToolApprovalPreferenceChange) throws -> ToolApprovalSettingsResult {
        // 审批沿用原来的本机数据库键，不加入普通配置的快速同步白名单。
        return result(try save(change))
    }

    private func result(_ preferences: ToolApprovalPreferences) -> ToolApprovalSettingsResult {
        revision &+= 1
        return ToolApprovalSettingsResult(revision: revision, preferences: preferences)
    }

    nonisolated static func load(from db: Database) throws -> ToolApprovalPreferences {
        let enabled = try Int.fetchOne(db, sql: "SELECT value_integer FROM app_config WHERE key = ?", arguments: [ToolApprovalPreferences.Keys.autoApproveEnabled]) ?? 0
        let countdown = try Int.fetchOne(db, sql: "SELECT value_integer FROM app_config WHERE key = ?", arguments: [ToolApprovalPreferences.Keys.autoApproveCountdownSeconds]) ?? 8
        let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?", arguments: [ToolApprovalPreferences.Keys.disabledAutoApproveTools])
        let disabled: [String]
        if let raw {
            guard let decoded = AppConfigStore.decodeStringArray(from: raw) else { throw ToolApprovalSettingsError.invalidValue }
            disabled = decoded
        } else { disabled = [] }
        return ToolApprovalPreferences(enabled: enabled != 0, countdown: countdown, disabledTools: disabled)
    }

    nonisolated static func update(_ change: ToolApprovalPreferenceChange, in db: Database) throws -> ToolApprovalPreferences {
        let current = try load(from: db)
        let key: String, text: String?, integer: Int?, type: String
        switch change {
        case .enabled(let enabled):
            key = ToolApprovalPreferences.Keys.autoApproveEnabled; text = nil; integer = enabled ? 1 : 0; type = "bool"
        case .countdown(let seconds):
            guard (1...30).contains(seconds) else { throw ToolApprovalSettingsError.invalidValue }
            key = ToolApprovalPreferences.Keys.autoApproveCountdownSeconds; text = nil; integer = seconds; type = "integer"
        case .automation(let enabled, let countdown):
            guard enabled != nil || countdown != nil else { throw ToolApprovalSettingsError.invalidValue }
            if let countdown {
                guard (1...30).contains(countdown) else { throw ToolApprovalSettingsError.invalidValue }
                _ = try update(.countdown(countdown), in: db)
            }
            if let enabled { _ = try update(.enabled(enabled), in: db) }
            return try load(from: db)
        case .disableForTool(let name, let disabled):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ToolApprovalSettingsError.invalidValue }
            var names = current.disabledSet
            if disabled { names.insert(name) } else { names.remove(name) }
            key = ToolApprovalPreferences.Keys.disabledAutoApproveTools
            text = AppConfigStore.encodeStringArray(names.sorted()); integer = nil; type = "text"
        case .clearDisabledTools:
            key = ToolApprovalPreferences.Keys.disabledAutoApproveTools; text = "[]"; integer = nil; type = "text"
        }
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, NULL, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text, value_real = NULL,
                value_integer = excluded.value_integer, type_hint = excluded.type_hint, updated_at = excluded.updated_at
            """, arguments: [key, text, integer, type, Date().timeIntervalSince1970])
        return try load(from: db)
    }
}
