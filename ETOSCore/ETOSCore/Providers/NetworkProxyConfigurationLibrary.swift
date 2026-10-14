import Foundation
import GRDB

public enum NetworkProxyConfigurationError: LocalizedError {
    case changed, unavailable, invalidHost, invalidPort

    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: NSLocalizedString("无法保存配置。", comment: "")
        case .invalidHost: NSLocalizedString("启用代理时必须填写代理地址。", comment: "")
        case .invalidPort: NSLocalizedString("代理端口必须在 1~65535 之间。", comment: "")
        }
    }
}

/// 使用既有配置键；整组比较与写入共享事务，避免旧窗口覆盖新凭据。
public actor NetworkProxyConfigurationLibrary {
    public static let shared = NetworkProxyConfigurationLibrary()

    public func snapshot() throws -> NetworkProxyConfiguration {
        do {
            try Task.checkCancellation()
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw NetworkProxyConfigurationError.unavailable }
            return try store.read { try NetworkProxyConfigurationStore.load($0) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as NetworkProxyConfigurationError { throw error }
        catch { throw NetworkProxyConfigurationError.unavailable }
    }

    public func save(_ configuration: NetworkProxyConfiguration, original: NetworkProxyConfiguration) throws -> NetworkProxyConfiguration {
        do {
            try Task.checkCancellation()
            try Self.validate(configuration)
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw NetworkProxyConfigurationError.unavailable }
            try store.write { db in
                try Task.checkCancellation()
                try NetworkProxyConfigurationStore.save(configuration, original: original, in: db)
            }
            NetworkProxyConfigurationStore.notifyChange()
            return configuration
        } catch is CancellationError { throw CancellationError() }
        catch let error as NetworkProxyConfigurationError { throw error }
        // 原始 SQLite 错误可能包含密码绑定参数，不能用于界面或诊断输出。
        catch { throw NetworkProxyConfigurationError.unavailable }
    }

    public nonisolated static func validate(_ configuration: NetworkProxyConfiguration) throws {
        guard (1...65535).contains(configuration.port) else { throw NetworkProxyConfigurationError.invalidPort }
        guard !configuration.isEnabled || !configuration.trimmedHost.isEmpty else { throw NetworkProxyConfigurationError.invalidHost }
    }
}

enum NetworkProxyConfigurationStore {
    static func load(_ db: Database) throws -> NetworkProxyConfiguration {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value_text, value_integer FROM app_config WHERE key LIKE 'networkProxy.global.%'")
        let values = Dictionary(uniqueKeysWithValues: rows.map { row in (row["key"] as String, row) })
        let keys = NetworkProxySettings.Keys.self
        let port: Int = values[keys.port]?["value_integer"] ?? 8080
        let enabled: Int = values[keys.isEnabled]?["value_integer"] ?? 0
        let type: String = values[keys.type]?["value_text"] ?? NetworkProxyType.http.rawValue
        return NetworkProxyConfiguration(isEnabled: enabled != 0, type: NetworkProxyType(rawValue: type) ?? .http,
            host: values[keys.host]?["value_text"] ?? "", port: (1...65535).contains(port) ? port : 8080,
            username: values[keys.username]?["value_text"] ?? "", password: values[keys.password]?["value_text"] ?? "")
    }

    static func save(_ configuration: NetworkProxyConfiguration, original: NetworkProxyConfiguration, in db: Database) throws {
        guard try load(db) == original else { throw NetworkProxyConfigurationError.changed }
        try NetworkProxyConfigurationLibrary.validate(configuration)
        try write(configuration, in: db)
    }

    static func write(_ configuration: NetworkProxyConfiguration, in db: Database) throws {
        let keys = NetworkProxySettings.Keys.self
        let values: [(String, String?, Int?, String)] = [
            (keys.isEnabled, nil, configuration.isEnabled ? 1 : 0, "bool"),
            (keys.type, configuration.type.rawValue, nil, "text"),
            (keys.host, configuration.host, nil, "text"),
            (keys.port, nil, configuration.port, "integer"),
            (keys.username, configuration.username, nil, "text"),
            (keys.password, configuration.password, nil, "text")
        ]
        let now = Date().timeIntervalSince1970
        for (key, text, integer, hint) in values {
            try db.execute(sql: """
                INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
                VALUES (?, ?, NULL, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET
                    value_text = excluded.value_text, value_real = NULL, value_integer = excluded.value_integer,
                    type_hint = excluded.type_hint, updated_at = excluded.updated_at
                """, arguments: [key, text, integer, hint, now])
        }
    }

    static func notifyChange() {
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}
