import Foundation
import GRDB

public enum ChatAppearanceConfigurationError: LocalizedError {
    case changed, unavailable, invalidColor, invalidName
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: NSLocalizedString("无法保存配置。", comment: "")
        case .invalidColor: NSLocalizedString("请输入有效的十六进制颜色。", comment: "")
        case .invalidName: NSLocalizedString("名称不能为空。", comment: "")
        }
    }
}

/// 桌面编辑器复用既有颜色配置格式；比较原始配置与写入共用事务，后台处理迁移和编码。
public actor ChatAppearanceConfigurationLibrary {
    public static let shared = ChatAppearanceConfigurationLibrary()
    public nonisolated static let didChangeNotification = Notification.Name("com.ETOS.chatAppearance.configurationDidChange")

    public func snapshot() throws -> ChatAppearanceProfileConfiguration {
        try Task.checkCancellation()
        guard Persistence.activeAuxiliaryStore(kind: .config) != nil else { throw ChatAppearanceConfigurationError.unavailable }
        // 沿用 Core 的旧键迁移、默认配置及时间段归一化，不建立第二份偏好存储。
        let configuration = ChatAppearanceProfileStore.loadConfiguration()
        try Task.checkCancellation()
        return configuration
    }

    public func save(_ configuration: ChatAppearanceProfileConfiguration,
                     original: ChatAppearanceProfileConfiguration) throws -> ChatAppearanceProfileConfiguration {
        try Task.checkCancellation()
        guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw ChatAppearanceConfigurationError.unavailable }
        do {
            let saved = try store.write { db in
                try Task.checkCancellation()
                return try ChatAppearanceConfigurationTransaction.save(configuration, original: original, in: db)
            }
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            return saved
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatAppearanceConfigurationError { throw error }
        catch let error as ChatAppearanceProfileError { throw error }
        catch { throw ChatAppearanceConfigurationError.unavailable }
    }
}

enum ChatAppearanceConfigurationTransaction {
    static func save(_ configuration: ChatAppearanceProfileConfiguration,
                     original: ChatAppearanceProfileConfiguration, in db: Database) throws -> ChatAppearanceProfileConfiguration {
        let key = ChatAppearanceProfileStore.configurationStorageKey
        guard let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?", arguments: [key]),
              let data = raw.data(using: .utf8),
              try JSONDecoder().decode(ChatAppearanceProfileConfiguration.self, from: data).normalized() == original else {
            throw ChatAppearanceConfigurationError.changed
        }
        // 先验证完整输入，不能让 normalized() 静默丢弃用户刚填写的无效时间段。
        try configuration.validateScheduleRules()
        let ids = Set(configuration.profiles.map(\.id))
        guard ids.count == configuration.profiles.count, ids.contains(ChatAppearanceProfile.defaultProfileID),
              configuration.scheduleRules.allSatisfy({ ids.contains($0.profileID) }),
              Set(configuration.scheduleRules.map(\.id)).count == configuration.scheduleRules.count else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        for profile in configuration.profiles { try validate(profile) }
        let normalized = configuration.normalized()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(normalized), as: UTF8.self)
        try db.execute(sql: """
            UPDATE app_config SET value_text = ?, value_real = NULL, value_integer = NULL,
                type_hint = 'text', updated_at = ? WHERE key = ?
            """, arguments: [encoded, Date().timeIntervalSince1970, key])
        return normalized
    }

    static func validate(_ profile: ChatAppearanceProfile) throws {
        guard !profile.id.isEmpty, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatAppearanceConfigurationError.invalidName
        }
        let styles = [profile.userLightTextStyles, profile.userDarkTextStyles, profile.assistantLightTextStyles, profile.assistantDarkTextStyles]
        let slots = [profile.userBubble, profile.assistantBubble, profile.userLightText, profile.userDarkText,
                     profile.assistantLightText, profile.assistantDarkText] + styles.flatMap { [$0.emphasis, $0.strong, $0.code] }
        let colors = slots.map(\.hex) + styles.flatMap { $0.customRules.map(\.colorHex) }
        for raw in colors {
            let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            guard (hex.count == 6 || hex.count == 8), UInt64(hex, radix: 16) != nil else { throw ChatAppearanceConfigurationError.invalidColor }
        }
    }
}
