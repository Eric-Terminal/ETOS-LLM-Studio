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

let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]
let audioPlaceholders: Set<String> = ["[语音消息]", "[語音訊息]", "[音声メッセージ]", "[Voice message]"]
let filePlaceholders: Set<String> = ["[文件]", "[檔案]", "[ファイル]", "[File]"]

func shouldSendText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if imagePlaceholders.contains(trimmed) { return false }
    if audioPlaceholders.contains(trimmed) { return false }
    if filePlaceholders.contains(trimmed) { return false }
    return true
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
    public var reasoningProviderSpecificFields: [String: JSONValue]?
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
