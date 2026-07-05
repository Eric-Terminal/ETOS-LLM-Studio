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

    // MARK: - Batch API
    func buildBatchFileUploadRequest(for model: RunnableModel, jsonlData: Data, purpose: String) -> URLRequest?
    func parseBatchFileUploadResponse(data: Data) throws -> String
    
    func buildBatchCreateRequest(for model: RunnableModel, fileId: String, endpoint: String, metadata: [String: String]?) -> URLRequest?
    func parseBatchCreateResponse(data: Data) throws -> BatchJob
    
    func buildBatchStatusRequest(for model: RunnableModel, batchId: String) -> URLRequest?
    func parseBatchStatusResponse(data: Data) throws -> BatchJob
    
    func buildBatchResultDownloadRequest(for model: RunnableModel, fileId: String) -> URLRequest?
    func parseBatchResultDownloadResponse(data: Data) throws -> Data
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

    func buildBatchFileUploadRequest(for model: RunnableModel, jsonlData: Data, purpose: String) -> URLRequest? { nil }
    func parseBatchFileUploadResponse(data: Data) throws -> String {
        throw NSError(domain: "APIAdapter", code: -13, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现 Batch 上传 API。", comment: "Adapter unsupported batch error")])
    }
    
    func buildBatchCreateRequest(for model: RunnableModel, fileId: String, endpoint: String, metadata: [String: String]?) -> URLRequest? { nil }
    func parseBatchCreateResponse(data: Data) throws -> BatchJob {
        throw NSError(domain: "APIAdapter", code: -13, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现 Batch 创建 API。", comment: "Adapter unsupported batch error")])
    }
    
    func buildBatchStatusRequest(for model: RunnableModel, batchId: String) -> URLRequest? { nil }
    func parseBatchStatusResponse(data: Data) throws -> BatchJob {
        throw NSError(domain: "APIAdapter", code: -13, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现 Batch 状态 API。", comment: "Adapter unsupported batch error")])
    }
    
    func buildBatchResultDownloadRequest(for model: RunnableModel, fileId: String) -> URLRequest? { nil }
    func parseBatchResultDownloadResponse(data: Data) throws -> Data {
        throw NSError(domain: "APIAdapter", code: -13, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前适配器未实现 Batch 下载 API。", comment: "Adapter unsupported batch error")])
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
// ============================================================================
// BatchModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 包含 Batch API 相关的数据结构�?// ============================================================================

import Foundation

public enum BatchJobStatus: String, Codable, Sendable {
    case validating
    case inProgress = "in_progress"
    case completed
    case failed
    case expired
    case cancelling
    case cancelled
    
    // 如果需要可以增加其他状态，�?Anthropic �?"ended" �?}

public struct BatchJob: Codable, Sendable, Identifiable {
    public let id: String
    public let providerID: UUID
    public let modelID: String
    public var status: BatchJobStatus
    public let createdAt: Date
    public var completedAt: Date?
    public var failedAt: Date?
    
    // OpenAI 专属�?    public var inputFileId: String?
    public var outputFileId: String?
    public var errorFileId: String?
    public var endpoint: String?
    
    public init(id: String, providerID: UUID, modelID: String, status: BatchJobStatus, createdAt: Date, completedAt: Date? = nil, failedAt: Date? = nil, inputFileId: String? = nil, outputFileId: String? = nil, errorFileId: String? = nil, endpoint: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.inputFileId = inputFileId
        self.outputFileId = outputFileId
        self.errorFileId = errorFileId
        self.endpoint = endpoint
    }
}

public struct BatchRequestItem: Codable, Sendable {
    public let customId: String
    public let method: String
    public let url: String
    public let body: JSONValue

    public init(customId: String, method: String, url: String, body: JSONValue) {
        self.customId = customId
        self.method = method
        self.url = url
        self.body = body
    }
    
    enum CodingKeys: String, CodingKey {
        case customId = "custom_id"
        case method
        case url
        case body
    }
}

public struct BatchResponseItem: Codable, Sendable {
    public let id: String
    public let customId: String
    public let response: BatchResponsePayload?
    public let error: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case id
        case customId = "custom_id"
        case response
        case error
    }
}

public struct BatchResponsePayload: Codable, Sendable {
    public let statusCode: Int
    public let requestId: String?
    public let body: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case requestId = "request_id"
        case body
    }
}


// MARK: - Batch Models

public enum BatchJobStatus: String, Codable, Sendable {
    case validating
    case inProgress = "in_progress"
    case completed
    case failed
    case expired
    case cancelling
    case cancelled
}

public struct BatchJob: Codable, Sendable, Identifiable {
    public let id: String
    public let providerID: UUID
    public let modelID: String
    public var status: BatchJobStatus
    public let createdAt: Date
    public var completedAt: Date?
    public var failedAt: Date?
    
    public var inputFileId: String?
    public var outputFileId: String?
    public var errorFileId: String?
    public var endpoint: String?
    
    public init(id: String, providerID: UUID, modelID: String, status: BatchJobStatus, createdAt: Date, completedAt: Date? = nil, failedAt: Date? = nil, inputFileId: String? = nil, outputFileId: String? = nil, errorFileId: String? = nil, endpoint: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.inputFileId = inputFileId
        self.outputFileId = outputFileId
        self.errorFileId = errorFileId
        self.endpoint = endpoint
    }
}

public struct BatchRequestItem: Codable, Sendable {
    public let customId: String
    public let method: String
    public let url: String
    public let body: JSONValue

    public init(customId: String, method: String, url: String, body: JSONValue) {
        self.customId = customId
        self.method = method
        self.url = url
        self.body = body
    }
    
    enum CodingKeys: String, CodingKey {
        case customId = "custom_id"
        case method
        case url
        case body
    }
}

public struct BatchResponseItem: Codable, Sendable {
    public let id: String
    public let customId: String
    public let response: BatchResponsePayload?
    public let error: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case id
        case customId = "custom_id"
        case response
        case error
    }
}

public struct BatchResponsePayload: Codable, Sendable {
    public let statusCode: Int
    public let requestId: String?
    public let body: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case requestId = "request_id"
        case body
    }
}

