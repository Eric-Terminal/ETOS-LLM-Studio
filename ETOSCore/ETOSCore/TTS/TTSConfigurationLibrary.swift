import Foundation
import GRDB

public enum TTSConfigurationError: LocalizedError {
    case changed, unavailable, invalidService

    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: NSLocalizedString("无法保存配置。", comment: "")
        case .invalidService: NSLocalizedString("当前 TTS 服务配置不完整。", comment: "")
        }
    }
}

/// 草稿保存携带数据库原始版本，包含密钥变化和删除，不能以规范化后的显示值判断冲突。
public struct TTSConfigurationSnapshot: Sendable {
    public var settings: TTSSettingsSnapshot
    public var services: [TTSServiceConfiguration]
    public var selectedServiceID: UUID?
    var revision: [String: TTSConfigurationValue]

    public var selectedService: TTSServiceConfiguration? {
        services.first { $0.id == selectedServiceID }
    }
}

/// 桌面端先在后台读取完整快照，再创建播放器和编辑草稿，不触发旧设置单例的同步数据库读取。
public actor TTSConfigurationLibrary {
    public static let shared = TTSConfigurationLibrary()

    public func snapshot() throws -> TTSConfigurationSnapshot {
        do {
            try Task.checkCancellation()
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw TTSConfigurationError.unavailable }
            let rows = try store.read { try TTSConfigurationStore.rows($0) }
            let settings = TTSConfigurationStore.settings(rows)
            let raw = rows[AppConfigKey.ttsServiceConfiguration.rawValue]?.text ?? ""
            // 损坏的已有 JSON 不能作为空配置重新写入，否则一次打开设置页就会丢失服务密钥。
            try TTSConfigurationStore.validatePayload(raw)
            let loaded = TTSServiceStore.loadPayload(from: raw, legacySettings: settings)
            var snapshot = TTSConfigurationSnapshot(settings: settings, services: loaded.payload.services,
                selectedServiceID: loaded.payload.selectedServiceID, revision: rows)
            if loaded.needsPersistence {
                let encoded = try TTSConfigurationStore.encode(loaded.payload)
                snapshot.revision = try store.write { db in
                    try Task.checkCancellation()
                    guard try TTSConfigurationStore.rows(db) == rows else { throw TTSConfigurationError.changed }
                    try TTSConfigurationStore.write(.init(text: encoded), key: AppConfigKey.ttsServiceConfiguration.rawValue, in: db)
                    return try TTSConfigurationStore.rows(db)
                }
                TTSConfigurationStore.notifyChange(serviceJSON: encoded)
            }
            return snapshot
        } catch is CancellationError { throw CancellationError() }
        catch let error as TTSConfigurationError { throw error }
        catch { throw TTSConfigurationError.unavailable }
    }

    public func save(_ draft: TTSConfigurationSnapshot, replacing original: TTSConfigurationSnapshot) throws -> TTSConfigurationSnapshot {
        do {
            try Task.checkCancellation()
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw TTSConfigurationError.unavailable }
            let saved = try store.write { db in
                try Task.checkCancellation()
                return try TTSConfigurationStore.save(draft, replacing: original, in: db)
            }
            TTSConfigurationStore.notifyChange(serviceJSON: saved.revision[AppConfigKey.ttsServiceConfiguration.rawValue]?.text ?? "")
            return saved
        } catch is CancellationError { throw CancellationError() }
        catch let error as TTSConfigurationError { throw error }
        // SQLite 错误可能包含服务 JSON 的绑定参数，界面和日志只能收到固定错误。
        catch { throw TTSConfigurationError.unavailable }
    }
}

struct TTSConfigurationValue: Equatable, Sendable {
    var text: String?
    var real: Double?
    var integer: Int?
    var hint: String?
    var updatedAt: Double?

    init(text: String? = nil, real: Double? = nil, integer: Int? = nil, hint: String? = nil, updatedAt: Double? = nil) {
        self.text = text; self.real = real; self.integer = integer; self.hint = hint; self.updatedAt = updatedAt
    }
}

enum TTSConfigurationStore {
    private static let keys = TTSSettingsStore.Keys.self
    static let managedKeys = [
        keys.playbackMode, keys.providerKind, keys.autoPlayAfterAssistantResponse, keys.onlyReadQuotedContent,
        keys.watchUseLightweightPreprocess, keys.watchSpeechMaxCharacters, keys.speechRate, keys.pitch,
        keys.playbackSpeed, keys.voice, keys.responseFormat, keys.languageType, keys.miniMaxEmotion,
        AppConfigKey.ttsServiceConfiguration.rawValue, AppConfigKey.ttsModelIdentifier.rawValue
    ]

    static func rows(_ db: Database) throws -> [String: TTSConfigurationValue] {
        let placeholders = managedKeys.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM app_config WHERE key IN (\(placeholders))", arguments: StatementArguments(managedKeys))
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["key"] as String, TTSConfigurationValue(text: row["value_text"], real: row["value_real"],
                integer: row["value_integer"], hint: row["type_hint"], updatedAt: row["updated_at"]))
        })
    }

    static func settings(_ rows: [String: TTSConfigurationValue]) -> TTSSettingsSnapshot {
        let defaults = TTSSettingsSnapshot.defaultValue
        func text(_ key: String, _ fallback: String) -> String { rows[key]?.text ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { rows[key]?.integer.map { $0 != 0 } ?? fallback }
        func real(_ key: String, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
            let value = rows[key]?.real.map(Float.init) ?? fallback
            return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return TTSSettingsSnapshot(
            playbackMode: TTSPlaybackMode(rawValue: text(keys.playbackMode, "")) ?? defaults.playbackMode,
            providerKind: TTSProviderKind(rawValue: text(keys.providerKind, "")) ?? defaults.providerKind,
            autoPlayAfterAssistantResponse: bool(keys.autoPlayAfterAssistantResponse, defaults.autoPlayAfterAssistantResponse),
            onlyReadQuotedContent: bool(keys.onlyReadQuotedContent, defaults.onlyReadQuotedContent),
            watchUseLightweightPreprocess: bool(keys.watchUseLightweightPreprocess, defaults.watchUseLightweightPreprocess),
            watchSpeechMaxCharacters: min(max(rows[keys.watchSpeechMaxCharacters]?.integer ?? defaults.watchSpeechMaxCharacters, 500), 6_000),
            speechRate: real(keys.speechRate, defaults.speechRate, 0.1...3),
            pitch: real(keys.pitch, defaults.pitch, 0.1...2), playbackSpeed: real(keys.playbackSpeed, defaults.playbackSpeed, 0.5...2),
            voice: text(keys.voice, defaults.voice), responseFormat: text(keys.responseFormat, defaults.responseFormat),
            languageType: text(keys.languageType, defaults.languageType), miniMaxEmotion: text(keys.miniMaxEmotion, defaults.miniMaxEmotion)
        )
    }

    static func validatePayload(_ raw: String) throws {
        if !raw.isEmpty { _ = try JSONDecoder().decode(TTSServiceStore.Payload.self, from: Data(raw.utf8)) }
    }

    static func encode(_ payload: TTSServiceStore.Payload) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    static func save(_ draft: TTSConfigurationSnapshot, replacing original: TTSConfigurationSnapshot, in db: Database) throws -> TTSConfigurationSnapshot {
        guard try rows(db) == original.revision else { throw TTSConfigurationError.changed }
        let payload = TTSServiceStore.normalizedPayload(.init(services: draft.services,
            selectedServiceID: draft.selectedServiceID, didMigrateLegacyModel: true))
        for service in payload.services where original.services.first(where: { $0.id == service.id }) != service {
            guard service.isReady else { throw TTSConfigurationError.invalidService }
        }
        let settings = draft.settings
        guard settings.speechRate.isFinite, settings.pitch.isFinite, settings.playbackSpeed.isFinite else {
            throw TTSConfigurationError.unavailable
        }
        let values: [(String, TTSConfigurationValue)] = [
            (keys.playbackMode, .init(text: settings.playbackMode.rawValue)),
            (keys.providerKind, .init(text: settings.providerKind.rawValue)),
            (keys.autoPlayAfterAssistantResponse, .init(integer: settings.autoPlayAfterAssistantResponse ? 1 : 0, hint: "bool")),
            (keys.onlyReadQuotedContent, .init(integer: settings.onlyReadQuotedContent ? 1 : 0, hint: "bool")),
            (keys.watchUseLightweightPreprocess, .init(integer: settings.watchUseLightweightPreprocess ? 1 : 0, hint: "bool")),
            (keys.watchSpeechMaxCharacters, .init(integer: min(max(settings.watchSpeechMaxCharacters, 500), 6_000))),
            (keys.speechRate, .init(real: Double(min(max(settings.speechRate, 0.1), 3)))),
            (keys.pitch, .init(real: Double(min(max(settings.pitch, 0.1), 2)))),
            (keys.playbackSpeed, .init(real: Double(min(max(settings.playbackSpeed, 0.5), 2)))),
            (keys.voice, .init(text: settings.voice)), (keys.responseFormat, .init(text: settings.responseFormat)),
            (keys.languageType, .init(text: settings.languageType)), (keys.miniMaxEmotion, .init(text: settings.miniMaxEmotion)),
            (AppConfigKey.ttsServiceConfiguration.rawValue, .init(text: try encode(payload)))
        ]
        let now = Date().timeIntervalSince1970
        for (key, value) in values { try write(value, key: key, updatedAt: now, in: db) }
        let savedRows = try rows(db)
        return TTSConfigurationSnapshot(settings: self.settings(savedRows), services: payload.services,
            selectedServiceID: payload.selectedServiceID, revision: savedRows)
    }

    static func write(_ value: TTSConfigurationValue, key: String, updatedAt: Double = Date().timeIntervalSince1970, in db: Database) throws {
        let hint = value.hint ?? (value.text != nil ? "text" : value.real != nil ? "real" : "integer")
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET
                value_text = excluded.value_text, value_real = excluded.value_real,
                value_integer = excluded.value_integer, type_hint = excluded.type_hint, updated_at = excluded.updated_at
            """, arguments: [key, value.text, value.real, value.integer, hint, updatedAt])
    }

    static func notifyChange(serviceJSON: String) {
        AppConfigStore.publishPersistedValue(.text(serviceJSON), for: .ttsServiceConfiguration)
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}
