// ============================================================================
// AppConfigLegacyUserDefaultsMigration.swift
// ============================================================================
// ETOS LLM Studio
//
// 将旧版 UserDefaults.standard 配置一次性迁移到 app_config。
// ============================================================================

import Foundation

enum AppConfigLegacyUserDefaultsMigration {
    private static let migrationLock = NSLock()
    private static var isMigrating = false

    static func migrateStandardUserDefaults() {
        let defaults = UserDefaults.standard
        guard hasMigrationCandidate(in: defaults) else { return }

        migrationLock.lock()
        if isMigrating {
            migrationLock.unlock()
            return
        }
        isMigrating = true
        migrationLock.unlock()

        defer {
            migrationLock.lock()
            isMigrating = false
            migrationLock.unlock()
        }

        GlobalSystemPromptStore.migrateLegacyUserDefaultsToDatabase()
        ChatAppearanceProfileStore.migrateLegacyUserDefaultsToAppConfig()

        var existingKeys = Set(Persistence.loadAllAppConfigs().map { $0.key })
        migrateAppConfigKeys(from: defaults, existingKeys: &existingKeys)
        migrateRawSettings(from: defaults, existingKeys: &existingKeys)
        migrateDynamicSettings(from: defaults, existingKeys: &existingKeys)
    }

    private static func hasMigrationCandidate(in defaults: UserDefaults) -> Bool {
        let keys = defaults.dictionaryRepresentation().keys
        for key in keys {
            if AppConfigKey(rawValue: key) != nil
                || rawSettingKeys.contains(key)
                || aliasedRawSettingKeys.contains(key)
                || key == GlobalSystemPromptStore.entriesStorageKey
                || key == GlobalSystemPromptStore.selectedEntryIDStorageKey
                || key == ChatAppearanceProfileStore.configurationStorageKey
                || key.hasPrefix("requestBodyControls.state.model.")
                || key.hasPrefix("requestBodyControls.state.signature.")
                || key.hasPrefix("sync.delta.version-tracker.")
                || key.hasPrefix("sync.delta.checkpoint.")
                || key.hasPrefix("achievementJournal.unlock.") {
                return true
            }
        }
        return false
    }

    private static let rawSettingKeys: Set<String> = [
        "tool.permission.autoApproveEnabled",
        "tts.autoPlayAfterAssistantResponse",
        "tts.onlyReadQuotedContent",
        "tts.watchUseLightweightPreprocess",
        "networkProxy.global.isEnabled",
        "dailyPulse.enabled",
        "dailyPulse.autoGenerate",
        "dailyPulse.includeMCPContext",
        "dailyPulse.includeShortcutContext",
        "dailyPulse.includeRecentExternalResults",
        "dailyPulse.includeTrendContext",
        "dailyPulse.delivery.reminderEnabled",
        "skills.chatToolsEnabled",
        "tool.permission.autoApproveCountdownSeconds",
        "tts.watchSpeechMaxCharacters",
        "networkProxy.global.port",
        "dailyPulse.delivery.reminderHour",
        "dailyPulse.delivery.reminderMinute",
        "tts.speechRate",
        "tts.pitch",
        "tts.playbackSpeed",
        "tts.playbackMode",
        "tts.providerKind",
        "tts.voice",
        "tts.responseFormat",
        "tts.languageType",
        "tts.miniMaxEmotion",
        "networkProxy.global.type",
        "networkProxy.global.host",
        "networkProxy.global.username",
        "networkProxy.global.password",
        "dailyPulse.focusText",
        "dailyPulse.lastViewedDayKey",
        "dailyPulse.lastDeliveryAttemptDayKey",
        "dailyPulse.delivery.lastReadyDayKey",
        "cloudSync.deviceIdentifier",
        "tool.permission.disabledAutoApproveTools",
        "skills.enabledNames",
        "cloudSync.appliedSnapshotChecksums",
        "cloudSync.snapshotChangeToken",
        "requestBodyControls.state.inherited",
        "enableCustomUserBubbleColor",
        "customUserBubbleColorHex",
        "enableCustomAssistantBubbleColor",
        "customAssistantBubbleColorHex",
        "enableCustomLightTextColor",
        "customLightTextColorHex",
        "enableCustomDarkTextColor",
        "customDarkTextColorHex"
    ]

    private static let aliasedRawSettingKeys: Set<String> = [
        "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated.v1"
    ]

    private static func migrateAppConfigKeys(
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        let syncGlobalPromptLegacy = defaults.object(forKey: AppConfigKey.syncGlobalPrompt.rawValue)
        for key in AppConfigKey.allCases {
            migrateAppConfigKey(key, from: defaults, existingKeys: &existingKeys)
        }

        if !existingKeys.contains(AppConfigKey.syncAppStorage.rawValue),
           defaults.object(forKey: AppConfigKey.syncAppStorage.rawValue) == nil,
           let object = syncGlobalPromptLegacy,
           let legacy = appConfigValue(from: object, for: .syncAppStorage),
           write(legacy, forRawKey: AppConfigKey.syncAppStorage.rawValue) {
            existingKeys.insert(AppConfigKey.syncAppStorage.rawValue)
        }
    }

    private static func migrateAppConfigKey(
        _ key: AppConfigKey,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        let rawKey = key.rawValue
        guard let object = defaults.object(forKey: rawKey) else { return }

        if existingKeys.contains(rawKey) {
            defaults.removeObject(forKey: rawKey)
            return
        }

        guard let value = appConfigValue(from: object, for: key) else {
            defaults.removeObject(forKey: rawKey)
            return
        }

        guard write(value, forRawKey: rawKey) else { return }
        existingKeys.insert(rawKey)
        defaults.removeObject(forKey: rawKey)
    }

    private static func migrateRawSettings(
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        [
            "tool.permission.autoApproveEnabled",
            "tts.autoPlayAfterAssistantResponse",
            "tts.onlyReadQuotedContent",
            "tts.watchUseLightweightPreprocess",
            "networkProxy.global.isEnabled",
            "dailyPulse.enabled",
            "dailyPulse.autoGenerate",
            "dailyPulse.includeMCPContext",
            "dailyPulse.includeShortcutContext",
            "dailyPulse.includeRecentExternalResults",
            "dailyPulse.includeTrendContext",
            "dailyPulse.delivery.reminderEnabled",
            "skills.chatToolsEnabled"
        ].forEach { migrateBool($0, from: defaults, existingKeys: &existingKeys) }

        [
            "tool.permission.autoApproveCountdownSeconds",
            "tts.watchSpeechMaxCharacters",
            "networkProxy.global.port",
            "dailyPulse.delivery.reminderHour",
            "dailyPulse.delivery.reminderMinute"
        ].forEach { migrateInteger($0, from: defaults, existingKeys: &existingKeys) }

        [
            "tts.speechRate",
            "tts.pitch",
            "tts.playbackSpeed"
        ].forEach { migrateReal($0, from: defaults, existingKeys: &existingKeys) }

        [
            "tts.playbackMode",
            "tts.providerKind",
            "tts.voice",
            "tts.responseFormat",
            "tts.languageType",
            "tts.miniMaxEmotion",
            "networkProxy.global.type",
            "networkProxy.global.host",
            "networkProxy.global.username",
            "networkProxy.global.password",
            "dailyPulse.focusText",
            "dailyPulse.lastViewedDayKey",
            "dailyPulse.lastDeliveryAttemptDayKey",
            "dailyPulse.delivery.lastReadyDayKey",
            "cloudSync.deviceIdentifier"
        ].forEach { migrateText($0, from: defaults, existingKeys: &existingKeys) }

        [
            "tool.permission.disabledAutoApproveTools",
            "skills.enabledNames"
        ].forEach { migrateStringArray($0, from: defaults, existingKeys: &existingKeys) }

        [
            "cloudSync.appliedSnapshotChecksums",
            "cloudSync.snapshotChangeToken"
        ].forEach { migrateData($0, from: defaults, existingKeys: &existingKeys) }

        migrateBool(
            "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated.v1",
            to: AppConfigKey.configLoaderToolCapabilityMigrated.rawValue,
            from: defaults,
            existingKeys: &existingKeys
        )
    }

    private static func migrateDynamicSettings(
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        let keys = Array(defaults.dictionaryRepresentation().keys)
        for key in keys {
            if key == "requestBodyControls.state.inherited"
                || key.hasPrefix("requestBodyControls.state.model.")
                || key.hasPrefix("requestBodyControls.state.signature.") {
                migrateUTF8DataText(key, from: defaults, existingKeys: &existingKeys)
            } else if key.hasPrefix("sync.delta.version-tracker.")
                        || key.hasPrefix("sync.delta.checkpoint.") {
                migrateData(key, from: defaults, existingKeys: &existingKeys)
            } else if key.hasPrefix("achievementJournal.unlock.") {
                migrateUTF8DataText(key, from: defaults, existingKeys: &existingKeys)
            }
        }
    }

    private static func migrateBool(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard defaults.object(forKey: key) != nil else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(
            key: key,
            integer: defaults.bool(forKey: key) ? 1 : 0,
            typeHint: "bool"
        ) else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateBool(
        _ legacyKey: String,
        to appConfigKey: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard defaults.object(forKey: legacyKey) != nil else { return }
        if existingKeys.contains(appConfigKey) {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        guard Persistence.writeAppConfig(
            key: appConfigKey,
            integer: defaults.bool(forKey: legacyKey) ? 1 : 0,
            typeHint: "bool"
        ) else { return }
        existingKeys.insert(appConfigKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private static func migrateInteger(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let object = defaults.object(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard let value = coerceInt(object) else {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, integer: value, typeHint: "integer") else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateReal(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let object = defaults.object(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard let value = coerceDouble(object) else {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, real: value, typeHint: "real") else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateText(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let value = defaults.string(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, text: value, typeHint: "text") else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateStringArray(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let value = defaults.stringArray(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard let encoded = encodeStringArray(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text") else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateData(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let data = defaults.data(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, data: data) else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    private static func migrateUTF8DataText(
        _ key: String,
        from defaults: UserDefaults,
        existingKeys: inout Set<String>
    ) {
        guard let data = defaults.data(forKey: key) else { return }
        if existingKeys.contains(key) {
            defaults.removeObject(forKey: key)
            return
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            defaults.removeObject(forKey: key)
            return
        }
        guard Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text") else { return }
        existingKeys.insert(key)
        defaults.removeObject(forKey: key)
    }

    @discardableResult
    private static func write(_ value: AppConfigValue, forRawKey rawKey: String) -> Bool {
        switch value {
        case .bool(let value):
            return Persistence.writeAppConfig(key: rawKey, integer: value ? 1 : 0, typeHint: "bool")
        case .integer(let value):
            return Persistence.writeAppConfig(key: rawKey, integer: value, typeHint: "integer")
        case .real(let value):
            return Persistence.writeAppConfig(key: rawKey, real: value, typeHint: "real")
        case .text(let value):
            return Persistence.writeAppConfig(key: rawKey, text: value, typeHint: "text")
        }
    }

    private static func appConfigValue(from object: Any, for key: AppConfigKey) -> AppConfigValue? {
        switch key.defaultValue {
        case .bool:
            return coerceBool(object).map(AppConfigValue.bool)
        case .integer:
            return coerceInt(object).map(AppConfigValue.integer)
        case .real:
            return coerceDouble(object).map(AppConfigValue.real)
        case .text:
            if let values = object as? [String] {
                return encodeStringArray(values).map(AppConfigValue.text)
            }
            if let values = object as? [String: String] {
                return encodeStringDictionary(values).map(AppConfigValue.text)
            }
            return coerceString(object).map(AppConfigValue.text)
        }
    }

    private static func encodeStringArray(_ values: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeStringDictionary(_ values: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func coerceBool(_ value: Any) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func coerceInt(_ value: Any) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func coerceDouble(_ value: Any) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func coerceString(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return value as String
        }
        return nil
    }
}
