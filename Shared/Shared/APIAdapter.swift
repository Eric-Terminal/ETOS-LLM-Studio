// ============================================================================
// APIAdapter.swift
// ============================================================================
// 定义了与不同 LLM API 后端交互的适配器模式。
//
// 核心组件:
// - APIAdapter 协议: 定义了所有 API 适配器必须遵守的通用接口 (已重构)。
// - OpenAIAdapter 类: 针对 OpenAI 及其兼容 API 的具体实现 (已重构)。
// ============================================================================

import Foundation
import CryptoKit
import os.log

// MARK: - 流式响应的数据片段

private func appendSegment(_ segment: String, to target: inout String?, separator: String = "\n\n") {
    guard !segment.isEmpty else { return }
    if target == nil || target?.isEmpty == true {
        target = segment
        return
    }
    let existing = target ?? ""
    let existingEndsWithNewline = existing.last == "\n" || existing.last == "\r"
    let newStartsWithNewline = segment.first == "\n" || segment.first == "\r"
    let joiner = (existingEndsWithNewline || newStartsWithNewline) ? "" : separator
    target = existing + joiner + segment
}

private let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]
private let audioPlaceholders: Set<String> = ["[语音消息]", "[語音訊息]", "[音声メッセージ]", "[Voice message]"]
private let filePlaceholders: Set<String> = ["[文件]", "[檔案]", "[ファイル]", "[File]"]

private func shouldSendText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if imagePlaceholders.contains(trimmed) { return false }
    if audioPlaceholders.contains(trimmed) { return false }
    if filePlaceholders.contains(trimmed) { return false }
    return true
}

private func inferredImageMimeType(from data: Data) -> String {
    guard data.count >= 12 else { return "image/png" }
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
        return "image/png"
    }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
        return "image/jpeg"
    }
    if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
       bytes.count >= 12,
       bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
        return "image/webp"
    }
    if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
        return "image/gif"
    }
    return "image/png"
}

private func logChatRequestSnapshot(
    adapterName: String,
    request: URLRequest,
    payload: [String: Any]
) {
    var detailPayload: [String: String] = [
        "适配器": adapterName,
        "方法": request.httpMethod ?? "POST",
        "地址": AppLogRedactor.sanitizeURLForLog(request.url),
        "请求体字节数": "\(request.httpBody?.count ?? 0)"
    ]

    if let headers = AppLogRedactor.sanitizeHeadersForLog(request.allHTTPHeaderFields) {
        detailPayload["请求头"] = headers
    }
    if let body = AppLogRedactor.sanitizeRequestBodyForLog(payload) {
        detailPayload["请求体(不含消息字段)"] = body
    } else {
        detailPayload["请求体(不含消息字段)"] = "[无法序列化]"
    }

    AppLog.developer(
        level: .debug,
        category: "请求",
        action: "构建\(adapterName)请求",
        message: "\(adapterName) 请求体已生成",
        payload: detailPayload
    )
}

/// 代表从流式 API 响应中解析出的单个数据片段。
public struct ChatMessagePart {
    public struct ToolCallDelta {
        public var id: String?
        public var index: Int?
        public var nameFragment: String?
        public var argumentsFragment: String?
        public var providerSpecificFields: [String: JSONValue]? = nil
    }

    public var content: String?
    public var reasoningContent: String?
    public var toolCallDeltas: [ToolCallDelta]?
    public var tokenUsage: MessageTokenUsage?
}

/// 生图响应中的单张图片结果。
public struct GeneratedImageResult: Sendable {
    public let data: Data?
    public let mimeType: String?
    public let remoteURL: URL?
    public let revisedPrompt: String?

    public init(data: Data?, mimeType: String?, remoteURL: URL?, revisedPrompt: String?) {
        self.data = data
        self.mimeType = mimeType
        self.remoteURL = remoteURL
        self.revisedPrompt = revisedPrompt
    }
}


// MARK: - API 适配器协议 (已重构)

/// `APIAdapter` 协议定义了一个标准接口，用于处理不同 LLM 提供商的 API 请求构建和响应解析。
/// 这使得 `ChatService` 无需关心特定 API 的细节，从而轻松支持多种后端。
public protocol APIAdapter {
    /// 最近一次构建聊天请求失败时的详细错误（可选）。
    /// 用于向上层暴露本地参数预校验等失败原因，避免只看到笼统的“构建失败”。
    var lastRequestBuildErrorMessage: String? { get }
    
    /// 构建一个用于发送聊天消息的网络请求。
    /// - Parameters:
    ///   - model: 当前选中的 `RunnableModel` 模型配置。
    ///   - commonPayload: 包含如 `temperature`, `top_p`, `stream` 等通用参数的字典。
    ///   - messages: **使用标准 `ChatMessage` 模型的消息历史记录。**
    ///   - tools: 一个可选的 `InternalToolDefinition` 数组，定义了可供 AI 使用的工具。
    ///   - audioAttachments: 一个字典，将消息 ID 映射到对应的音频附件，支持历史消息中的音频持续发送。
    ///   - imageAttachments: 一个字典，将消息 ID 映射到对应的图片附件列表，支持视觉模型。
    ///   - fileAttachments: 一个字典，将消息 ID 映射到对应的文件附件列表。
    /// - Returns: 一个配置好的 `URLRequest` 对象，如果构建失败则返回 `nil`。
    func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest?
    
    /// 构建一个用于获取模型列表的网络请求。
    /// - Parameter provider: 需要查询的 `Provider`。
    /// - Returns: 一个配置好的 `URLRequest` 对象。
    func buildModelListRequest(for provider: Provider) -> URLRequest?

    /// 解析模型列表响应，返回模型数组。
    /// - Parameter data: 从服务器接收到的 `Data` 对象。
    func parseModelListResponse(data: Data) throws -> [Model]
    
    /// 解析一次性返回的（非流式）API 响应。
    /// - Parameter data: 从服务器接收到的 `Data` 对象。
    /// - Returns: **一个完整的、可直接使用的 `ChatMessage` 对象。**
    func parseResponse(data: Data) throws -> ChatMessage
    
    /// 解析流式响应中的单行数据。
    /// - Parameter line: 从流中读取的一行字符串 (通常以 "data:" 开头)。
    /// - Returns: **一个 `ChatMessagePart` 数据片段，如果行无效则返回 `nil`。**
    func parseStreamingResponse(line: String) -> ChatMessagePart?
    
    /// 构建语音转文字请求。
    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest?
    
    /// 解析语音转文字响应。
    func parseTranscriptionResponse(data: Data) throws -> String
    
    /// 构建一个用于生成嵌入的请求。
    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest?
    
    /// 解析嵌入响应，返回与输入文本一一对应的向量。
    func parseEmbeddingResponse(data: Data) throws -> [[Float]]

    /// 构建一个用于生图（文生图 / 图生图）的请求。
    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest?

    /// 解析生图响应。
    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult]
}

public extension APIAdapter {
    var lastRequestBuildErrorMessage: String? { nil }

    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest? {
        nil
    }
    
    func parseTranscriptionResponse(data: Data) throws -> String {
        throw NSError(domain: "APIAdapter", code: -10, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现语音转文字功能。"])
    }
    
    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        nil
    }
    
    func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        throw NSError(domain: "APIAdapter", code: -11, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现嵌入 API。"])
    }

    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        nil
    }

    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        throw NSError(domain: "APIAdapter", code: -12, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现生图 API。"])
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { Model(modelName: $0.id) }
    }
}

private enum ToolSchemaPreflight {
    private static let validTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array", "null"]
    private static let combinatorKeys: [String] = ["anyOf", "oneOf", "allOf"]

    static func normalizeAndValidate(schema: [String: Any], toolName: String) -> Result<[String: Any], String> {
        let normalized = normalizeSchemaValue(schema) as? [String: Any] ?? schema
        var issues: [String] = []
        validateSchemaNode(normalized, path: "$", issues: &issues)
        guard !issues.isEmpty else {
            return .success(normalized)
        }

        let visible = Array(issues.prefix(3))
        var message = String(
            format: NSLocalizedString("错误：工具 %@ 的参数 Schema 校验失败，请先修正后再发送：", comment: "Tool schema preflight failed prefix"),
            toolName
        )
        for line in visible {
            message.append("\n- \(line)")
        }
        if issues.count > visible.count {
            message.append(
                String(
                    format: NSLocalizedString("\n- 其余 %d 条问题已省略。", comment: "Tool schema preflight omitted issues"),
                    issues.count - visible.count
                )
            )
        }
        return .failure(message)
    }

    private static func normalizeSchemaValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return normalizeSchemaObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.map { normalizeSchemaValue($0) }
        }
        return value
    }

    private static func normalizeSchemaObject(_ object: [String: Any]) -> [String: Any] {
        var normalized = object.mapValues { normalizeSchemaValue($0) }

        for key in combinatorKeys {
            if let options = normalized[key] as? [Any] {
                normalized[key] = normalizeCombinatorOptions(options)
            }
        }

        if let properties = normalized["properties"] as? [String: Any] {
            var normalizedProperties: [String: Any] = [:]
            normalizedProperties.reserveCapacity(properties.count)
            for (key, value) in properties {
                if let schema = value as? [String: Any] {
                    normalizedProperties[key] = normalizeSchemaObject(schema)
                } else if let normalizedType = normalizedSchemaTypeValue(value) {
                    normalizedProperties[key] = ["type": normalizedType]
                } else if let inferred = inferredSchemaType(fromValue: value) {
                    normalizedProperties[key] = ["type": inferred]
                } else {
                    normalizedProperties[key] = value
                }
            }
            normalized["properties"] = normalizedProperties
        }

        if let normalizedType = normalizedSchemaTypeValue(normalized["type"]) {
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
                      let inferred = inferredSchemaType(fromEnum: enumValues) {
                normalized["type"] = inferred
            } else if let constValue = normalized["const"],
                      let inferred = inferredSchemaType(fromValue: constValue) {
                normalized["type"] = inferred
            } else if let inferred = inferredSchemaTypeFromCombinators(normalized) {
                normalized["type"] = inferred
            }
        }

        return normalized
    }

    private static func normalizeCombinatorOptions(_ options: [Any]) -> [Any] {
        options.compactMap { raw in
            if let schema = raw as? [String: Any] {
                return normalizeSchemaObject(schema)
            }
            if let normalizedType = normalizedSchemaTypeValue(raw) {
                return ["type": normalizedType]
            }
            if let inferred = inferredSchemaType(fromValue: raw) {
                return ["type": inferred]
            }
            return nil
        }
    }

    private static func normalizedSchemaTypeKeyword(_ type: String) -> String? {
        let lowered = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard validTypes.contains(lowered) else { return nil }
        if lowered == "null" { return nil }
        return lowered
    }

    private static func normalizedSchemaTypeValue(_ rawType: Any?) -> String? {
        if let type = rawType as? String {
            return normalizedSchemaTypeKeyword(type)
        }
        if let typeArray = rawType as? [Any] {
            for item in typeArray {
                if let type = item as? String,
                   let normalized = normalizedSchemaTypeKeyword(type) {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func inferredSchemaType(fromEnum values: [Any]) -> String? {
        let nonNullValues = values.filter { !($0 is NSNull) }
        guard let first = nonNullValues.first,
              let inferred = inferredSchemaType(fromValue: first) else { return nil }
        for value in nonNullValues.dropFirst() where inferredSchemaType(fromValue: value) != inferred {
            return nil
        }
        return inferred
    }

    private static func inferredSchemaType(fromValue value: Any) -> String? {
        if value is NSNull { return nil }
        if value is Bool { return "boolean" }
        if value is String { return "string" }
        if value is Int || value is Int8 || value is Int16 || value is Int32 || value is Int64 ||
            value is UInt || value is UInt8 || value is UInt16 || value is UInt32 || value is UInt64 {
            return "integer"
        }
        if value is Double || value is Float {
            return "number"
        }
        if value is [Any] {
            return "array"
        }
        if value is [String: Any] {
            return "object"
        }
        return nil
    }

    private static func inferredSchemaTypeFromCombinators(_ object: [String: Any]) -> String? {
        for key in combinatorKeys {
            guard let options = object[key] as? [Any] else { continue }
            for option in options {
                if let schema = option as? [String: Any] {
                    if let directType = normalizedSchemaTypeValue(schema["type"]) {
                        return directType
                    }
                    if let enumValues = schema["enum"] as? [Any],
                       let inferred = inferredSchemaType(fromEnum: enumValues) {
                        return inferred
                    }
                    if let constValue = schema["const"],
                       let inferred = inferredSchemaType(fromValue: constValue) {
                        return inferred
                    }
                } else if let normalizedType = normalizedSchemaTypeValue(option) {
                    return normalizedType
                } else if let inferred = inferredSchemaType(fromValue: option) {
                    return inferred
                }
            }
        }
        return nil
    }

    private static func validateSchemaNode(_ rawNode: Any, path: String, issues: inout [String]) {
        guard let node = rawNode as? [String: Any] else {
            issues.append("\(path)：Schema 节点必须是对象。")
            return
        }

        let hasType = normalizedSchemaTypeValue(node["type"]) != nil
        let hasRef = (node["$ref"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasCombinator = combinatorKeys.contains { key in
            if let options = node[key] as? [Any] {
                return !options.isEmpty
            }
            return false
        }
        if !hasType && !hasRef && !hasCombinator {
            issues.append("\(path)：缺少 type 字段。")
        }

        if let required = node["required"] {
            guard let requiredArray = required as? [Any] else {
                issues.append("\(path).required：必须是字符串数组。")
                return
            }
            for (index, item) in requiredArray.enumerated() where !(item is String) {
                issues.append("\(path).required[\(index)]：必须是字符串。")
            }
        }

        if let properties = node["properties"] {
            guard let propertyMap = properties as? [String: Any] else {
                issues.append("\(path).properties：必须是对象。")
                return
            }
            for (key, value) in propertyMap {
                validateSchemaNode(value, path: pathByAppending(path, component: "properties.\(key)"), issues: &issues)
            }
        }

        if let items = node["items"] {
            if let itemSchema = items as? [String: Any] {
                validateSchemaNode(itemSchema, path: pathByAppending(path, component: "items"), issues: &issues)
            } else if let tupleSchemas = items as? [Any] {
                for (index, tupleSchema) in tupleSchemas.enumerated() {
                    validateSchemaNode(tupleSchema, path: "\(pathByAppending(path, component: "items"))[\(index)]", issues: &issues)
                }
            } else {
                issues.append("\(path).items：必须是对象或对象数组。")
            }
        }

        if let additionalProperties = node["additionalProperties"] {
            if additionalProperties is Bool {
                // 合法，忽略
            } else if let schema = additionalProperties as? [String: Any] {
                validateSchemaNode(schema, path: pathByAppending(path, component: "additionalProperties"), issues: &issues)
            } else {
                issues.append("\(path).additionalProperties：必须是布尔值或对象。")
            }
        }

        for key in combinatorKeys {
            guard let rawValue = node[key] else { continue }
            guard let options = rawValue as? [Any] else {
                issues.append("\(path).\(key)：必须是数组。")
                continue
            }
            if options.isEmpty {
                issues.append("\(path).\(key)：数组不能为空。")
                continue
            }
            for (index, option) in options.enumerated() {
                validateSchemaNode(option, path: "\(pathByAppending(path, component: key))[\(index)]", issues: &issues)
            }
        }
    }

    private static func pathByAppending(_ base: String, component: String) -> String {
        "\(base).\(component)"
    }
}


// MARK: - OpenAI 适配器实现 (已重构)

/// `OpenAIAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理与 OpenAI 兼容的 API。
public class OpenAIAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIAdapter")
    public private(set) var lastRequestBuildErrorMessage: String?
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])
    static let streamIncludeUsageControlKey = "openai_stream_include_usage"
    private static let responsesModeSignalKeys: Set<String> = [
        "background",
        "context_management",
        "conversation",
        "include",
        "max_output_tokens",
        "previous_response_id",
        "reasoning",
        "store",
        "text",
        "truncation"
    ]
    private static let openAIControlOverrideKeys: Set<String> = [
        "openai_api",
        "openai_api_mode",
        "use_responses_api",
        streamIncludeUsageControlKey
    ]
    private static let chatCompletionsOnlyKeys: Set<String> = [
        "functions",
        "function_call",
        "messages",
        "stream_options"
    ]

    private enum OpenAIConversationAPI {
        case chatCompletions
        case responses
    }

    private enum OpenAIResponsesToolChoice {
        case auto
        case required
        case none

        init?(_ rawValue: String) {
            switch rawValue.lowercased() {
            case "auto":
                self = .auto
            case "required", "any":
                self = .required
            case "none":
                self = .none
            default:
                return nil
            }
        }
    }

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    private func inferredCapabilities(for modelName: String) -> [Model.Capability] {
        let lowered = modelName.lowercased()
        var capabilities: [Model.Capability] = Model.defaultCapabilities
        if lowered.contains("tts") || lowered.contains("text-to-speech") || lowered.contains("speech") {
            capabilities.append(.textToSpeech)
        }
        if lowered.contains("gpt-image") || lowered.contains("image") || lowered.contains("dall") {
            capabilities.append(.imageGeneration)
        }
        return capabilities
    }

    private func normalizedOpenAIToolParameters(_ parameters: [String: Any]) -> [String: Any] {
        normalizedOpenAISchemaValue(parameters) as? [String: Any] ?? parameters
    }

    private func normalizedOpenAISchemaValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return normalizedOpenAISchemaObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.map { normalizedOpenAISchemaValue($0) }
        }
        return value
    }

    private func normalizedOpenAISchemaObject(_ object: [String: Any]) -> [String: Any] {
        var normalized = object.mapValues { normalizedOpenAISchemaValue($0) }
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

    private func flattenedOpenAISchemaCombinators(_ object: [String: Any]) -> [String: Any] {
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

    private func normalizedOpenAISchemaOptions(from rawOptions: [Any]) -> [[String: Any]] {
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

    private func preferredOpenAISchemaOption(from options: [[String: Any]]) -> [String: Any]? {
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

    private func mergedOpenAISchema(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
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

    private func normalizedOpenAISchemaPropertiesMap(_ properties: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(properties.count)
        for (key, value) in properties {
            normalized[key] = normalizedOpenAISchemaPropertyValue(value)
        }
        return normalized
    }

    private func normalizedOpenAISchemaPropertyValue(_ value: Any) -> Any {
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

    private func normalizedOpenAISchemaTypeKeyword(_ type: String) -> String? {
        let lowered = type.lowercased()
        guard lowered != "null" else { return nil }
        let supportedTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array"]
        guard supportedTypes.contains(lowered) else { return nil }
        return lowered
    }

    private func normalizedOpenAISchemaTypeValue(_ rawType: Any?) -> String? {
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

    private func inferredOpenAISchemaType(fromEnum values: [Any]) -> String? {
        let nonNullValues = values.filter { !($0 is NSNull) }
        guard let firstValue = nonNullValues.first else { return nil }
        guard let inferred = inferredOpenAISchemaType(fromValue: firstValue) else { return nil }
        for value in nonNullValues.dropFirst() where inferredOpenAISchemaType(fromValue: value) != inferred {
            return nil
        }
        return inferred
    }

    private func inferredOpenAISchemaType(fromValue value: Any) -> String? {
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

    private func inferredOpenAISchemaTypeFromCombinators(_ object: [String: Any]) -> String? {
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

    private func looksLikeOpenAILeafSchema(_ object: [String: Any]) -> Bool {
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

    private func sanitizedImageGenerationOverrides(_ overrides: [String: Any]) -> [String: Any] {
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

    private func sanitizedOpenAIControlOverrides(_ overrides: [String: Any]) -> [String: Any] {
        overrides.filter { !Self.openAIControlOverrideKeys.contains($0.key) }
    }

    private func normalizedOpenAIConversationAPIValue(_ rawValue: String) -> OpenAIConversationAPI? {
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

    private func boolValue(from rawValue: Any?) -> Bool? {
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

    private func resolvedConversationAPI(for overrides: [String: Any]) -> OpenAIConversationAPI {
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

    private func sanitizedChatCompletionsOverrides(_ overrides: [String: Any]) -> [String: Any] {
        sanitizedOpenAIControlOverrides(overrides).filter { !Self.responsesModeSignalKeys.contains($0.key) }
    }

    private func sanitizedResponsesOverrides(_ overrides: [String: Any]) -> [String: Any] {
        let stripped = sanitizedOpenAIControlOverrides(overrides).filter { !Self.chatCompletionsOnlyKeys.contains($0.key) }
        var sanitized = stripped
        if sanitized["max_output_tokens"] == nil, let legacyMaxTokens = stripped["max_tokens"] {
            sanitized["max_output_tokens"] = legacyMaxTokens
        }
        sanitized.removeValue(forKey: "max_tokens")
        sanitized.removeValue(forKey: "input")
        return sanitized
    }

    private func sanitizedPayloadForDebug(_ value: Any) -> Any {
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

    private func buildResponsesMessageInput(
        for message: ChatMessage,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> [String: Any]? {
        guard message.role == .system || message.role == .user || message.role == .assistant else {
            return nil
        }

        let audioAttachment = audioAttachments[message.id]
        let messageImageAttachments = imageAttachments[message.id] ?? []
        let messageFileAttachments = fileAttachments[message.id] ?? []
        let needsMultipart = !messageImageAttachments.isEmpty || audioAttachment != nil || !messageFileAttachments.isEmpty

        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needsMultipart {
            guard !message.content.isEmpty else { return nil }
            return [
                "type": "message",
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var content: [[String: Any]] = []
        if shouldSendText(trimmedContent) {
            content.append([
                "type": "input_text",
                "text": trimmedContent
            ])
        }

        for imageAttachment in messageImageAttachments {
            content.append([
                "type": "input_image",
                "image_url": imageAttachment.dataURL
            ])
        }

        if let audioAttachment {
            content.append([
                "type": "input_file",
                "file_data": audioAttachment.data.base64EncodedString(),
                "filename": audioAttachment.fileName
            ])
        }

        for fileAttachment in messageFileAttachments {
            content.append([
                "type": "input_file",
                "file_data": fileAttachment.data.base64EncodedString(),
                "filename": fileAttachment.fileName
            ])
        }

        guard !content.isEmpty else { return nil }
        return [
            "type": "message",
            "role": message.role.rawValue,
            "content": content
        ]
    }

    private func buildResponsesFunctionCallItem(from toolCall: InternalToolCall) -> [String: Any] {
        [
            "type": "function_call",
            "call_id": toolCall.id,
            "name": sanitizedToolName(toolCall.toolName),
            "arguments": toolCall.arguments,
            "status": "completed"
        ]
    }

    private func buildResponsesFunctionCallOutputItem(from message: ChatMessage) -> [String: Any]? {
        guard message.role == .tool, let callID = message.toolCalls?.first?.id else { return nil }
        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": message.content
        ]
    }

    private func buildResponsesInputItems(
        from messages: [ChatMessage],
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []
        items.reserveCapacity(messages.count)

        for message in messages {
            if let messageItem = buildResponsesMessageInput(
                for: message,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            ) {
                items.append(messageItem)
            }

            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                items.append(contentsOf: toolCalls.map { buildResponsesFunctionCallItem(from: $0) })
            } else if message.role == .tool, let outputItem = buildResponsesFunctionCallOutputItem(from: message) {
                items.append(outputItem)
            }
        }

        return items
    }

    private func makeResponsesToolChoicePayload(_ rawValue: Any?) -> Any? {
        if let toolChoice = rawValue as? [String: Any] {
            return toolChoice
        }
        if let rawString = rawValue as? String,
           let normalized = OpenAIResponsesToolChoice(rawString) {
            switch normalized {
            case .auto:
                return "auto"
            case .required:
                return "required"
            case .none:
                return "none"
            }
        }
        return nil
    }

    private func parseResponsesTextContent(from content: [Any]) -> String {
        var segments: [String] = []
        for rawPart in content {
            guard let part = rawPart as? [String: Any],
                  let type = part["type"] as? String else { continue }
            switch type {
            case "output_text":
                if let text = part["text"] as? String, !text.isEmpty {
                    segments.append(text)
                }
            case "refusal":
                if let refusal = part["refusal"] as? String, !refusal.isEmpty {
                    segments.append(refusal)
                }
            default:
                continue
            }
        }
        return segments.joined()
    }

    private func parseResponsesReasoningContent(from item: [String: Any]) -> String? {
        var reasoning: String? = nil

        if let content = item["content"] as? [Any] {
            for rawPart in content {
                guard let part = rawPart as? [String: Any],
                      let type = part["type"] as? String else { continue }
                switch type {
                case "reasoning_text", "summary_text":
                    if let text = part["text"] as? String {
                        appendSegment(text, to: &reasoning)
                    }
                default:
                    continue
                }
            }
        }

        if let summary = item["summary"] as? [Any] {
            for rawPart in summary {
                guard let part = rawPart as? [String: Any],
                      let type = part["type"] as? String,
                      type == "summary_text",
                      let text = part["text"] as? String else { continue }
                appendSegment(text, to: &reasoning)
            }
        }

        return reasoning
    }

    private func parseResponsesMessage(from payload: [String: Any]) throws -> ChatMessage {
        if let errorObject = payload["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            throw NSError(domain: "OpenAIResponsesError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let outputItems = payload["output"] as? [Any] else {
            throw NSError(domain: "OpenAIResponsesError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少 output 数组"])
        }

        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []

        for rawItem in outputItems {
            guard let item = rawItem as? [String: Any],
                  let type = item["type"] as? String else { continue }
            switch type {
            case "message":
                if let content = item["content"] as? [Any] {
                    textContent += parseResponsesTextContent(from: content)
                }
            case "function_call":
                let callID = (item["call_id"] as? String)
                    ?? (item["id"] as? String)
                    ?? "tool-\(UUID().uuidString)"
                guard let name = item["name"] as? String else { continue }
                let arguments = item["arguments"] as? String ?? ""
                internalToolCalls.append(
                    InternalToolCall(
                        id: callID,
                        toolName: name,
                        arguments: arguments
                    )
                )
            case "reasoning":
                if let reasoning = parseResponsesReasoningContent(from: item) {
                    appendSegment(reasoning, to: &reasoningContent)
                }
            default:
                continue
            }
        }

        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeResponsesTokenUsage(from: payload["usage"])
        )
    }

    private func parseResponsesStreamingEvent(_ payload: [String: Any]) -> ChatMessagePart? {
        guard let eventType = payload["type"] as? String else { return nil }
        switch eventType {
        case "response.output_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.refusal.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.function_call_arguments.delta":
            guard let delta = payload["delta"] as? String else { return nil }
            let callID = (payload["call_id"] as? String) ?? (payload["item_id"] as? String)
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: nil,
                        argumentsFragment: delta
                    )
                ]
            )

        case "response.output_item.added":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "function_call" else {
                return nil
            }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String)
            let arguments = item["arguments"] as? String
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: item["name"] as? String,
                        argumentsFragment: arguments
                    )
                ]
            )

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(reasoningContent: delta)
            }
            return nil

        case "response.completed", "response.incomplete":
            guard let response = payload["response"] as? [String: Any],
                  let usage = makeResponsesTokenUsage(from: response["usage"]) else {
                return nil
            }
            return ChatMessagePart(tokenUsage: usage)

        default:
            return nil
        }
    }

    private func makeResponsesTokenUsage(from rawUsage: Any?) -> MessageTokenUsage? {
        guard let usage = rawUsage as? [String: Any] else { return nil }
        let promptTokens = usage["input_tokens"] as? Int
        let completionTokens = usage["output_tokens"] as? Int
        let totalTokens = usage["total_tokens"] as? Int
        let reasoningTokens: Int?
        if let details = usage["output_tokens_details"] as? [String: Any] {
            reasoningTokens = details["reasoning_tokens"] as? Int
        } else {
            reasoningTokens = nil
        }

        if promptTokens == nil && completionTokens == nil && totalTokens == nil && reasoningTokens == nil {
            return nil
        }

        return MessageTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            thinkingTokens: reasoningTokens
        )
    }

    // MARK: - 内部解码模型 (实现细节)
    
    private struct OpenAIToolCall: Decodable {
        let id: String?
        let type: String
        let index: Int?
        let providerSpecificFields: [String: JSONValue]?
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let function: Function

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case index
            case function
            case providerSpecificFields
            case provider_specific_fields
            case extraContent
            case extra_content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            index = try container.decodeIfPresent(Int.self, forKey: .index)
            function = try container.decode(Function.self, forKey: .function)
            var mergedProviderSpecificFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .providerSpecificFields)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .provider_specific_fields))
                ?? [:]
            let extraContent = try container.decodeIfPresent([String: JSONValue].self, forKey: .extraContent)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .extra_content))
            if let extraContent,
               let googleValue = extraContent["google"],
               case let .dictionary(googleDict) = googleValue,
               let thoughtSignatureValue = googleDict["thought_signature"],
               case let .string(thoughtSignature) = thoughtSignatureValue,
               !thoughtSignature.isEmpty {
                mergedProviderSpecificFields["thought_signature"] = .string(thoughtSignature)
            }
            providerSpecificFields = mergedProviderSpecificFields.isEmpty ? nil : mergedProviderSpecificFields
        }
    }
    
    private struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
                let tool_calls: [OpenAIToolCall]?
                let reasoning_content: String? // 重新添加被移除的字段
            }
            let message: Message? // 用于非流式
            let delta: Message?   // 用于流式
        }
        let choices: [Choice]
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
        let usage: Usage?
    }
    
    private struct OpenAITranscriptionResponse: Decodable {
        let text: String
    }
    
    private struct OpenAIEmbeddingResponse: Decodable {
        struct DataEntry: Decodable {
            let embedding: [Double]
        }
        let data: [DataEntry]
    }

    private struct OpenAIImageResponse: Decodable {
        struct DataEntry: Decodable {
            let b64_json: String?
            let url: String?
            let revised_prompt: String?
        }
        let data: [DataEntry]
    }

    public init() {}

    // MARK: - 协议方法实现

    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        lastRequestBuildErrorMessage = nil
        let rawOverrides = model.model.overrideParameters.mapValues { $0.toAny() }
        let conversationAPI = resolvedConversationAPI(for: rawOverrides)

        switch conversationAPI {
        case .chatCompletions:
            return buildChatCompletionsRequest(
                for: model,
                commonPayload: commonPayload,
                overrides: sanitizedChatCompletionsOverrides(rawOverrides),
                messages: messages,
                tools: tools,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
        case .responses:
            return buildResponsesRequest(
                for: model,
                commonPayload: commonPayload,
                overrides: sanitizedResponsesOverrides(rawOverrides),
                messages: messages,
                tools: tools,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
        }
    }

    private func buildChatCompletionsRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        overrides: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let chatURL = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let randomApiKey = model.provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: randomApiKey, to: &request)

        let apiMessages: [[String: Any]] = messages.map { msg in
            var dict: [String: Any] = ["role": msg.role.rawValue]

            let audioAttachment = audioAttachments[msg.id]
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let msgFileAttachments = fileAttachments[msg.id] ?? []
            let hasMultiContent = (audioAttachment != nil || !msgImageAttachments.isEmpty || !msgFileAttachments.isEmpty) && msg.role == .user

            if hasMultiContent {
                var contentParts: [[String: Any]] = []
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)

                if shouldSendText(trimmed) {
                    contentParts.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }

                for imageAttachment in msgImageAttachments {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": imageAttachment.dataURL
                        ]
                    ])
                }

                if let audioAttachment {
                    let base64Audio = audioAttachment.data.base64EncodedString()
                    contentParts.append([
                        "type": "input_audio",
                        "input_audio": [
                            "data": base64Audio,
                            "format": audioAttachment.format
                        ]
                    ])
                }

                for fileAttachment in msgFileAttachments {
                    let base64File = fileAttachment.data.base64EncodedString()
                    contentParts.append([
                        "type": "input_file",
                        "input_file": [
                            "data": base64File,
                            "mime_type": fileAttachment.mimeType,
                            "file_name": fileAttachment.fileName
                        ]
                    ])
                }

                if !contentParts.isEmpty {
                    dict["content"] = contentParts
                } else {
                    dict["content"] = msg.content
                }
            } else {
                dict["content"] = msg.content
            }

            if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let apiToolCalls: [[String: Any]] = toolCalls.map { call in
                    var apiToolCall: [String: Any] = [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": sanitizedToolName(call.toolName),
                            "arguments": call.arguments
                        ]
                    ]
                    if let providerSpecificFields = call.providerSpecificFields, !providerSpecificFields.isEmpty {
                        apiToolCall["provider_specific_fields"] = providerSpecificFields.mapValues { $0.toAny() }
                        if let rawThoughtSignature = providerSpecificFields["thought_signature"],
                           case let .string(thoughtSignature) = rawThoughtSignature,
                           !thoughtSignature.isEmpty {
                            apiToolCall["extra_content"] = [
                                "google": [
                                    "thought_signature": thoughtSignature
                                ]
                            ]
                        }
                    }
                    return apiToolCall
                }
                dict["tool_calls"] = apiToolCalls
            } else if msg.role == .tool, let toolCallId = msg.toolCalls?.first?.id {
                dict["tool_call_id"] = toolCallId
            }
            return dict
        }

        let shouldIncludeUsageInStream = boolValue(from: commonPayload[Self.streamIncludeUsageControlKey]) ?? true

        var finalPayload = overrides
        finalPayload.merge(commonPayload) { _, new in new }
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
        finalPayload["model"] = model.model.modelName
        finalPayload["messages"] = apiMessages

        if let shouldStream = finalPayload["stream"] as? Bool, shouldStream {
            var streamOptions = finalPayload["stream_options"] as? [String: Any] ?? [:]
            if shouldIncludeUsageInStream {
                if streamOptions["include_usage"] == nil {
                    streamOptions["include_usage"] = true
                }
            } else {
                streamOptions.removeValue(forKey: "include_usage")
            }
            if streamOptions.isEmpty {
                finalPayload.removeValue(forKey: "stream_options")
            } else {
                finalPayload["stream_options"] = streamOptions
            }
        }

        if let tools, !tools.isEmpty {
            var schemaErrors: [String] = []
            let apiTools = tools.compactMap { tool -> [String: Any]? in
                let safeName = sanitizedToolName(tool.name)
                guard let rawParams = tool.parameters.toAny() as? [String: Any] else {
                    schemaErrors.append(
                        String(
                            format: NSLocalizedString("错误：工具 %@ 的 parameters 必须是对象。", comment: "Tool schema parameters must be object"),
                            safeName
                        )
                    )
                    return nil
                }
                switch ToolSchemaPreflight.normalizeAndValidate(schema: rawParams, toolName: safeName) {
                case .success(let normalizedSchema):
                    let functionParams = normalizedOpenAIToolParameters(normalizedSchema)
                    let function: [String: Any] = ["name": safeName, "description": tool.description, "parameters": functionParams]
                    return ["type": "function", "function": function]
                case .failure(let message):
                    schemaErrors.append(message)
                    return nil
                }
            }
            if !schemaErrors.isEmpty {
                let message = schemaErrors.joined(separator: "\n")
                lastRequestBuildErrorMessage = message
                logger.error("OpenAI 工具 Schema 预校验失败：\(message, privacy: .public)")
                return nil
            }
            finalPayload["tools"] = apiTools
            finalPayload["tool_choice"] = "auto"
        }

        let containsMediaAttachment = !audioAttachments.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody {
                if containsMediaAttachment {
                    var sanitizedPayload = finalPayload
                    if var messages = sanitizedPayload["messages"] as? [[String: Any]] {
                        for index in messages.indices {
                            guard var contentArray = messages[index]["content"] as? [[String: Any]] else { continue }
                            for contentIndex in contentArray.indices {
                                var contentItem = contentArray[contentIndex]
                                guard let type = contentItem["type"] as? String else { continue }

                                if type == "input_audio" {
                                    if var audioInfo = contentItem["input_audio"] as? [String: Any],
                                       let rawData = audioInfo["data"] as? String {
                                        audioInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_audio"] = audioInfo
                                    }
                                }

                                if type == "input_file" {
                                    if var fileInfo = contentItem["input_file"] as? [String: Any],
                                       let rawData = fileInfo["data"] as? String {
                                        fileInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_file"] = fileInfo
                                    }
                                }

                                if type == "image_url" {
                                    if var imageInfo = contentItem["image_url"] as? [String: Any],
                                       let url = imageInfo["url"] as? String,
                                       url.hasPrefix("data:") {
                                        imageInfo["url"] = "[base64 image omitted: \(url.count) chars]"
                                        contentItem["image_url"] = imageInfo
                                    }
                                }

                                contentArray[contentIndex] = contentItem
                            }
                            messages[index]["content"] = contentArray
                        }
                        sanitizedPayload["messages"] = messages
                    }

                    if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: []),
                       let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (已隐藏媒体 Base64):\n---\n\(sanitizedString)\n---")
                    } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (无法完全隐藏媒体，输出原始体的 hash): \(jsonString.hashValue)")
                    }
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的聊天请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
                }
            }
            logChatRequestSnapshot(adapterName: "OpenAI兼容", request: request, payload: finalPayload)
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }

        return request
    }

    private func buildResponsesRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        overrides: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Responses 请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let responsesURL = baseURL.appendingPathComponent("responses")

        var request = URLRequest(url: responsesURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let randomApiKey = model.provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建 Responses 请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: randomApiKey, to: &request)

        let inputItems = buildResponsesInputItems(
            from: messages,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )

        var finalPayload = overrides
        finalPayload.merge(commonPayload) { _, new in new }
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
        finalPayload["model"] = model.model.modelName
        finalPayload["input"] = inputItems

        if let tools, !tools.isEmpty {
            var schemaErrors: [String] = []
            let apiTools = tools.compactMap { tool -> [String: Any]? in
                let safeName = sanitizedToolName(tool.name)
                guard let rawParams = tool.parameters.toAny() as? [String: Any] else {
                    schemaErrors.append(
                        String(
                            format: NSLocalizedString("错误：工具 %@ 的 parameters 必须是对象。", comment: "Tool schema parameters must be object"),
                            safeName
                        )
                    )
                    return nil
                }
                switch ToolSchemaPreflight.normalizeAndValidate(schema: rawParams, toolName: safeName) {
                case .success(let normalizedSchema):
                    let functionParams = normalizedOpenAIToolParameters(normalizedSchema)
                    return [
                        "type": "function",
                        "name": safeName,
                        "description": tool.description,
                        "parameters": functionParams,
                        "strict": false
                    ]
                case .failure(let message):
                    schemaErrors.append(message)
                    return nil
                }
            }
            if !schemaErrors.isEmpty {
                let message = schemaErrors.joined(separator: "\n")
                lastRequestBuildErrorMessage = message
                logger.error("OpenAI Responses 工具 Schema 预校验失败：\(message, privacy: .public)")
                return nil
            }
            finalPayload["tools"] = apiTools
            if finalPayload["tool_choice"] == nil {
                finalPayload["tool_choice"] = "auto"
            } else if let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
                finalPayload["tool_choice"] = normalizedChoice
            }
        } else if let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
            finalPayload["tool_choice"] = normalizedChoice
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody {
                let sanitizedPayload = sanitizedPayloadForDebug(finalPayload)
                if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: []),
                   let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                    logger.debug("构建的 Responses 请求体:\n---\n\(sanitizedString)\n---")
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的 Responses 请求体 (无法完全隐藏媒体，输出原始体的 hash): \(jsonString.hashValue)")
                }
            }
            logChatRequestSnapshot(adapterName: "OpenAI兼容 (Responses)", request: request, payload: finalPayload)
        } catch {
            logger.error("构建 Responses 请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }

        return request
    }
    
    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let baseURL = URL(string: provider.baseURL) else {
            logger.error("构建模型列表请求失败: 无效的 API 基础 URL - \(provider.baseURL)")
            return nil
        }
        let modelsURL = baseURL.appendingPathComponent("models")
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let randomApiKey = provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(provider.headerOverrides, apiKey: randomApiKey, to: &request)
        
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { modelInfo in
            Model(
                modelName: modelInfo.id,
                capabilities: inferredCapabilities(for: modelInfo.id)
            )
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let payload = object as? [String: Any],
           payload["output"] != nil || (payload["object"] as? String) == "response" {
            return try parseResponsesMessage(from: payload)
        }

        let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        
        guard let message = apiResponse.choices.first?.message else {
            throw NSError(domain: "APIAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 message 对象"])
        }
        
        // **翻译官的核心工作 (工具调用反向翻译)**:
        let internalToolCalls: [InternalToolCall]?
        if let openAIToolCalls = message.tool_calls {
            internalToolCalls = openAIToolCalls.compactMap {
                guard let id = $0.id else {
                    logger.error("解析工具调用失败: 缺少调用 ID。")
                    return nil
                }
                guard let name = $0.function.name else {
                    logger.error("解析工具调用失败: 缺少函数名称，ID: \(id)")
                    return nil
                }
                let arguments = $0.function.arguments ?? ""
                return InternalToolCall(
                    id: id,
                    toolName: name,
                    arguments: arguments,
                    providerSpecificFields: $0.providerSpecificFields
                )
            }
        } else {
            internalToolCalls = nil
        }
        
        return ChatMessage(
            id: UUID(),
            role: MessageRole(rawValue: message.role ?? "assistant") ?? .assistant,
            content: message.content ?? "",
            reasoningContent: message.reasoning_content, // 映射解析出的字段
            toolCalls: internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usage)
        )
    }
    
    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        if dataString == "[DONE]" {
            logger.info("流式传输结束信号 [DONE] 已收到。")
            return nil
        }
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let payload = object as? [String: Any],
           let eventType = payload["type"] as? String,
           eventType.hasPrefix("response.") {
            return parseResponsesStreamingEvent(payload)
        }
        
        do {
            let chunk = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let tokenUsage = makeTokenUsage(from: chunk.usage)

            // include_usage 场景下，OpenAI 最后一包可能只有 usage（choices 为空）。
            guard let delta = chunk.choices.first?.delta else {
                if tokenUsage != nil {
                    return ChatMessagePart(tokenUsage: tokenUsage)
                }
                return nil
            }
            
            // 解析流式响应中的工具调用增量 (采用 Append 模式)
            let toolCallDeltas: [ChatMessagePart.ToolCallDelta]?
            if let openAIToolCalls = delta.tool_calls {
                toolCallDeltas = openAIToolCalls.enumerated().map { idx, call in
                    ChatMessagePart.ToolCallDelta(
                        id: call.id,
                        index: call.index ?? idx,
                        nameFragment: call.function.name,
                        argumentsFragment: call.function.arguments,
                        providerSpecificFields: call.providerSpecificFields
                    )
                }
            } else {
                toolCallDeltas = nil
            }
            
            return ChatMessagePart(
                content: delta.content,
                reasoningContent: delta.reasoning_content,
                toolCallDeltas: toolCallDeltas,
                tokenUsage: tokenUsage
            ) // 映射解析出的字段
        } catch {
            logger.warning("流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
    
    public func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建语音转文字请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let transcriptionURL = baseURL.appendingPathComponent("audio/transcriptions")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建语音转文字请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // 5分钟，支持长音频文件转写
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var body = Data()
        body.appendMultipartField(name: "model", value: model.model.modelName, boundary: boundary)
        if let language, !language.isEmpty {
            body.appendMultipartField(name: "language", value: language, boundary: boundary)
        }
        body.appendMultipartFile(name: "file", fileName: fileName, mimeType: mimeType, data: audioData, boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        
        request.httpBody = body
        return request
    }
    
    public func parseTranscriptionResponse(data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
            return response.text
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("语音转文字响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }
    
    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建嵌入请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let embeddingsURL = baseURL.appendingPathComponent("embeddings")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // 5分钟，支持大批量文本嵌入
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var payload: [String: Any] = [
            "model": model.model.modelName,
            "input": texts
        ]
        let overrides = sanitizedOpenAIControlOverrides(model.model.overrideParameters.mapValues { $0.toAny() })
        payload.merge(overrides) { _, new in new }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建嵌入请求失败: 无法编码 JSON - \(error.localizedDescription)")
            return nil
        }
    }
    
    public func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        do {
            let response = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
            return response.data.map { entry in entry.embedding.map { Float($0) } }
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("嵌入响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建生图请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }

        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建生图请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }

        let overrides = sanitizedImageGenerationOverrides(
            model.model.overrideParameters.mapValues { $0.toAny() }
        )
        if referenceImages.isEmpty {
            let imagesURL = baseURL.appendingPathComponent("images/generations")
            var request = URLRequest(url: imagesURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

            var payload = overrides
            payload["model"] = model.model.modelName
            payload["prompt"] = prompt
            if payload["n"] == nil {
                payload["n"] = 1
            }
            if payload["response_format"] == nil {
                payload["response_format"] = "b64_json"
            }

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
                return request
            } catch {
                logger.error("构建生图请求失败: 无法编码 JSON - \(error.localizedDescription)")
                return nil
            }
        }

        let editsURL = baseURL.appendingPathComponent("images/edits")
        var request = URLRequest(url: editsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

        var body = Data()
        body.appendMultipartField(name: "model", value: model.model.modelName, boundary: boundary)
        body.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)

        let responseFormat = (overrides["response_format"] as? String) ?? "b64_json"
        body.appendMultipartField(name: "response_format", value: responseFormat, boundary: boundary)
        if overrides["n"] == nil {
            body.appendMultipartField(name: "n", value: "1", boundary: boundary)
        }

        for image in referenceImages {
            body.appendMultipartFile(
                name: "image",
                fileName: image.fileName,
                mimeType: image.mimeType,
                data: image.data,
                boundary: boundary
            )
        }

        for (key, value) in overrides {
            if ["model", "prompt", "response_format"].contains(key) {
                continue
            }
            let valueString: String?
            switch value {
            case let v as String:
                valueString = v
            case let v as Bool:
                valueString = v ? "true" : "false"
            case let v as Int:
                valueString = String(v)
            case let v as Double:
                valueString = String(v)
            default:
                valueString = nil
            }
            if let valueString {
                body.appendMultipartField(name: key, value: valueString, boundary: boundary)
            }
        }

        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let response = try JSONDecoder().decode(OpenAIImageResponse.self, from: data)
        let results = response.data.compactMap { entry -> GeneratedImageResult? in
            if let b64 = entry.b64_json,
               let imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                return GeneratedImageResult(
                    data: imageData,
                    mimeType: inferredImageMimeType(from: imageData),
                    remoteURL: nil,
                    revisedPrompt: entry.revised_prompt
                )
            }
            if let urlString = entry.url, let url = URL(string: urlString) {
                return GeneratedImageResult(
                    data: nil,
                    mimeType: nil,
                    remoteURL: url,
                    revisedPrompt: entry.revised_prompt
                )
            }
            return nil
        }

        if results.isEmpty {
            throw NSError(domain: "OpenAIImageAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "响应中未包含可用图片数据"])
        }
        return results
    }

    private func makeTokenUsage(from usage: OpenAIResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.prompt_tokens == nil && usage.completion_tokens == nil && usage.total_tokens == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens,
            thinkingTokens: nil,
            cacheWriteTokens: nil,
            cacheReadTokens: nil
        )
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
    
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }
    
    mutating func appendMultipartFile(name: String, fileName: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}

private let apiKeyPlaceholder = "{api_key}"

private func applyHeaderOverrides(_ overrides: [String: String], apiKey: String?, to request: inout URLRequest) {
    guard !overrides.isEmpty else { return }
    let resolvedKey = apiKey ?? ""
    for (key, value) in overrides {
        let resolvedValue = apiKey == nil ? value : value.replacingOccurrences(of: apiKeyPlaceholder, with: resolvedKey)
        request.setValue(resolvedValue, forHTTPHeaderField: key)
    }
}


// MARK: - Gemini 适配器实现

/// `GeminiAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Google Gemini API。
/// Gemini API 使用 `contents`/`parts` 结构，系统提示使用独立的 `system_instruction` 字段。
public class GeminiAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "GeminiAdapter")
    public private(set) var lastRequestBuildErrorMessage: String?
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    private func inferredCapabilities(for modelName: String) -> [Model.Capability] {
        let lowered = modelName.lowercased()
        var capabilities: [Model.Capability] = Model.defaultCapabilities
        if lowered.contains("tts") || lowered.contains("speech") {
            capabilities.append(.textToSpeech)
        }
        if lowered.contains("imagen") || lowered.contains("image") {
            capabilities.append(.imageGeneration)
        }
        return capabilities
    }

    private func normalizedGeminiToolParameters(_ parameters: [String: Any]) -> [String: Any] {
        normalizedGeminiSchemaValue(parameters) as? [String: Any] ?? parameters
    }

    private func normalizedGeminiSchemaValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return normalizedGeminiSchemaObject(dictionary)
        }
        if let array = value as? [Any] {
            return array.map { normalizedGeminiSchemaValue($0) }
        }
        return value
    }

    private func normalizedGeminiSchemaObject(_ object: [String: Any]) -> [String: Any] {
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

    private func flattenedGeminiSchemaCombinators(_ object: [String: Any]) -> [String: Any] {
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

    private func normalizedGeminiSchemaOptions(from rawOptions: [Any]) -> [[String: Any]] {
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

    private func preferredGeminiSchemaOption(from options: [[String: Any]]) -> [String: Any]? {
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

    private func mergedGeminiSchema(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
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

    private func normalizedGeminiSchemaPropertiesMap(_ properties: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(properties.count)
        for (key, value) in properties {
            normalized[key] = normalizedGeminiSchemaPropertyValue(value)
        }
        return normalized
    }

    private func normalizedGeminiSchemaPropertyValue(_ value: Any) -> Any {
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

    private func normalizedGeminiSchemaTypeKeyword(_ type: String) -> String? {
        let lowered = type.lowercased()
        guard lowered != "null" else { return nil }
        let supportedTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array"]
        guard supportedTypes.contains(lowered) else { return nil }
        return lowered
    }

    private func normalizedGeminiSchemaTypeValue(_ rawType: Any?) -> String? {
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

    private func inferredGeminiSchemaType(fromEnum values: [Any]) -> String? {
        let nonNullValues = values.filter { !($0 is NSNull) }
        guard let firstValue = nonNullValues.first else { return nil }
        guard let inferred = inferredGeminiSchemaType(fromValue: firstValue) else { return nil }
        for value in nonNullValues.dropFirst() where inferredGeminiSchemaType(fromValue: value) != inferred {
            return nil
        }
        return inferred
    }

    private func inferredGeminiSchemaType(fromValue value: Any) -> String? {
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

    private func inferredGeminiSchemaTypeFromCombinators(_ object: [String: Any]) -> String? {
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

    private func looksLikeGeminiLeafSchema(_ object: [String: Any]) -> Bool {
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

    private func sanitizedGeminiSchemaObject(_ object: [String: Any]) -> [String: Any] {
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
    
    private struct GeminiResponse: Decodable {
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
        }
        let usageMetadata: UsageMetadata?
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }

    private struct GeminiModelListResponse: Decodable {
        struct ModelInfo: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [ModelInfo]?
    }

    private struct GeminiErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    private struct AnyCodable: Decodable {
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
    
    private struct GeminiEmbeddingResponse: Decodable {
        struct Embedding: Decodable {
            let values: [Double]
        }
        let embedding: Embedding?
        let embeddings: [Embedding]?
    }
    
    public init() {}
    
    // MARK: - 协议方法实现
    
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        lastRequestBuildErrorMessage = nil
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        // Gemini 端点格式: /models/{model}:generateContent 或 :streamGenerateContent
        let isStreaming = commonPayload["stream"] as? Bool ?? false
        let action = isStreaming ? "streamGenerateContent" : "generateContent"
        var chatURL = baseURL.appendingPathComponent("models/\(model.model.modelName):\(action)")
        
        // Gemini 使用 URL 参数传递 API Key
        var urlComponents = URLComponents(url: chatURL, resolvingAgainstBaseURL: false)!
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        if isStreaming {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        urlComponents.queryItems = queryItems
        chatURL = urlComponents.url!
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        // 分离系统消息和普通消息
        var systemInstructionParts: [[String: Any]] = []
        var geminiContents: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    systemInstructionParts.append(["text": msg.content])
                }
                continue
            }
            
            // 映射角色: assistant -> model, user -> user, tool -> function
            let geminiRole: String
            switch msg.role {
            case .user:
                geminiRole = "user"
            case .assistant:
                geminiRole = "model"
            case .tool:
                // 工具结果需要特殊处理
                if let toolCall = msg.toolCalls?.first {
                    let rawName = toolCall.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sanitizedName = sanitizedToolName(rawName)
                    if sanitizedName.isEmpty {
                        logger.error("Gemini 工具结果缺少有效名称，已忽略该条工具响应。")
                        continue
                    }
                    var functionResponse: [String: Any] = [
                        "name": sanitizedName,
                        "response": ["result": msg.content]
                    ]
                    let toolCallId = toolCall.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !toolCallId.isEmpty {
                        functionResponse["id"] = toolCallId
                    }
                    geminiContents.append([
                        "role": "user",
                        "parts": [["functionResponse": functionResponse]]
                    ])
                }
                continue
            default:
                continue
            }
            
            var parts: [[String: Any]] = []
            
            // 检查是否有附件
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let msgFileAttachments = fileAttachments[msg.id] ?? []
            let audioAttachment = audioAttachments[msg.id]
            
            // 添加文本内容
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldSendText(trimmed) {
                parts.append(["text": trimmed])
            }
            
            // 添加图片 (Gemini 格式: inline_data)
            for imageAttachment in msgImageAttachments {
                // 从 dataURL 中提取 base64 和 mimeType
                if let (mimeType, base64Data) = parseDataURL(imageAttachment.dataURL) {
                    parts.append([
                        "inline_data": [
                            "mime_type": mimeType,
                            "data": base64Data
                        ]
                    ])
                }
            }
            
            // 添加音频 (Gemini 格式)
            if let audioAttachment = audioAttachment {
                let base64Audio = audioAttachment.data.base64EncodedString()
                let mimeType = audioAttachment.format == "wav" ? "audio/wav" : "audio/\(audioAttachment.format)"
                parts.append([
                    "inline_data": [
                        "mime_type": mimeType,
                        "data": base64Audio
                    ]
                ])
            }

            // 添加文件 (Gemini 格式: inline_data)
            for fileAttachment in msgFileAttachments {
                let base64File = fileAttachment.data.base64EncodedString()
                parts.append([
                    "inline_data": [
                        "mime_type": fileAttachment.mimeType,
                        "data": base64File
                    ]
                ])
            }
            
            // 处理 assistant 消息中的工具调用
            if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    let rawName = toolCall.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sanitizedName = sanitizedToolName(rawName)
                    if sanitizedName.isEmpty {
                        logger.error("Gemini 工具调用缺少有效名称，已忽略该条工具调用。")
                        continue
                    }
                    var argsDict: [String: Any] = [:]
                    if let argsData = toolCall.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        argsDict = parsed
                    }
                    var functionCallPart: [String: Any] = [
                        "functionCall": [
                            "name": sanitizedName,
                            "args": argsDict
                        ]
                    ]
                    let toolCallId = toolCall.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !toolCallId.isEmpty {
                        var functionCall = functionCallPart["functionCall"] as? [String: Any] ?? [:]
                        functionCall["id"] = toolCallId
                        functionCallPart["functionCall"] = functionCall
                    }
                    if let rawThoughtSignature = toolCall.providerSpecificFields?["thought_signature"],
                       case let .string(thoughtSignature) = rawThoughtSignature,
                       !thoughtSignature.isEmpty {
                        functionCallPart["thought_signature"] = thoughtSignature
                    }
                    parts.append(functionCallPart)
                }
            }
            
            if !parts.isEmpty {
                geminiContents.append([
                    "role": geminiRole,
                    "parts": parts
                ])
            }
        }
        
        // 构建请求体
        var payload: [String: Any] = [:]
        
        // 应用模型覆盖参数
        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        
        // 设置 contents
        payload["contents"] = geminiContents
        
        // 设置 system_instruction
        if !systemInstructionParts.isEmpty {
            payload["system_instruction"] = ["parts": systemInstructionParts]
        }
        
        // 构建 generationConfig
        var generationConfig: [String: Any] = [:]
        if let temperature = commonPayload["temperature"] ?? overrides["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = commonPayload["top_p"] ?? overrides["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = commonPayload["top_k"] ?? overrides["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = commonPayload["max_tokens"] ?? overrides["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        // 支持 thinking 模式
        if let thinkingBudget = overrides["thinking_budget"] {
            generationConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
        }
        if !generationConfig.isEmpty {
            payload["generationConfig"] = generationConfig
        }
        
        // 工具定义
        if let tools = tools, !tools.isEmpty {
            var schemaErrors: [String] = []
            let functionDeclarations = tools.compactMap { tool -> [String: Any]? in
                let sanitizedName = sanitizedToolName(tool.name)
                var funcDef: [String: Any] = [
                    "name": sanitizedName,
                    "description": tool.description
                ]
                guard let rawParams = tool.parameters.toAny() as? [String: Any] else {
                    schemaErrors.append(
                        String(
                            format: NSLocalizedString("错误：工具 %@ 的 parameters 必须是对象。", comment: "Tool schema parameters must be object"),
                            sanitizedName
                        )
                    )
                    return nil
                }
                switch ToolSchemaPreflight.normalizeAndValidate(schema: rawParams, toolName: sanitizedName) {
                case .success(let normalizedSchema):
                    funcDef["parameters"] = normalizedGeminiToolParameters(normalizedSchema)
                    return funcDef
                case .failure(let message):
                    schemaErrors.append(message)
                    return nil
                }
            }
            if !schemaErrors.isEmpty {
                let message = schemaErrors.joined(separator: "\n")
                lastRequestBuildErrorMessage = message
                logger.error("Gemini 工具 Schema 预校验失败：\(message, privacy: .public)")
                return nil
            }
            let validDeclarations = functionDeclarations.filter { !($0["name"] as? String ?? "").isEmpty }
            if validDeclarations.isEmpty {
                logger.error("Gemini 工具定义缺少有效名称，已跳过 tools 字段。")
            } else {
                payload["tools"] = [["function_declarations": validDeclarations]]
            }
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("构建的 Gemini 聊天请求体:\n---\n\(jsonString)\n---")
            }
            logChatRequestSnapshot(adapterName: "Gemini", request: request, payload: payload)
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
        
        return request
    }
    
    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let baseURL = URL(string: provider.baseURL) else {
            logger.error("构建模型列表请求失败: 无效的 API 基础 URL - \(provider.baseURL)")
            return nil
        }
        
        guard let apiKey = provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        var modelsURL = baseURL.appendingPathComponent("models")
        var urlComponents = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        modelsURL = urlComponents.url!
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyHeaderOverrides(provider.headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        if let errorEnvelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
           let error = errorEnvelope.error {
            throw NSError(domain: "GeminiAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        let response = try JSONDecoder().decode(GeminiModelListResponse.self, from: data)
        guard let models = response.models else {
            return []
        }

        let supportedModels = models.filter { info in
            guard let methods = info.supportedGenerationMethods else { return true }
            return methods.contains("generateContent") || methods.contains("streamGenerateContent")
        }

        return supportedModels.map { info in
            let rawName = info.name
            let normalizedName = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            return Model(
                modelName: normalizedName,
                displayName: info.displayName,
                capabilities: inferredCapabilities(for: normalizedName)
            )
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        let apiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        // 检查错误
        if let error = apiResponse.error {
            throw NSError(domain: "GeminiAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }
        
        guard let candidate = apiResponse.candidates?.first,
              let content = candidate.content,
              let parts = content.parts else {
            throw NSError(domain: "GeminiAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 content 对象"])
        }
        
        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []
        
        for (index, part) in parts.enumerated() {
            if let text = part.text {
                if part.thought == true {
                    // 这是思考内容
                    appendSegment(text, to: &reasoningContent)
                } else {
                    textContent += text
                }
            }
            if let functionCall = part.functionCall {
                let callId: String
                if let existingCallId = functionCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !existingCallId.isEmpty {
                    callId = existingCallId
                } else {
                    callId = "gemini_call_\(index)"
                }
                var argsString = "{}"
                if let args = functionCall.args {
                    let argsDict = args.mapValues { $0.value }
                    if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                       let str = String(data: argsData, encoding: .utf8) {
                        argsString = str
                    }
                }
                var providerSpecificFields: [String: JSONValue]? = nil
                if let thoughtSignature = part.thoughtSignature, !thoughtSignature.isEmpty {
                    providerSpecificFields = ["thought_signature": .string(thoughtSignature)]
                }
                internalToolCalls.append(InternalToolCall(
                    id: callId,
                    toolName: functionCall.name,
                    arguments: argsString,
                    providerSpecificFields: providerSpecificFields
                ))
            }
        }
        
        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usageMetadata)
        )
    }
    
    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }
        
        do {
            let chunk = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            guard let candidate = chunk.candidates?.first,
                  let content = candidate.content,
                  let parts = content.parts else {
                // 可能只有 usageMetadata
                if let usage = chunk.usageMetadata {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
            }
            
            var textContent: String? = nil
            var reasoningContent: String? = nil
            var toolCallDeltas: [ChatMessagePart.ToolCallDelta]? = nil
            
            for (index, part) in parts.enumerated() {
                if let text = part.text {
                    if part.thought == true {
                        reasoningContent = (reasoningContent ?? "") + text
                    } else {
                        textContent = (textContent ?? "") + text
                    }
                }
                if let functionCall = part.functionCall {
                    let callId: String
                    if let existingCallId = functionCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingCallId.isEmpty {
                        callId = existingCallId
                    } else {
                        callId = "gemini_call_\(index)"
                    }
                    var argsString: String? = nil
                    if let args = functionCall.args {
                        let argsDict = args.mapValues { $0.value }
                        if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsString = str
                        }
                    }
                    if toolCallDeltas == nil { toolCallDeltas = [] }
                    let providerSpecificFields: [String: JSONValue]?
                    if let thoughtSignature = part.thoughtSignature, !thoughtSignature.isEmpty {
                        providerSpecificFields = ["thought_signature": .string(thoughtSignature)]
                    } else {
                        providerSpecificFields = nil
                    }
                    toolCallDeltas?.append(ChatMessagePart.ToolCallDelta(
                        id: callId,
                        index: index,
                        nameFragment: functionCall.name,
                        argumentsFragment: argsString,
                        providerSpecificFields: providerSpecificFields
                    ))
                }
            }
            
            return ChatMessagePart(
                content: textContent,
                reasoningContent: reasoningContent,
                toolCallDeltas: toolCallDeltas,
                tokenUsage: makeTokenUsage(from: chunk.usageMetadata)
            )
        } catch {
            logger.warning("Gemini 流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
    
    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建嵌入请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        // Gemini 嵌入端点
        let action = texts.count == 1 ? "embedContent" : "batchEmbedContents"
        var embeddingsURL = baseURL.appendingPathComponent("models/\(model.model.modelName):\(action)")
        var urlComponents = URLComponents(url: embeddingsURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        embeddingsURL = urlComponents.url!
        
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var payload: [String: Any]
        if texts.count == 1 {
            payload = [
                "model": "models/\(model.model.modelName)",
                "content": ["parts": [["text": texts[0]]]]
            ]
        } else {
            let requests = texts.map { text in
                [
                    "model": "models/\(model.model.modelName)",
                    "content": ["parts": [["text": text]]]
                ]
            }
            payload = ["requests": requests]
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建嵌入请求失败: 无法编码 JSON - \(error.localizedDescription)")
            return nil
        }
    }
    
    public func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        do {
            let response = try JSONDecoder().decode(GeminiEmbeddingResponse.self, from: data)
            if let embedding = response.embedding {
                return [embedding.values.map { Float($0) }]
            }
            if let embeddings = response.embeddings {
                return embeddings.map { $0.values.map { Float($0) } }
            }
            throw NSError(domain: "GeminiAdapterError", code: 2, userInfo: [NSLocalizedDescriptionKey: "嵌入响应中缺少 embedding 数据"])
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("Gemini 嵌入响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Gemini 生图请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }

        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Gemini 生图请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }

        var imageURL = baseURL.appendingPathComponent("models/\(model.model.modelName):generateContent")
        var urlComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        imageURL = urlComponents.url!

        var request = URLRequest(url: imageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        var parts: [[String: Any]] = []
        if referenceImages.isEmpty {
            parts.append(["text": prompt])
        } else {
            // 与 Gemini 官方示例保持一致：先给参考图，再给编辑指令文本。
            for image in referenceImages {
                parts.append([
                    "inline_data": [
                        "mime_type": image.mimeType,
                        "data": image.data.base64EncodedString()
                    ]
                ])
            }
            parts.append(["text": prompt])
        }

        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ]
        ]

        var generationConfig: [String: Any] = [:]
        if let temperature = overrides["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = overrides["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = overrides["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = overrides["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let responseModalities = overrides["response_modalities"] ?? overrides["responseModalities"] {
            generationConfig["responseModalities"] = responseModalities
        } else {
            generationConfig["responseModalities"] = ["IMAGE"]
        }
        payload["generationConfig"] = generationConfig

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建 Gemini 生图请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let error = response.error {
            throw NSError(domain: "GeminiImageAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        var results: [GeneratedImageResult] = []
        var revisedPrompts: [String] = []

        for candidate in response.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revisedPrompts.append(text)
                }
                if let inlineData = part.inlineData,
                   let b64 = inlineData.data,
                   let imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    let mimeType = inlineData.mimeType ?? inferredImageMimeType(from: imageData)
                    results.append(GeneratedImageResult(
                        data: imageData,
                        mimeType: mimeType,
                        remoteURL: nil,
                        revisedPrompt: nil
                    ))
                }
            }
        }

        let revisedPrompt = revisedPrompts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !revisedPrompt.isEmpty {
            results = results.map { result in
                GeneratedImageResult(
                    data: result.data,
                    mimeType: result.mimeType,
                    remoteURL: result.remoteURL,
                    revisedPrompt: revisedPrompt
                )
            }
        }

        if results.isEmpty {
            throw NSError(domain: "GeminiImageAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "响应中未包含可用图片数据"])
        }
        return results
    }
    
    // MARK: - 辅助方法
    
    private func makeTokenUsage(from usage: GeminiResponse.UsageMetadata?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.promptTokenCount == nil
            && usage.candidatesTokenCount == nil
            && usage.totalTokenCount == nil
            && usage.thoughtsTokenCount == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.promptTokenCount,
            completionTokens: usage.candidatesTokenCount,
            totalTokens: usage.totalTokenCount,
            thinkingTokens: usage.thoughtsTokenCount,
            cacheWriteTokens: nil,
            cacheReadTokens: nil
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    private func parseDataURL(_ dataURL: String) -> (mimeType: String, base64Data: String)? {
        // 格式: data:image/png;base64,xxxxx
        guard dataURL.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(dataURL.dropFirst(5))
        guard let semicolonIndex = withoutPrefix.firstIndex(of: ";"),
              let commaIndex = withoutPrefix.firstIndex(of: ",") else { return nil }
        let mimeType = String(withoutPrefix[..<semicolonIndex])
        let base64Data = String(withoutPrefix[withoutPrefix.index(after: commaIndex)...])
        return (mimeType, base64Data)
    }
}


// MARK: - Anthropic 适配器实现

/// `AnthropicAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Anthropic Claude API。
/// Anthropic API 使用顶层 `system` 字段，消息中使用 content blocks 格式，工具调用使用 `tool_use`/`tool_result`。
public class AnthropicAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AnthropicAdapter")
    public private(set) var lastRequestBuildErrorMessage: String?
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }
    
    // MARK: - 内部解码模型
    
    private struct AnthropicResponse: Decodable {
        let id: String?
        let type: String?
        let role: String?
        let content: [ContentBlock]?
        let stop_reason: String?
        let usage: Usage?
        
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: [String: AnyCodable]?
            // 用于流式响应的 thinking block
            let thinking: String?
        }
        
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        
        struct Error: Decodable {
            let type: String?
            let message: String?
        }
        let error: Error?
    }
    
    /// 流式事件结构
    private struct AnthropicStreamEvent: Decodable {
        let type: String
        let index: Int?
        let content_block: AnthropicResponse.ContentBlock?
        let delta: Delta?
        let usage: AnthropicResponse.Usage?
        let message: AnthropicResponse?
        
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let partial_json: String?
            let thinking: String?
            let stop_reason: String?
            let usage: AnthropicResponse.Usage?
        }
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    private struct AnyCodable: Decodable {
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
    
    public init() {}

    private struct AnthropicModelListResponse: Decodable {
        struct ModelInfo: Decodable {
            let id: String
            let displayName: String?
            let name: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case name
            }
        }
        let data: [ModelInfo]?
    }

    private struct AnthropicErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
        }
        let error: Error?
    }
    
    // MARK: - 协议方法实现
    
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        lastRequestBuildErrorMessage = nil
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        let chatURL = baseURL.appendingPathComponent("messages")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic 使用 x-api-key header
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        // 分离系统消息和普通消息
        var systemPrompts: [String] = []
        var anthropicMessages: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    systemPrompts.append(msg.content)
                }
                continue
            }
            
            let hasUnsupportedAttachments = audioAttachments[msg.id] != nil || !(fileAttachments[msg.id] ?? []).isEmpty
            if hasUnsupportedAttachments {
                logger.warning("Anthropic 不支持音频/文件附件，已忽略该消息的附件内容。")
            }
            
            // Anthropic 只支持 user 和 assistant 角色
            let anthropicRole: String
            switch msg.role {
            case .user:
                anthropicRole = "user"
            case .assistant:
                anthropicRole = "assistant"
            case .tool:
                // 工具结果在 Anthropic 中作为 user 消息的 tool_result content block
                if let toolCall = msg.toolCalls?.first {
                    let toolResultBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolCall.id,
                        "content": msg.content
                    ]
                    anthropicMessages.append([
                        "role": "user",
                        "content": [toolResultBlock]
                    ])
                }
                continue
            default:
                continue
            }
            
            // 检查是否有附件
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let hasMedia = !msgImageAttachments.isEmpty
            
            if hasMedia && msg.role == .user {
                // 使用 content blocks 格式
                var contentBlocks: [[String: Any]] = []
                
                // 添加图片 (Anthropic 格式)
                for imageAttachment in msgImageAttachments {
                    if let (mediaType, base64Data) = parseDataURL(imageAttachment.dataURL) {
                        contentBlocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Data
                            ]
                        ])
                    }
                }
                
                // 添加文本
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    contentBlocks.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }
                
                if !contentBlocks.isEmpty {
                    anthropicMessages.append([
                        "role": anthropicRole,
                        "content": contentBlocks
                    ])
                }
            } else if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                // assistant 消息中包含工具调用
                var contentBlocks: [[String: Any]] = []
                
                // 如果有文本内容，先添加
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    contentBlocks.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }
                
                // 添加 tool_use blocks
                for toolCall in toolCalls {
                    var inputDict: [String: Any] = [:]
                    if let argsData = toolCall.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        inputDict = parsed
                    }
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": toolCall.id,
                        "name": sanitizedToolName(toolCall.toolName),
                        "input": inputDict
                    ])
                }
                
                anthropicMessages.append([
                    "role": anthropicRole,
                    "content": contentBlocks
                ])
            } else {
                // 普通文本消息
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    anthropicMessages.append([
                        "role": anthropicRole,
                        "content": msg.content
                    ])
                }
            }
        }
        
        // 构建请求体
        var payload: [String: Any] = [:]
        
        // 应用模型覆盖参数
        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        
        payload["model"] = model.model.modelName
        payload["messages"] = anthropicMessages
        
        // 设置 system
        if !systemPrompts.isEmpty {
            payload["system"] = systemPrompts.joined(separator: "\n\n")
        }
        
        // 设置生成参数
        if let maxTokens = commonPayload["max_tokens"] ?? overrides["max_tokens"] {
            payload["max_tokens"] = maxTokens
        } else {
            // Anthropic 要求必须指定 max_tokens
            payload["max_tokens"] = 8192
        }
        
        if let temperature = commonPayload["temperature"] ?? overrides["temperature"] {
            payload["temperature"] = temperature
        }
        if let topP = commonPayload["top_p"] ?? overrides["top_p"] {
            payload["top_p"] = topP
        }
        if let topK = commonPayload["top_k"] ?? overrides["top_k"] {
            payload["top_k"] = topK
        }
        
        // 流式设置
        if let stream = commonPayload["stream"] as? Bool {
            payload["stream"] = stream
        }
        
        // 支持 extended thinking
        if let thinkingBudget = overrides["thinking_budget"] {
            payload["thinking"] = [
                "type": "enabled",
                "budget_tokens": thinkingBudget
            ]
        }
        
        // 工具定义
        if let tools = tools, !tools.isEmpty {
            var schemaErrors: [String] = []
            let anthropicTools = tools.compactMap { tool -> [String: Any]? in
                let safeName = sanitizedToolName(tool.name)
                var toolDef: [String: Any] = [
                    "name": safeName,
                    "description": tool.description
                ]
                guard let rawParams = tool.parameters.toAny() as? [String: Any] else {
                    schemaErrors.append(
                        String(
                            format: NSLocalizedString("错误：工具 %@ 的 parameters 必须是对象。", comment: "Tool schema parameters must be object"),
                            safeName
                        )
                    )
                    return nil
                }
                switch ToolSchemaPreflight.normalizeAndValidate(schema: rawParams, toolName: safeName) {
                case .success(let normalizedSchema):
                    toolDef["input_schema"] = normalizedSchema
                    return toolDef
                case .failure(let message):
                    schemaErrors.append(message)
                    return nil
                }
            }
            if !schemaErrors.isEmpty {
                let message = schemaErrors.joined(separator: "\n")
                lastRequestBuildErrorMessage = message
                logger.error("Anthropic 工具 Schema 预校验失败：\(message, privacy: .public)")
                return nil
            }
            payload["tools"] = anthropicTools
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("构建的 Anthropic 聊天请求体:\n---\n\(jsonString)\n---")
            }
            logChatRequestSnapshot(adapterName: "Anthropic", request: request, payload: payload)
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
        
        return request
    }
    
    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let baseURL = URL(string: provider.baseURL) else {
            logger.error("构建模型列表请求失败: 无效的 API 基础 URL - \(provider.baseURL)")
            return nil
        }

        guard let apiKey = provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }

        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyHeaderOverrides(provider.headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        if let errorEnvelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data),
           let error = errorEnvelope.error {
            throw NSError(domain: "AnthropicAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        let response = try JSONDecoder().decode(AnthropicModelListResponse.self, from: data)
        guard let models = response.data else {
            return []
        }
        return models.map { info in
            let displayName = info.displayName ?? info.name
            return Model(modelName: info.id, displayName: displayName)
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        
        // 检查错误
        if let error = apiResponse.error {
            throw NSError(domain: "AnthropicAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }
        
        guard let contentBlocks = apiResponse.content else {
            throw NSError(domain: "AnthropicAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 content 数组"])
        }
        
        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []
        
        for block in contentBlocks {
            switch block.type {
            case "text":
                if let text = block.text {
                    textContent += text
                }
            case "thinking":
                if let thinking = block.thinking ?? block.text {
                    appendSegment(thinking, to: &reasoningContent)
                }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    var argsString = "{}"
                    if let input = block.input {
                        let inputDict = input.mapValues { $0.value }
                        if let argsData = try? JSONSerialization.data(withJSONObject: inputDict),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsString = str
                        }
                    }
                    internalToolCalls.append(InternalToolCall(id: id, toolName: name, arguments: argsString))
                }
            default:
                break
            }
        }
        
        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usage)
        )
    }
    
    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        // Anthropic 使用 SSE 格式: event: xxx\ndata: {...}
        // 这里我们处理 data: 行
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }
        
        do {
            let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            
            switch event.type {
            case "message_start":
                // 消息开始，可能包含初始 usage
                if let usage = event.message?.usage {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
                
            case "content_block_start":
                // 内容块开始
                if let block = event.content_block {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        return ChatMessagePart(
                            toolCallDeltas: [ChatMessagePart.ToolCallDelta(
                                id: id,
                                index: event.index ?? 0,
                                nameFragment: name,
                                argumentsFragment: nil
                            )]
                        )
                    }
                }
                return nil
                
            case "content_block_delta":
                // 内容块增量
                guard let delta = event.delta else { return nil }
                
                if delta.type == "text_delta", let text = delta.text {
                    return ChatMessagePart(content: text)
                }
                if delta.type == "thinking_delta", let thinking = delta.thinking {
                    return ChatMessagePart(reasoningContent: thinking)
                }
                if delta.type == "input_json_delta", let partialJson = delta.partial_json {
                    return ChatMessagePart(
                        toolCallDeltas: [ChatMessagePart.ToolCallDelta(
                            id: nil,
                            index: event.index ?? 0,
                            nameFragment: nil,
                            argumentsFragment: partialJson
                        )]
                    )
                }
                return nil
                
            case "message_delta":
                // 消息结束，包含最终 usage
                if let usage = event.usage ?? event.delta?.usage {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
                
            case "message_stop":
                // 流结束
                logger.info("Anthropic 流式传输结束。")
                return nil
                
            case "error":
                logger.error("Anthropic 流式错误: \(dataString)")
                return nil
                
            default:
                return nil
            }
        } catch {
            logger.warning("Anthropic 流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
    
    // MARK: - 辅助方法
    
    private func makeTokenUsage(from usage: AnthropicResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.input_tokens == nil
            && usage.output_tokens == nil
            && usage.cache_creation_input_tokens == nil
            && usage.cache_read_input_tokens == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.input_tokens,
            completionTokens: usage.output_tokens,
            totalTokens: nil,
            thinkingTokens: nil,
            cacheWriteTokens: usage.cache_creation_input_tokens,
            cacheReadTokens: usage.cache_read_input_tokens
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    private func parseDataURL(_ dataURL: String) -> (mediaType: String, base64Data: String)? {
        guard dataURL.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(dataURL.dropFirst(5))
        guard let semicolonIndex = withoutPrefix.firstIndex(of: ";"),
              let commaIndex = withoutPrefix.firstIndex(of: ",") else { return nil }
        let mediaType = String(withoutPrefix[..<semicolonIndex])
        let base64Data = String(withoutPrefix[withoutPrefix.index(after: commaIndex)...])
        return (mediaType, base64Data)
    }
}
