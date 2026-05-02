import Foundation
import CryptoKit

extension ThirdPartyImportService {
    static func withSecurityScopedAccess<T>(to fileURL: URL, action: () throws -> T) throws -> T {
        let didStart = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        return try action()
    }

    static func tryParseDictionaryJSON(from fileURL: URL) -> [String: Any]? {
        guard !isDirectory(fileURL),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return tryParseDictionaryJSON(data)
    }

    static func tryParseDictionaryJSON(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func parseJSONStringToDictionary(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return tryParseDictionaryJSON(data)
    }

    static func findFirstDictionaryJSON(
        inDirectory directoryURL: URL,
        where predicate: ([String: Any]) -> Bool
    ) throws -> [String: Any]? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            guard fileURL.pathExtension.lowercased() == "json",
                  let parsed = tryParseDictionaryJSON(from: fileURL) else {
                continue
            }
            if predicate(parsed) {
                return parsed
            }
        }

        return nil
    }

    static func findJSONInDirectory(
        _ directoryURL: URL,
        preferredNames: [String]
    ) -> [String: Any]? {
        guard let fileURL = findFileInDirectory(directoryURL, preferredNames: preferredNames) else {
            return nil
        }
        return tryParseDictionaryJSON(from: fileURL)
    }

    static func findFileInDirectory(
        _ directoryURL: URL,
        preferredNames: [String]
    ) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let nameSet = Set(preferredNames.map { $0.lowercased() })
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            if nameSet.contains(fileURL.lastPathComponent.lowercased()) {
                return fileURL
            }
        }

        return nil
    }

    static func findETOSJSONFile(inDirectory directoryURL: URL) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var fallback: URL?
        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            if fileURL.lastPathComponent.hasPrefix("ETOS-数据导出-") {
                return fileURL
            }
            fallback = fallback ?? fileURL
        }

        return fallback
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    static func isLikelyCompressedBackup(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext == "zip" || ext == "bak"
    }

    static func normalizeProviderFormat(typeHint: String?, modelIDs: [String]) -> String {
        let hint = (typeHint ?? "").lowercased()

        if !hint.isEmpty {
            if hint.contains("anthropic") || hint.contains("claude") {
                return "anthropic"
            }
            if hint.contains("gemini") || hint.contains("google") || hint.contains("vertex") {
                return "gemini"
            }
            return "openai-compatible"
        }

        let joinedModels = modelIDs.joined(separator: " ").lowercased()
        if joinedModels.contains("claude") {
            return "anthropic"
        }
        if joinedModels.contains("gemini") {
            return "gemini"
        }
        return "openai-compatible"
    }

    static func isOpenAIResponsesType(_ raw: String?) -> Bool {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return normalized == "openai-response" || normalized == "openai-responses"
    }

    struct ImportedModelCapabilityShape {
        var kind: ModelKind?
        var inputModalities: [ModelModality]?
        var outputModalities: [ModelModality]?
        var capabilities: [ModelCapability]?
    }

    static func importedModel(
        modelName: String,
        displayName: String,
        isActivated: Bool,
        useResponsesAPI: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        kind: ModelKind? = .chat,
        inputModalities: [ModelModality]? = nil,
        outputModalities: [ModelModality]? = nil,
        capabilities: [ModelCapability]? = nil
    ) -> Model {
        var mergedOverrideParameters = overrideParameters
        if useResponsesAPI {
            mergedOverrideParameters["use_responses_api"] = .bool(true)
        }
        let resolvedCapabilities = capabilities ?? (kind == .chat ? Model.defaultCapabilities : nil)
        return Model(
            modelName: modelName,
            displayName: displayName,
            isActivated: isActivated,
            overrideParameters: mergedOverrideParameters,
            kind: kind,
            inputModalities: inputModalities,
            outputModalities: outputModalities,
            capabilities: resolvedCapabilities
        )
    }

    static func cherryModelCapabilityShape(_ model: [String: Any]) -> ImportedModelCapabilityShape {
        let endpointType = normalizedTypeString(string(model["endpoint_type"]))
        let capabilityTypes = cherryCapabilityTypes(from: model["capabilities"], includeDisabled: false)
            .union(cherryLegacyTypeValues(from: model["type"]))

        if endpointType == "image-generation" {
            return ImportedModelCapabilityShape(kind: .image)
        }
        if endpointType == "jina-rerank" || capabilityTypes.contains("rerank") {
            return ImportedModelCapabilityShape(kind: .rerank)
        }
        if capabilityTypes.contains("embedding") {
            return ImportedModelCapabilityShape(kind: .embedding)
        }

        var inputModalities: [ModelModality]?
        if capabilityTypes.contains("vision") {
            inputModalities = [.text, .image]
        }

        let functionCallingSelection = cherryCapabilitySelection(
            from: model["capabilities"],
            legacyTypes: model["type"],
            matching: ["function-calling", "tool-calling"]
        )
        let reasoningSelection = cherryCapabilitySelection(
            from: model["capabilities"],
            legacyTypes: model["type"],
            matching: ["reasoning"]
        )

        var capabilities: [ModelCapability]?
        if functionCallingSelection != nil || reasoningSelection != nil {
            var capabilitySet = Set<ModelCapability>()
            if functionCallingSelection != false {
                capabilitySet.insert(.toolCalling)
            }
            if reasoningSelection == true {
                capabilitySet.insert(.reasoning)
            }
            capabilities = Model.orderedCapabilities(Array(capabilitySet))
        }

        return ImportedModelCapabilityShape(
            kind: .chat,
            inputModalities: inputModalities,
            outputModalities: nil,
            capabilities: capabilities
        )
    }

    static func rikkaModelCapabilityShape(_ model: [String: Any]) -> ImportedModelCapabilityShape {
        let kind = modelKind(from: string(model["type"])) ?? .chat
        return ImportedModelCapabilityShape(
            kind: kind,
            inputModalities: modelModalities(from: model["inputModalities"], fieldPresent: model.keys.contains("inputModalities")),
            outputModalities: kind == .embedding
                ? nil
                : modelOutputModalities(from: model["outputModalities"], fieldPresent: model.keys.contains("outputModalities")),
            capabilities: kind == .embedding
                ? []
                : modelCapabilities(from: model["abilities"], fieldPresent: model.keys.contains("abilities"))
        )
    }

    static func kelivoModelCapabilityShape(_ override: [String: Any]) -> ImportedModelCapabilityShape {
        let kind = modelKind(from: string(override["type"])) ?? .chat
        return ImportedModelCapabilityShape(
            kind: kind,
            inputModalities: modelModalities(from: override["input"], fieldPresent: override.keys.contains("input")),
            outputModalities: kind == .embedding
                ? nil
                : modelOutputModalities(from: override["output"], fieldPresent: override.keys.contains("output")),
            capabilities: kind == .embedding
                ? []
                : modelCapabilities(from: override["abilities"], fieldPresent: override.keys.contains("abilities"))
        )
    }

    static func kelivoAPIModelID(from override: [String: Any]) -> String? {
        nonEmpty(string(override["apiModelId"]))
            ?? nonEmpty(string(override["api_model_id"]))
    }

    static func modelKind(from raw: String?) -> ModelKind? {
        switch normalizedTypeString(raw) {
        case "image", "image-generation":
            return .image
        case "embedding":
            return .embedding
        case "rerank":
            return .rerank
        case "chat", "text":
            return .chat
        default:
            return nil
        }
    }

    static func modelModalities(from raw: Any?, fieldPresent: Bool) -> [ModelModality]? {
        let values = normalizeStringArray(raw).compactMap { value -> ModelModality? in
            switch normalizedTypeString(value) {
            case "text": return .text
            case "image", "vision": return .image
            case "audio": return .audio
            case "file": return .file
            default: return nil
            }
        }
        if values.isEmpty {
            return fieldPresent ? [] : nil
        }
        return Model.orderedModalities(values)
    }

    static func modelOutputModalities(from raw: Any?, fieldPresent: Bool) -> [ModelModality]? {
        guard let modalities = modelModalities(from: raw, fieldPresent: fieldPresent) else { return nil }
        if modalities.isEmpty {
            return []
        }
        return Model.orderedOutputModalities(modalities)
    }

    static func modelCapabilities(from raw: Any?, fieldPresent: Bool) -> [ModelCapability]? {
        let values = normalizeStringArray(raw).compactMap { value -> ModelCapability? in
            switch normalizedTypeString(value) {
            case "tool", "tools", "function-calling", "tool-calling":
                return .toolCalling
            case "reasoning":
                return .reasoning
            default:
                return nil
            }
        }
        if values.isEmpty {
            return fieldPresent ? [] : nil
        }
        return Model.orderedCapabilities(values)
    }

    static func cherryCapabilityTypes(from raw: Any?, includeDisabled: Bool) -> Set<String> {
        Set(normalizeJSONArray(raw).compactMap { item -> String? in
            if let map = dictionary(item) {
                if !includeDisabled,
                   bool(map["isUserSelected"], defaultValue: true) == false {
                    return nil
                }
                return normalizedTypeString(string(map["type"]))
            }
            return normalizedTypeString(string(item))
        }.filter { !$0.isEmpty })
    }

    static func cherryCapabilitySelection(
        from raw: Any?,
        legacyTypes: Any?,
        matching targets: Set<String>
    ) -> Bool? {
        var result: Bool?
        for item in normalizeJSONArray(raw) {
            let rawType: String?
            let enabled: Bool
            if let map = dictionary(item) {
                rawType = string(map["type"])
                enabled = bool(map["isUserSelected"], defaultValue: true)
            } else {
                rawType = string(item)
                enabled = true
            }

            let type = normalizedTypeString(rawType)
            guard targets.contains(type) else { continue }
            result = enabled
        }
        if result == nil,
           !targets.isDisjoint(with: cherryLegacyTypeValues(from: legacyTypes)) {
            return true
        }
        return result
    }

    static func cherryLegacyTypeValues(from raw: Any?) -> Set<String> {
        Set(normalizeStringArray(raw).map(normalizedTypeString).filter { !$0.isEmpty })
    }

    static func customBodyOverrideParameters(
        from raw: Any?,
        parseStringValues: Bool = false
    ) -> [String: JSONValue] {
        var overrides: [String: JSONValue] = [:]
        for item in normalizeJSONArray(raw) {
            guard let map = dictionary(item),
                  let key = nonEmpty(string(map["key"]) ?? string(map["name"])) else {
                continue
            }

            let rawValue = map["value"] ?? NSNull()
            let value = parseStringValues
                ? jsonValueFromPossiblyEncodedString(rawValue)
                : jsonValue(from: rawValue)
            if let value {
                overrides[key] = value
            }
        }
        return overrides
    }

    static func jsonValueFromPossiblyEncodedString(_ raw: Any) -> JSONValue? {
        guard let text = raw as? String else {
            return jsonValue(from: raw)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" { return .null }
        if let intValue = Int(trimmed) { return .int(intValue) }
        if let doubleValue = Double(trimmed) { return .double(doubleValue) }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let value = jsonValue(from: object) {
                return value
            }
        }

        return .string(text)
    }

    static func jsonValue(from raw: Any) -> JSONValue? {
        switch raw {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as Float:
            return .double(Double(value))
        case let value as NSNumber:
            if String(cString: value.objCType) == "c" {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if doubleValue.rounded() == doubleValue {
                return .int(value.intValue)
            }
            return .double(doubleValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.compactMap(jsonValue(from:)))
        case let value as [String: Any]:
            return .dictionary(value.compactMapValues(jsonValue(from:)))
        default:
            return nil
        }
    }

    static func stringDictionary(_ raw: Any?) -> [String: String] {
        guard let dict = dictionary(raw) else { return [:] }
        return dict.reduce(into: [:]) { result, entry in
            guard let value = nonEmpty(string(entry.value)) else { return }
            result[entry.key] = value
        }
    }

    static func networkProxyConfiguration(from config: [String: Any]) -> NetworkProxyConfiguration? {
        guard bool(config["proxyEnabled"], defaultValue: false),
              let host = nonEmpty(string(config["proxyHost"])),
              let portText = nonEmpty(string(config["proxyPort"])),
              let port = Int(portText) else {
            return nil
        }

        let proxyType = NetworkProxyType(rawValue: normalizedTypeString(string(config["proxyType"]))) ?? .http
        return NetworkProxyConfiguration(
            isEnabled: true,
            type: proxyType,
            host: host,
            port: port,
            username: string(config["proxyUsername"]) ?? "",
            password: string(config["proxyPassword"]) ?? ""
        ).normalizedIfEnabled
    }

    static func normalizedTypeString(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    static func normalizeBaseURL(_ raw: String?, for apiFormat: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalized.isEmpty {
            switch apiFormat {
            case "anthropic":
                return "https://api.anthropic.com/v1"
            case "gemini":
                return "https://generativelanguage.googleapis.com/v1beta"
            default:
                return "https://api.openai.com/v1"
            }
        }

        let lower = normalized.lowercased()
        let hasVersion = lower.contains("/v1") || lower.contains("/v1beta") || lower.contains("/v2")
        if hasVersion {
            return normalized
        }

        switch apiFormat {
        case "anthropic":
            return normalized + "/v1"
        case "gemini":
            return normalized + "/v1beta"
        default:
            return normalized + "/v1"
        }
    }

    static func dedupeProviders(_ providers: [Provider]) -> [Provider] {
        var seen = Set<String>()
        var result: [Provider] = []
        result.reserveCapacity(providers.count)

        for provider in providers {
            let modelSignature = provider.models.map { model in
                [
                    model.modelName.lowercased(),
                    model.displayName.lowercased(),
                    model.isActivated ? "1" : "0",
                    model.kind.rawValue,
                    model.inputModalities.map(\.rawValue).joined(separator: ","),
                    model.outputModalities.map(\.rawValue).joined(separator: ","),
                    model.capabilities.map(\.rawValue).joined(separator: ","),
                    model.overrideParameters.keys.sorted().map { key in
                        "\(key)=\(model.overrideParameters[key]?.prettyPrintedCompact() ?? "")"
                    }.joined(separator: ",")
                ].joined(separator: ":")
            }.joined(separator: ";")
            let headerSignature = provider.headerOverrides.keys.sorted().map { key in
                "\(key)=\(provider.headerOverrides[key] ?? "")"
            }.joined(separator: ",")
            let proxySignature = provider.proxyConfiguration.map { proxy in
                [
                    proxy.type.rawValue,
                    proxy.host.lowercased(),
                    String(proxy.port),
                    proxy.username.lowercased()
                ].joined(separator: ":")
            } ?? ""
            let key = [
                provider.name.lowercased(),
                provider.baseURL.lowercased(),
                provider.apiFormat.lowercased(),
                provider.apiKeys.joined(separator: ","),
                headerSignature,
                proxySignature,
                modelSignature
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                result.append(provider)
            }
        }

        return result
    }

    static func splitAPIKeys(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n;")
        return dedupeStrings(
            raw
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func dedupeStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    static func mapMessageRole(_ raw: String?) -> MessageRole {
        switch (raw ?? "").lowercased() {
        case "system": return .system
        case "assistant", "model": return .assistant
        case "tool", "function": return .tool
        case "error": return .error
        default: return .user
        }
    }

    static func flattenText(_ any: Any?) -> String? {
        guard let any else { return nil }

        if let string = any as? String {
            return nonEmpty(string)
        }

        if let number = any as? NSNumber {
            return number.stringValue
        }

        if let list = any as? [Any] {
            let parts = list.compactMap { flattenText($0) }
            let merged = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return merged.isEmpty ? nil : merged
        }

        if let map = any as? [String: Any] {
            if let direct = nonEmpty(string(map["text"])) {
                return direct
            }
            if let direct = nonEmpty(string(map["content"])) {
                return direct
            }
            if let parts = flattenText(map["parts"]) {
                return parts
            }
            if let value = flattenText(map["value"]) {
                return value
            }
        }

        return nil
    }

    static func parseDate(_ any: Any?) -> Date? {
        guard let any else { return nil }

        if let date = any as? Date {
            return date
        }

        if let number = any as? NSNumber {
            return dateFromTimestamp(number.doubleValue)
        }

        if let string = any as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let numeric = Double(trimmed) {
                return dateFromTimestamp(numeric)
            }

            if let iso = ISO8601DateFormatter.full.date(from: trimmed) {
                return iso
            }
            if let basic = ISO8601DateFormatter.basic.date(from: trimmed) {
                return basic
            }
            if let parsed = ThirdPartyDateParser.shared.date(from: trimmed) {
                return parsed
            }
        }

        return nil
    }

    static func dateFromTimestamp(_ value: Double) -> Date {
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return Date(timeIntervalSince1970: value)
    }

    static func stableUUID(from raw: String?) -> UUID? {
        guard let raw = nonEmpty(raw) else { return nil }
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(raw.utf8))
        let bytes = Array(digest)
        guard bytes.count >= 16 else { return nil }
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
#else
        return nil
#endif
    }

    static func dictionary(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }

    static func normalizeJSONArray(_ any: Any?) -> [Any] {
        if let list = any as? [Any] {
            return list
        }
        if let dict = any as? [String: Any] {
            return Array(dict.values)
        }
        return []
    }

    static func normalizeStringArray(_ any: Any?) -> [String] {
        normalizeJSONArray(any)
            .compactMap { nonEmpty(string($0)) }
    }

    static func string(_ any: Any?) -> String? {
        if let string = any as? String { return string }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ any: Any?, defaultValue: Bool) -> Bool {
        if let value = any as? Bool {
            return value
        }
        if let value = any as? NSNumber {
            return value.boolValue
        }
        if let value = any as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return defaultValue
    }

    static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
enum ThirdPartyDateParser {
    static let shared = DateFormatterPool()

    final class DateFormatterPool {
        let formatters: [DateFormatter]

        init() {
            let patterns = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd"
            ]
            self.formatters = patterns.map { pattern in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = pattern
                return formatter
            }
        }

        func date(from value: String) -> Date? {
            for formatter in formatters {
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            return nil
        }
    }
}
extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
