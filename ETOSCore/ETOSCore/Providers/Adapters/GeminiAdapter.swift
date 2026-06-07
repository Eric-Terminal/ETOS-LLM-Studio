// ============================================================================
// GeminiAdapter.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Google Gemini 后端的请求构建、响应解析与流式事件处理。
// ============================================================================

import Foundation
import CryptoKit
import os.log

// MARK: - Gemini 适配器实现

/// `GeminiAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Google Gemini API。
/// Gemini API 使用 `contents`/`parts` 结构，系统提示使用独立的 `system_instruction` 字段。
public class GeminiAdapter: APIAdapter {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "GeminiAdapter")
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

    func normalizedGeminiBaseURL(from rawBaseURL: String) -> URL? {
        guard var components = URLComponents(string: rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        if components.host == "generativelanguage.googleapis.com" {
            var pathParts = components.path.split(separator: "/").map(String.init)
            if pathParts.last?.lowercased() == "openai" {
                pathParts.removeLast()
                components.path = pathParts.isEmpty ? "" : "/" + pathParts.joined(separator: "/")
            }
        }
        return components.url
    }

    func normalizedGeminiToolParameters(_ parameters: [String: Any]) -> [String: Any] {
        normalizedGeminiSchemaValue(parameters) as? [String: Any] ?? parameters
    }

    func normalizedGeminiSchemaValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return normalizedGeminiSchemaObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.map { normalizedGeminiSchemaValue($0) }
        }
        return value
    }

    func normalizedGeminiSchemaObject(_ object: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(object.count)
        for (key, value) in object {
            if key == "properties", let properties = value as? [String: Any] {
                normalized[key] = properties
            } else {
                normalized[key] = normalizedGeminiSchemaValue(value)
            }
        }
        normalized = flattenedGeminiSchemaCombinators(normalized)
        if let properties = normalized["properties"] as? [String: Any] {
            normalized["properties"] = normalizedGeminiSchemaPropertiesMap(properties)
        }
        if normalized["default"] is NSNull {
            normalized.removeValue(forKey: "default")
        }
        if let enumValues = normalized["enum"] as? [Any] {
            let filteredEnumValues = enumValues.filter { !($0 is NSNull) }
            if filteredEnumValues.isEmpty {
                normalized.removeValue(forKey: "enum")
            } else {
                normalized["enum"] = filteredEnumValues
            }
        }
        if let constValue = normalized["const"], normalized["enum"] == nil,
           let constString = constValue as? String {
            normalized["enum"] = [constString]
        }

        if let normalizedType = normalizedGeminiSchemaTypeValue(normalized["type"]) {
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
                      let inferred = inferredGeminiSchemaType(fromEnum: enumValues) {
                normalized["type"] = inferred
            } else if let constValue = normalized["const"],
                      let inferred = inferredGeminiSchemaType(fromValue: constValue) {
                normalized["type"] = inferred
            } else if let inferred = inferredGeminiSchemaTypeFromCombinators(normalized) {
                normalized["type"] = inferred
            } else if looksLikeGeminiLeafSchema(normalized) {
                normalized["type"] = "string"
            }
        }

        return sanitizedGeminiSchemaObject(normalized)
    }

    func flattenedGeminiSchemaCombinators(_ object: [String: Any]) -> [String: Any] {
        var flattened = object

        if let rawAnyOf = flattened["anyOf"] as? [Any] {
            let options = normalizedGeminiSchemaOptions(from: rawAnyOf)
            flattened.removeValue(forKey: "anyOf")
            if let preferred = preferredGeminiSchemaOption(from: options) {
                flattened = mergedGeminiSchema(base: flattened, overlay: preferred)
            }
        }

        if let rawOneOf = flattened["oneOf"] as? [Any] {
            let options = normalizedGeminiSchemaOptions(from: rawOneOf)
            flattened.removeValue(forKey: "oneOf")
            if let preferred = preferredGeminiSchemaOption(from: options) {
                flattened = mergedGeminiSchema(base: flattened, overlay: preferred)
            }
        }

        if let rawAllOf = flattened["allOf"] as? [Any] {
            let options = normalizedGeminiSchemaOptions(from: rawAllOf)
            flattened.removeValue(forKey: "allOf")
            for option in options {
                flattened = mergedGeminiSchema(base: flattened, overlay: option)
            }
        }

        return flattened
    }

    func normalizedGeminiSchemaOptions(from rawOptions: [Any]) -> [[String: Any]] {
        rawOptions.compactMap { raw in
            if let schema = raw as? [String: Any] {
                return schema
            }
            if let normalizedType = normalizedGeminiSchemaTypeValue(raw) {
                return ["type": normalizedType]
            }
            if let inferredType = inferredGeminiSchemaType(fromValue: raw) {
                return ["type": inferredType]
            }
            return nil
        }
    }

    func preferredGeminiSchemaOption(from options: [[String: Any]]) -> [String: Any]? {
        let candidates = options.filter { !$0.isEmpty }
        if let typed = candidates.first(where: { normalizedGeminiSchemaTypeValue($0["type"]) != nil }) {
            return typed
        }
        if let explicit = candidates.first(where: {
            $0["enum"] != nil || $0["const"] != nil || $0["properties"] != nil || $0["items"] != nil
        }) {
            return explicit
        }
        return candidates.first
    }

    func mergedGeminiSchema(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
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

    func normalizedGeminiSchemaPropertiesMap(_ properties: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(properties.count)
        for (key, value) in properties {
            normalized[key] = normalizedGeminiSchemaPropertyValue(value)
        }
        return normalized
    }

    func normalizedGeminiSchemaPropertyValue(_ value: Any) -> Any {
        if let schema = value as? [String: Any] {
            return normalizedGeminiSchemaObject(schema)
        }
        if let normalizedType = normalizedGeminiSchemaTypeValue(value) {
            return ["type": normalizedType]
        }
        if let inferredType = inferredGeminiSchemaType(fromValue: value) {
            return ["type": inferredType]
        }
        return ["type": "string"]
    }

    func normalizedGeminiSchemaTypeKeyword(_ type: String) -> String? {
        let lowered = type.lowercased()
        guard lowered != "null" else { return nil }
        let supportedTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array"]
        guard supportedTypes.contains(lowered) else { return nil }
        return lowered
    }

    func normalizedGeminiSchemaTypeValue(_ rawType: Any?) -> String? {
        guard let rawType else { return nil }
        if let type = rawType as? String {
            return normalizedGeminiSchemaTypeKeyword(type)
        }
        if let typeArray = rawType as? [Any] {
            for value in typeArray {
                guard let type = value as? String else { continue }
                if let normalized = normalizedGeminiSchemaTypeKeyword(type) {
                    return normalized
                }
            }
        }
        return nil
    }

    func inferredGeminiSchemaType(fromEnum values: [Any]) -> String? {
        let nonNullValues = values.filter { !($0 is NSNull) }
        guard let firstValue = nonNullValues.first else { return nil }
        guard let inferred = inferredGeminiSchemaType(fromValue: firstValue) else { return nil }
        for value in nonNullValues.dropFirst() where inferredGeminiSchemaType(fromValue: value) != inferred {
            return nil
        }
        return inferred
    }

    func inferredGeminiSchemaType(fromValue value: Any) -> String? {
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

    func inferredGeminiSchemaTypeFromCombinators(_ object: [String: Any]) -> String? {
        let combinatorKeys = ["anyOf", "oneOf", "allOf"]
        for key in combinatorKeys {
            guard let options = object[key] as? [Any], !options.isEmpty else { continue }
            let inferredTypes = options.compactMap { option -> String? in
                guard let schema = option as? [String: Any] else { return nil }
                if let directType = normalizedGeminiSchemaTypeValue(schema["type"]) {
                    return directType
                }
                if let enumValues = schema["enum"] as? [Any],
                   let inferred = inferredGeminiSchemaType(fromEnum: enumValues) {
                    return inferred
                }
                if let constValue = schema["const"],
                   let inferred = inferredGeminiSchemaType(fromValue: constValue) {
                    return inferred
                }
                return inferredGeminiSchemaTypeFromCombinators(schema)
            }

            guard let first = inferredTypes.first else { continue }
            if inferredTypes.allSatisfy({ $0 == first }) {
                return first
            }
        }
        return nil
    }

    func looksLikeGeminiLeafSchema(_ object: [String: Any]) -> Bool {
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

    func sanitizedGeminiSchemaObject(_ object: [String: Any]) -> [String: Any] {
        let supportedKeys: Set<String> = [
            "type",
            "format",
            "title",
            "description",
            "nullable",
            "enum",
            "maxItems",
            "minItems",
            "properties",
            "required",
            "minProperties",
            "maxProperties",
            "minLength",
            "maxLength",
            "pattern",
            "example",
            "anyOf",
            "propertyOrdering",
            "default",
            "items",
            "minimum",
            "maximum"
        ]

        var sanitized: [String: Any] = [:]
        sanitized.reserveCapacity(object.count)
        for (key, value) in object where supportedKeys.contains(key) {
            sanitized[key] = value
        }
        return sanitized
    }

    // MARK: - 内部解码模型
    
    struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                let role: String?
                let parts: [Part]?
            }
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
                let thoughtSignature: String?
                let functionCall: FunctionCall?
                let inlineData: InlineData?

                enum CodingKeys: String, CodingKey {
                    case text
                    case thought
                    case thoughtSignature
                    case thought_signature
                    case functionCall
                    case inlineData
                    case inline_data
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    text = try container.decodeIfPresent(String.self, forKey: .text)
                    thought = try container.decodeIfPresent(Bool.self, forKey: .thought)
                    thoughtSignature = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
                        ?? (try container.decodeIfPresent(String.self, forKey: .thought_signature))
                    functionCall = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
                    inlineData = try container.decodeIfPresent(InlineData.self, forKey: .inlineData)
                        ?? (try container.decodeIfPresent(InlineData.self, forKey: .inline_data))
                }
            }
            struct FunctionCall: Decodable {
                let id: String?
                let name: String
                let args: [String: AnyCodable]?
            }
            struct InlineData: Decodable {
                let mimeType: String?
                let data: String?

                enum CodingKeys: String, CodingKey {
                    case mimeType
                    case mime_type
                    case data
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
                        ?? (try container.decodeIfPresent(String.self, forKey: .mime_type))
                    data = try container.decodeIfPresent(String.self, forKey: .data)
                }
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let totalTokenCount: Int?
            let thoughtsTokenCount: Int?
            let cachedContentTokenCount: Int?
        }
        let usageMetadata: UsageMetadata?
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }

    struct GeminiModelListResponse: Decodable {
        struct ModelInfo: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [ModelInfo]?
    }

    struct GeminiErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    struct AnyCodable: Decodable {
        let value: Any
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let doubleValue = try? container.decode(Double.self) {
                value = doubleValue
            } else if let boolValue = try? container.decode(Bool.self) {
                value = boolValue
            } else if let stringValue = try? container.decode(String.self) {
                value = stringValue
            } else if let arrayValue = try? container.decode([AnyCodable].self) {
                value = arrayValue.map { $0.value }
            } else if let dictValue = try? container.decode([String: AnyCodable].self) {
                value = dictValue.mapValues { $0.value }
            } else {
                value = NSNull()
            }
        }
    }
    
    struct GeminiEmbeddingResponse: Decodable {
        struct Embedding: Decodable {
            let values: [Double]
        }
        let embedding: Embedding?
        let embeddings: [Embedding]?
    }
    
    public init() {}
    
}
