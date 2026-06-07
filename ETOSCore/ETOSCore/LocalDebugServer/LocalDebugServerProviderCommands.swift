// ============================================================================
// LocalDebugServerProviderCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件为电脑端调试工具提供结构化的 Provider 与模型编辑命令。
// ============================================================================

import Foundation

extension LocalDebugServer {
    func handleProviderUpsert(_ json: [String: Any]) async -> [String: Any] {
        let providerID = parseDebugUUID(json["provider_id"] ?? json["id"])
        let name = trimmedDebugString(json["name"])
        let baseURL = trimmedDebugString(json["base_url"] ?? json["baseURL"])
        let apiFormat = trimmedDebugString(json["api_format"] ?? json["apiFormat"])

        var providers = ConfigLoader.loadProviders()
        let existingIndex = providerID.flatMap { id in providers.firstIndex(where: { $0.id == id }) }
        var provider: Provider

        if let existingIndex {
            provider = providers[existingIndex]
            if let name { provider.name = name }
            if let baseURL { provider.baseURL = baseURL }
            if let apiFormat { provider.apiFormat = apiFormat }
        } else {
            guard let name, !name.isEmpty else {
                return debugProviderError("新增 Provider 需要 name")
            }
            provider = Provider(
                id: providerID ?? UUID(),
                name: name,
                baseURL: baseURL ?? "",
                apiKeys: [],
                apiFormat: apiFormat ?? "openai-compatible"
            )
        }

        if let apiKeys = debugStringArray(json["api_keys"] ?? json["apiKeys"]) {
            provider.apiKeys = apiKeys
        } else if let apiKey = trimmedDebugString(json["api_key"] ?? json["apiKey"]) {
            provider.apiKeys = apiKey.isEmpty ? [] : [apiKey]
        }
        if let headerOverrides = debugStringDictionary(json["header_overrides"] ?? json["headerOverrides"]) {
            provider.headerOverrides = headerOverrides
        }

        if let existingIndex {
            providers[existingIndex] = provider
        } else {
            providers.append(provider)
        }
        ConfigLoader.saveProvider(provider)
        ChatService.shared.reloadProviders()

        do {
            return [
                "status": "ok",
                "message": existingIndex == nil ? "Provider 已新增" : "Provider 已更新",
                "provider": try encodeWebConsoleJSONObject(provider),
                "count": providers.count
            ]
        } catch {
            return debugProviderError("Provider 序列化失败：\(error.localizedDescription)")
        }
    }

    func handleProviderModelUpsert(_ json: [String: Any]) async -> [String: Any] {
        guard let providerID = parseDebugUUID(json["provider_id"] ?? json["providerID"]) else {
            return debugProviderError("缺少或无效的 provider_id")
        }

        var providers = ConfigLoader.loadProviders()
        guard let providerIndex = providers.firstIndex(where: { $0.id == providerID }) else {
            return debugProviderError("未找到 Provider")
        }

        var provider = providers[providerIndex]
        let modelID = parseDebugUUID(json["model_id"] ?? json["id"])
        let existingIndex = modelID.flatMap { id in provider.models.firstIndex(where: { $0.id == id }) }
        let modelName = trimmedDebugString(json["model_name"] ?? json["modelName"])
        let displayName = trimmedDebugString(json["display_name"] ?? json["displayName"])
        let overrideParametersRaw = json["override_parameters"] ?? json["overrideParameters"]
        let overrideParameters = tryDecodeDebugJSONValueDictionary(overrideParametersRaw)
        if overrideParametersRaw != nil && overrideParameters == nil {
            return debugProviderError("override_parameters 必须是 JSON 对象")
        }

        var model: Model
        if let existingIndex {
            model = provider.models[existingIndex]
            if let modelName { model.modelName = modelName }
            if let displayName { model.displayName = displayName }
        } else {
            guard let modelName, !modelName.isEmpty else {
                return debugProviderError("新增模型需要 model_name")
            }
            model = Model(
                id: modelID ?? UUID(),
                modelName: modelName,
                displayName: displayName?.isEmpty == false ? displayName : modelName,
                isActivated: true
            )
        }

        if let isActivated = debugProviderBool(json["is_activated"] ?? json["isActivated"]) {
            model.isActivated = isActivated
        }
        if let kindRaw = trimmedDebugString(json["kind"]),
           let kind = ModelKind(rawValue: kindRaw) {
            model.kind = kind
        }
        if let capabilityValues = debugStringArray(json["capabilities"]) {
            let capabilities = capabilityValues.compactMap(ModelCapability.init(rawValue:))
            model.capabilities = Model.orderedCapabilities(capabilities)
        }
        if let overrideParameters {
            model.overrideParameters = overrideParameters
        }

        if let existingIndex {
            provider.models[existingIndex] = model
        } else {
            provider.models.append(model)
        }
        providers[providerIndex] = provider
        ConfigLoader.saveProvider(provider)
        ChatService.shared.reloadProviders()

        do {
            return [
                "status": "ok",
                "message": existingIndex == nil ? "模型已新增" : "模型已更新",
                "provider": try encodeWebConsoleJSONObject(provider),
                "model": try encodeWebConsoleJSONObject(model)
            ]
        } catch {
            return debugProviderError("模型序列化失败：\(error.localizedDescription)")
        }
    }

    private func parseDebugUUID(_ value: Any?) -> UUID? {
        guard let raw = trimmedDebugString(value), !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    private func trimmedDebugString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func debugStringArray(_ value: Any?) -> [String]? {
        switch value {
        case let values as [String]:
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        case let values as [Any]:
            return values.map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return trimmed
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return nil
        }
    }

    private func debugStringDictionary(_ value: Any?) -> [String: String]? {
        if let dictionary = value as? [String: String] {
            return dictionary
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary.reduce(into: [String: String]()) { result, item in
            result[item.key] = "\(item.value)"
        }
    }

    private func tryDecodeDebugJSONValueDictionary(_ value: Any?) -> [String: JSONValue]? {
        guard let value else { return nil }
        if value is NSNull { return [:] }
        if let dictionary = value as? [String: JSONValue] {
            return dictionary
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [:] }
            guard let data = trimmed.data(using: .utf8) else { return nil }
            return try? makeWebConsoleJSONDecoder().decode([String: JSONValue].self, from: data)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? makeWebConsoleJSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func debugProviderBool(_ value: Any?) -> Bool? {
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

    private func debugProviderError(_ message: String) -> [String: Any] {
        [
            "status": "error",
            "error_code": "INVALID_ARGS",
            "message": message
        ]
    }
}
