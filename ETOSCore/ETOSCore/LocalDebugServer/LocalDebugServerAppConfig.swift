// ============================================================================
// LocalDebugServerAppConfig.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接电脑端调试工具的应用配置读取与写入命令。
// ============================================================================

import Foundation

extension LocalDebugServer {
    func handleAppConfigList(_ json: [String: Any]) async -> [String: Any] {
        let query = (json["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let includeLocalOnly = Self.debugAppConfigBool(from: json["include_local_only"]) ?? true

        let settings = AppConfigKey.allCases.compactMap { key -> [String: Any]? in
            guard includeLocalOnly || key.participatesInSync else { return nil }
            let item = debugAppConfigItem(for: key)
            if query.isEmpty { return item }

            let rawKey = key.rawValue.lowercased()
            let group = (item["group"] as? String)?.lowercased() ?? ""
            let valueText = (item["value_text"] as? String)?.lowercased() ?? ""
            return rawKey.contains(query) || group.contains(query) || valueText.contains(query) ? item : nil
        }

        return [
            "status": "ok",
            "settings": settings,
            "count": settings.count
        ]
    }

    func handleAppConfigSet(_ json: [String: Any]) async -> [String: Any] {
        guard let rawKey = (json["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = AppConfigKey(rawValue: rawKey) else {
            return debugAppConfigError("缺少或无效的 key")
        }
        guard let rawValue = json["value"],
              let value = debugAppConfigValue(from: rawValue, for: key) else {
            return debugAppConfigError("value 与配置类型不匹配")
        }

        guard AppConfigStore.persistSynchronously(value, for: key) else {
            return debugAppConfigError("写入配置失败")
        }
        AppConfigStore.shared.reloadFromPersistentStore()

        return [
            "status": "ok",
            "message": "配置已保存",
            "setting": debugAppConfigItem(for: key)
        ]
    }

    private func debugAppConfigItem(for key: AppConfigKey) -> [String: Any] {
        let value = currentDebugAppConfigValue(for: key)
        let defaultValue = key.defaultValue
        return [
            "key": key.rawValue,
            "group": debugAppConfigGroup(for: key),
            "type": key.typeHint,
            "value": value.anyValue,
            "value_text": debugAppConfigValueText(value),
            "default_value": defaultValue.anyValue,
            "default_value_text": debugAppConfigValueText(defaultValue),
            "participates_in_sync": key.participatesInSync
        ]
    }

    private func currentDebugAppConfigValue(for key: AppConfigKey) -> AppConfigValue {
        let snapshot = AppConfigStore.persistentSnapshot(includeLocalOnly: true)
        return debugAppConfigValue(from: snapshot[key.rawValue], for: key) ?? key.defaultValue
    }

    private func debugAppConfigValue(from rawValue: Any?, for key: AppConfigKey) -> AppConfigValue? {
        switch key.defaultValue {
        case .bool:
            return Self.debugAppConfigBool(from: rawValue).map(AppConfigValue.bool)
        case .integer:
            return Self.debugAppConfigInt(from: rawValue).map(AppConfigValue.integer)
        case .real:
            return Self.debugDouble(from: rawValue).map(AppConfigValue.real)
        case .text:
            if let rawValue = rawValue as? String {
                return .text(rawValue)
            }
            guard let rawValue,
                  JSONSerialization.isValidJSONObject(rawValue),
                  let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return .text(text)
        }
    }

    private func debugAppConfigGroup(for key: AppConfigKey) -> String {
        let rawKey = key.rawValue
        if let first = rawKey.split(separator: ".", maxSplits: 1).first {
            return String(first)
        }
        if rawKey.hasPrefix("ai") { return "ai" }
        if rawKey.hasPrefix("enable") { return "feature" }
        return "general"
    }

    private func debugAppConfigValueText(_ value: AppConfigValue) -> String {
        switch value {
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return "\(value)"
        case .real(let value):
            return "\(value)"
        case .text(let value):
            return value
        }
    }

    private func debugAppConfigError(_ message: String) -> [String: Any] {
        [
            "status": "error",
            "error_code": "INVALID_ARGS",
            "message": message
        ]
    }

    nonisolated private static func debugAppConfigBool(from value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "off"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    nonisolated private static func debugAppConfigInt(from value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    nonisolated private static func debugDouble(from value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
