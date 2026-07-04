// ============================================================================
// APIAdapterSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 API 适配器共享的数据结构、协议默认实现与请求辅助函数。
// ============================================================================

import Foundation

// MARK: - 流式响应的数据片段

func appendSegment(_ segment: String, to target: inout String?, separator: String = "\n\n") {
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

let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]", "[Imagen]", "[صورة]", "[Изображение]"]
let audioPlaceholders: Set<String> = ["[语音消息]", "[語音訊息]", "[音声メッセージ]", "[Voice message]", "[Voz Mensaje]", "[Voix Message]", "[الصوت رسالة]", "[Голосовое сообщение]"]
let filePlaceholders: Set<String> = ["[文件]", "[檔案]", "[ファイル]", "[File]", "[Archivo]", "[Fichier]", "[ملف]", "[Файл]"]

func shouldSendText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if imagePlaceholders.contains(trimmed) { return false }
    if audioPlaceholders.contains(trimmed) { return false }
    if filePlaceholders.contains(trimmed) { return false }
    return true
}

public enum ReasoningContentEchoPayload {
    public static let key = "reasoning_content_echo_mode"
}

func resolvedReasoningContentEchoMode(from payload: [String: Any], fallbackKey: String? = nil) -> ReasoningContentEchoMode {
    if let rawValue = payload[ReasoningContentEchoPayload.key] as? String {
        return .normalized(rawValue)
    }
    if let fallbackKey, let rawValue = payload[fallbackKey] as? String {
        return .normalized(rawValue)
    }
    return .defaultMode
}

func shouldEchoReasoningMetadata(for message: ChatMessage, mode: ReasoningContentEchoMode) -> Bool {
    switch mode {
    case .always:
        return true
    case .toolCallsOnly:
        return message.role == .assistant && !(message.toolCalls ?? []).isEmpty
    case .never:
        return false
    }
}

func resolvedRequestModelName(for model: RunnableModel, overrides: [String: Any]) -> String {
    if let overrideModel = overrides["model"] as? String {
        let trimmed = overrideModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return model.model.modelName
}

// 让高级自定义 Body 和适配器生成字段共存；数组拼接用于保留双方工具声明。
func mergedRequestPayload(_ base: [String: Any], with overlay: [String: Any]) -> [String: Any] {
    var result = base
    for (key, overlayValue) in overlay {
        if let baseDictionary = result[key] as? [String: Any],
           let overlayDictionary = overlayValue as? [String: Any] {
            result[key] = mergedRequestPayload(baseDictionary, with: overlayDictionary)
        } else if let baseArray = result[key] as? [Any],
                  let overlayArray = overlayValue as? [Any] {
            result[key] = baseArray + overlayArray
        } else {
            result[key] = overlayValue
        }
    }
    return result
}

func stableToolDefinitions(
    _ tools: [InternalToolDefinition],
    sanitizedName: (String) -> String
) -> [InternalToolDefinition] {
    tools.sorted { lhs, rhs in
        let lhsFields = stableToolSortFields(for: lhs, sanitizedName: sanitizedName)
        let rhsFields = stableToolSortFields(for: rhs, sanitizedName: sanitizedName)
        for index in lhsFields.indices {
            guard lhsFields[index] != rhsFields[index] else { continue }
            return lhsFields[index] < rhsFields[index]
        }
        return false
    }
}

private func stableToolSortFields(
    for tool: InternalToolDefinition,
    sanitizedName: (String) -> String
) -> [String] {
    let sanitizedToolName = sanitizedName(tool.name)
    return [
        sanitizedToolName.lowercased(),
        sanitizedToolName,
        tool.name.lowercased(),
        tool.name,
        tool.description,
        tool.parameters.prettyPrintedCompact(),
        tool.isBlocking ? "1" : "0"
    ]
}

func stableJSONSchemaRequiredArray(_ required: [Any]) -> [Any] {
    let stringValues = required.compactMap { $0 as? String }
    guard stringValues.count == required.count else { return required }
    return stringValues.sorted()
}

func stableJSONSchemaValueForTransport(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        var stable: [String: Any] = [:]
        stable.reserveCapacity(dictionary.count)
        for (key, rawValue) in dictionary {
            if key == "required", let required = rawValue as? [Any] {
                stable[key] = stableJSONSchemaRequiredArray(required)
            } else {
                stable[key] = stableJSONSchemaValueForTransport(rawValue)
            }
        }
        return stable
    }
    if let array = value as? [Any] {
        return array.map { stableJSONSchemaValueForTransport($0) }
    }
    return value
}

func inferredImageMimeType(from data: Data) -> String {
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

func logChatRequestSnapshot(
    adapterName: String,
    request: URLRequest,
    payload: [String: Any]
) {
    guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return }

    var detailPayload: [String: String] = [
        NSLocalizedString("适配器", comment: "App log payload key"): adapterName,
        NSLocalizedString("方法", comment: "App log payload key"): request.httpMethod ?? "POST",
        NSLocalizedString("地址", comment: "App log payload key"): AppLogRedactor.sanitizeURLForLog(request.url),
        NSLocalizedString("请求体字节数", comment: "App log payload key"): "\(request.httpBody?.count ?? 0)"
    ]

    if let headers = AppLogRedactor.sanitizeHeadersForLog(request.allHTTPHeaderFields) {
        detailPayload[NSLocalizedString("请求头", comment: "App log payload key")] = headers
    }
    let exposesMessageFields = AppConfigStore.boolValue(for: .requestLogPlainMessageEnabled)
    if let body = AppLogRedactor.sanitizeRequestBodyForLog(payload, exposesMessageFields: exposesMessageFields) {
        let bodyKey = exposesMessageFields
            ? NSLocalizedString("请求体(含明文消息)", comment: "App log payload key")
            : NSLocalizedString("请求体(不含消息字段)", comment: "App log payload key")
        detailPayload[bodyKey] = body
    } else {
        detailPayload[NSLocalizedString("请求体(不含消息字段)", comment: "App log payload key")] = NSLocalizedString("[无法序列化]", comment: "App log payload value")
    }

    AppLog.developer(
        level: .debug,
        category: NSLocalizedString("请求", comment: "App log category"),
        action: String(format: NSLocalizedString("构建%@请求", comment: "App log action"), adapterName),
        message: String(format: NSLocalizedString("%@ 请求体已生成", comment: "App log message"), adapterName),
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
        public var argumentsReplacement: String? = nil
        public var providerSpecificFields: [String: JSONValue]? = nil
    }

    public var content: String?
    public var reasoningContent: String?
    public var reasoningProviderSpecificFields: [String: JSONValue]?
    public var providerResponseMetadata: [String: JSONValue]?
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

// MARK: - API 适配器协议

/// `APIAdapter` 协议定义了一个标准接口，用于处理不同 LLM 提供商的 API 请求构建和响应解析。
/// 这使得 `ChatService` 无需关心特定 API 的细节，从而轻松支持多种后端。
public protocol APIAdapter {
    func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest?
    func buildModelListRequest(for provider: Provider) -> URLRequest?
    func parseModelListResponse(data: Data) throws -> [Model]
    func parseResponse(data: Data) throws -> ChatMessage
    func parseStreamingResponse(line: String) -> ChatMessagePart?
    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest?
    func parseTranscriptionResponse(data: Data) throws -> String
    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest?
    func parseEmbeddingResponse(data: Data) throws -> [[Float]]
    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest?
    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult]
}

public extension APIAdapter {
    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest? {
        nil
    }

    func parseTranscriptionResponse(data: Data) throws -> String {
        throw NSError(domain: "APIAdapter", code: -10, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现语音转文字功能。", comment: "Adapter unsupported transcription error")])
    }

    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        nil
    }

    func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        throw NSError(domain: "APIAdapter", code: -11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现嵌入 API。", comment: "Adapter unsupported embedding error")])
    }

    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        nil
    }

    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        throw NSError(domain: "APIAdapter", code: -12, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现生图 API。", comment: "Adapter unsupported image generation error")])
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { Model(modelName: $0.id) }
    }
}

let apiKeyPlaceholder = "{api_key}"

func applyHeaderOverrides(_ overrides: [String: String], apiKey: String?, to request: inout URLRequest) {
    guard !overrides.isEmpty else { return }
    let resolvedKey = apiKey ?? ""
    for (key, value) in overrides {
        let resolvedValue = apiKey == nil ? value : value.replacingOccurrences(of: apiKeyPlaceholder, with: resolvedKey)
        request.setValue(resolvedValue, forHTTPHeaderField: key)
    }
}

extension Data {
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
