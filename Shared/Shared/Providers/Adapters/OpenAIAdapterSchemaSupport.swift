// ============================================================================
// OpenAIAdapterSchemaSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// OpenAI 兼容适配器的工具名、JSON Schema 与参数覆盖辅助逻辑。
// ============================================================================

import CryptoKit
import Foundation

extension OpenAIAdapter {
    static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    func normalizedOpenAIToolParameters(_ parameters: [String: Any]) -> [String: Any] {
        normalizedOpenAISchemaValue(parameters) as? [String: Any] ?? parameters
    }

    func normalizedOpenAISchemaValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return normalizedOpenAISchemaObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.map { normalizedOpenAISchemaValue($0) }
        }
        return value
    }

    func normalizedOpenAISchemaObject(_ object: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(object.count)
        for (key, value) in object {
            if key == "properties", let properties = value as? [String: Any] {
                normalized[key] = properties
            } else {
                normalized[key] = normalizedOpenAISchemaValue(value)
            }
        }
        normalized = flattenedOpenAISchemaCombinators(normalized)
        if let properties = normalized["properties"] as? [String: Any] {
            normalized["properties"] = normalizedOpenAISchemaPropertiesMap(properties)
        }
        if normalized["default"] is NSNull {
            normalized.removeValue(forKey: "default")
        }

        if let normalizedType = normalizedOpenAISchemaTypeValue(normalized["type"]) {
            normalized["type"] = normalizedType
        } else if normalized["type"] != nil {
            normalized.removeValue(forKey: "type")
        }

        if normalized["type"] == nil {
            if normalized["properties"] is [String: Any]
                || normalized["required"] is [Any]
                || normalized["additionalProperties"] != nil {
                normalized["type"] = "object"
            } else if normalized["items"] != nil {
                normalized["type"] = "array"
            } else if let enumValues = normalized["enum"] as? [Any],
                      let inferred = inferredOpenAISchemaType(fromEnum: enumValues) {
                normalized["type"] = inferred
            } else if let constValue = normalized["const"],
                      let inferred = inferredOpenAISchemaType(fromValue: constValue) {
                normalized["type"] = inferred
            } else if let inferred = inferredOpenAISchemaTypeFromCombinators(normalized) {
                normalized["type"] = inferred
            } else if looksLikeOpenAILeafSchema(normalized) {
                normalized["type"] = "string"
            }
        }

        return normalized
    }

    func flattenedOpenAISchemaCombinators(_ object: [String: Any]) -> [String: Any] {
        var flattened = object

        if let rawAnyOf = flattened["anyOf"] as? [Any] {
            let options = normalizedOpenAISchemaOptions(from: rawAnyOf)
            flattened.removeValue(forKey: "anyOf")
            if let preferred = preferredOpenAISchemaOption(from: options) {
                flattened = mergedOpenAISchema(base: flattened, overlay: preferred)
            }
        }

        if let rawOneOf = flattened["oneOf"] as? [Any] {
            let options = normalizedOpenAISchemaOptions(from: rawOneOf)
            flattened.removeValue(forKey: "oneOf")
            if let preferred = preferredOpenAISchemaOption(from: options) {
                flattened = mergedOpenAISchema(base: flattened, overlay: preferred)
            }
        }

        if let rawAllOf = flattened["allOf"] as? [Any] {
            let options = normalizedOpenAISchemaOptions(from: rawAllOf)
            flattened.removeValue(forKey: "allOf")
            for option in options {
                flattened = mergedOpenAISchema(base: flattened, overlay: option)
            }
        }

        return flattened
    }

    func normalizedOpenAISchemaOptions(from rawOptions: [Any]) -> [[String: Any]] {
        rawOptions.compactMap { raw in
            if let schema = raw as? [String: Any] {
                return schema
            }
            if let normalizedType = normalizedOpenAISchemaTypeValue(raw) {
                return ["type": normalizedType]
            }
            if let inferredType = inferredOpenAISchemaType(fromValue: raw) {
                return ["type": inferredType]
            }
            return nil
        }
    }

    func preferredOpenAISchemaOption(from options: [[String: Any]]) -> [String: Any]? {
        let candidates = options.filter { !$0.isEmpty }
        if let typed = candidates.first(where: { normalizedOpenAISchemaTypeValue($0["type"]) != nil }) {
            return typed
        }
        if let explicit = candidates.first(where: {
            $0["enum"] != nil || $0["const"] != nil || $0["properties"] != nil || $0["items"] != nil
        }) {
            return explicit
        }
        return candidates.first
    }

    func mergedOpenAISchema(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in overlay where merged[key] == nil {
            merged[key] = value
        }

        if let baseRequired = merged["required"] as? [Any],
           let overlayRequired = overlay["required"] as? [Any] {
            var seen = Set<String>()
            var mergedRequired: [Any] = []
            for item in baseRequired + overlayRequired {
                if let text = item as? String {
                    if seen.insert(text).inserted {
                        mergedRequired.append(text)
                    }
                } else {
                    mergedRequired.append(item)
                }
            }
            merged["required"] = mergedRequired
        }

        return merged
    }

    func normalizedOpenAISchemaPropertiesMap(_ properties: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(properties.count)
        for (key, value) in properties {
            normalized[key] = normalizedOpenAISchemaPropertyValue(value)
        }
        return normalized
    }

    func normalizedOpenAISchemaPropertyValue(_ value: Any) -> Any {
        if let schema = value as? [String: Any] {
            return normalizedOpenAISchemaObject(schema)
        }
        if let normalizedType = normalizedOpenAISchemaTypeValue(value) {
            return ["type": normalizedType]
        }
        if let inferredType = inferredOpenAISchemaType(fromValue: value) {
            return ["type": inferredType]
        }
        return ["type": "string"]
    }

    func normalizedOpenAISchemaTypeKeyword(_ type: String) -> String? {
        let lowered = type.lowercased()
        guard lowered != "null" else { return nil }
        let supportedTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array"]
        guard supportedTypes.contains(lowered) else { return nil }
        return lowered
    }

    func normalizedOpenAISchemaTypeValue(_ rawType: Any?) -> String? {
        guard let rawType else { return nil }
        if let type = rawType as? String {
            return normalizedOpenAISchemaTypeKeyword(type)
        }
        if let typeArray = rawType as? [Any] {
            for value in typeArray {
                guard let type = value as? String else { continue }
                if let normalized = normalizedOpenAISchemaTypeKeyword(type) {
                    return normalized
                }
            }
        }
        return nil
    }

    func inferredOpenAISchemaType(fromEnum values: [Any]) -> String? {
        let nonNullValues = values.filter { !($0 is NSNull) }
        guard let firstValue = nonNullValues.first else { return nil }
        guard let inferred = inferredOpenAISchemaType(fromValue: firstValue) else { return nil }
        for value in nonNullValues.dropFirst() where inferredOpenAISchemaType(fromValue: value) != inferred {
            return nil
        }
        return inferred
    }

    func inferredOpenAISchemaType(fromValue value: Any) -> String? {
        if value is String {
            return "string"
        }
        if value is Bool {
            return "boolean"
        }
        if value is Int || value is Int8 || value is Int16 || value is Int32 || value is Int64
            || value is UInt || value is UInt8 || value is UInt16 || value is UInt32 || value is UInt64 {
            return "integer"
        }
        if value is Float || value is Double || value is Decimal {
            return "number"
        }
        if value is [Any] {
            return "array"
        }
        if value is [String: Any] {
            return "object"
        }
        if let number = value as? NSNumber {
            let objCType = String(cString: number.objCType)
            if objCType == "c" || objCType == "B" {
                return "boolean"
            }
            if ["q", "i", "s", "l", "Q", "I", "S", "L", "C"].contains(objCType) {
                return "integer"
            }
            let doubleValue = number.doubleValue
            return floor(doubleValue) == doubleValue ? "integer" : "number"
        }
        return nil
    }

    func inferredOpenAISchemaTypeFromCombinators(_ object: [String: Any]) -> String? {
        let combinatorKeys = ["anyOf", "oneOf", "allOf"]
        for key in combinatorKeys {
            guard let options = object[key] as? [Any], !options.isEmpty else { continue }
            let inferredTypes = options.compactMap { option -> String? in
                guard let schema = option as? [String: Any] else { return nil }
                if let directType = normalizedOpenAISchemaTypeValue(schema["type"]) {
                    return directType
                }
                if let enumValues = schema["enum"] as? [Any],
                   let inferred = inferredOpenAISchemaType(fromEnum: enumValues) {
                    return inferred
                }
                if let constValue = schema["const"],
                   let inferred = inferredOpenAISchemaType(fromValue: constValue) {
                    return inferred
                }
                return inferredOpenAISchemaTypeFromCombinators(schema)
            }

            guard let first = inferredTypes.first else { continue }
            if inferredTypes.allSatisfy({ $0 == first }) {
                return first
            }
        }
        return nil
    }

    func looksLikeOpenAILeafSchema(_ object: [String: Any]) -> Bool {
        let leafHints: Set<String> = [
            "description",
            "title",
            "default",
            "examples",
            "example",
            "pattern",
            "format",
            "minLength",
            "maxLength",
            "minimum",
            "maximum",
            "exclusiveMinimum",
            "exclusiveMaximum",
            "multipleOf",
            "minItems",
            "maxItems",
            "uniqueItems",
            "nullable",
            "deprecated",
            "readOnly",
            "writeOnly",
            "contentMediaType",
            "contentEncoding"
        ]
        return !leafHints.isDisjoint(with: Set(object.keys))
    }

    func sanitizedImageGenerationOverrides(_ overrides: [String: Any]) -> [String: Any] {
        let blockedKeys: Set<String> = [
            "messages",
            "tools",
            "tool_choice",
            "functions",
            "function_call",
            "parallel_tool_calls",
            "stream",
            "stream_options"
        ]
        return sanitizedOpenAIControlOverrides(overrides).filter { !blockedKeys.contains($0.key) }
    }

    func sanitizedOpenAIControlOverrides(_ overrides: [String: Any]) -> [String: Any] {
        overrides.filter { !Self.openAIControlOverrideKeys.contains($0.key) }
    }

    func removeOpenAIToolFields(from payload: inout [String: Any]) {
        payload.removeValue(forKey: "tools")
        payload.removeValue(forKey: "tool_choice")
        payload.removeValue(forKey: "functions")
        payload.removeValue(forKey: "function_call")
        payload.removeValue(forKey: "parallel_tool_calls")
    }

    func normalizedOpenAIConversationAPIValue(_ rawValue: String) -> OpenAIConversationAPI? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "responses", "response":
            return .responses
        case "chat", "chat_completion", "chat_completions":
            return .chatCompletions
        default:
            return nil
        }
    }

    func boolValue(from rawValue: Any?) -> Bool? {
        switch rawValue {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func resolvedConversationAPI(for overrides: [String: Any]) -> OpenAIConversationAPI {
        if let rawValue = overrides["openai_api"] as? String,
           let mode = normalizedOpenAIConversationAPIValue(rawValue) {
            return mode
        }
        if let rawValue = overrides["openai_api_mode"] as? String,
           let mode = normalizedOpenAIConversationAPIValue(rawValue) {
            return mode
        }
        if let useResponses = boolValue(from: overrides["use_responses_api"]) {
            return useResponses ? .responses : .chatCompletions
        }
        if overrides.keys.contains(where: { Self.responsesModeSignalKeys.contains($0) }) {
            return .responses
        }
        return .chatCompletions
    }

    func sanitizedChatCompletionsOverrides(_ overrides: [String: Any]) -> [String: Any] {
        sanitizedOpenAIControlOverrides(overrides).filter { !Self.responsesModeSignalKeys.contains($0.key) }
    }

    func sanitizedResponsesOverrides(_ overrides: [String: Any]) -> [String: Any] {
        let stripped = sanitizedOpenAIControlOverrides(overrides).filter { !Self.chatCompletionsOnlyKeys.contains($0.key) }
        var sanitized = stripped
        if sanitized["max_output_tokens"] == nil, let legacyMaxTokens = stripped["max_tokens"] {
            sanitized["max_output_tokens"] = legacyMaxTokens
        }
        sanitized.removeValue(forKey: "max_tokens")
        sanitized.removeValue(forKey: "input")
        return sanitized
    }

    func jsonValue(fromJSONObject object: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return value
    }

    func sanitizedPayloadForDebug(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            sanitized.reserveCapacity(dictionary.count)
            for (key, rawValue) in dictionary {
                let loweredKey = key.lowercased()
                if loweredKey == "data" || loweredKey == "file_data" {
                    if let text = rawValue as? String {
                        sanitized[key] = "[base64 omitted: \(text.count) chars]"
                    } else {
                        sanitized[key] = "[binary omitted]"
                    }
                    continue
                }
                if (loweredKey == "url" || loweredKey == "image_url"),
                   let text = rawValue as? String,
                   text.hasPrefix("data:") {
                    sanitized[key] = "[base64 image omitted: \(text.count) chars]"
                    continue
                }
                sanitized[key] = sanitizedPayloadForDebug(rawValue)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitizedPayloadForDebug($0) }
        }
        return value
    }
}
