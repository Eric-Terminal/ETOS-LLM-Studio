// ============================================================================
// Models.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据模型文件
//
// 定义内容:
// - Provider/Model: 用户自定义的提供商与模型配置
// - ChatMessage: 聊天消息结构 (核心数据模型)
// - ChatSession: 聊天会话结构
// - 其他与数据相关的枚举和结构体
// ============================================================================

import Foundation
import SwiftUI
import CoreGraphics
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 提供商与模型配置

/// 可编码的通用 JSON 值，用于处理 [String: Any] 类型的字典
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .dictionary(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: c.codingPath, debugDescription: "不支持的 JSON 类型")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .dictionary(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .dictionary(let v): return v.mapValues { $0.toAny() }
        case .array(let v): return v.map { $0.toAny() }
        case .null: return NSNull()
        }
    }

    public func prettyPrintedCompact() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(self)"
    }
}

/// 兼容 OpenAI 风格的模型列表响应
public struct ModelListResponse: Decodable {
    public struct ModelData: Decodable {
        public let id: String
        public let object: String?
        public let created: Int?
        public let ownedBy: String?
        
        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }
    
    public let data: [ModelData]
}

public enum NetworkProxyType: String, Codable, Hashable, CaseIterable, Sendable {
    case http
    case socks5
}

public struct NetworkProxyConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var type: NetworkProxyType
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(
        isEnabled: Bool = false,
        type: NetworkProxyType = .http,
        host: String = "",
        port: Int = 8080,
        username: String = "",
        password: String = ""
    ) {
        self.isEnabled = isEnabled
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasAuthentication: Bool {
        !trimmedUsername.isEmpty
    }

    public var normalizedIfEnabled: NetworkProxyConfiguration? {
        guard isEnabled else { return nil }
        let normalizedHost = trimmedHost
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else {
            return nil
        }
        return NetworkProxyConfiguration(
            isEnabled: true,
            type: type,
            host: normalizedHost,
            port: port,
            username: trimmedUsername,
            password: trimmedPassword
        )
    }
}


/// 代表一个用户自定义的 API 服务提供商
public struct Provider: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    /// 提供商 API Key，会随 Provider 一起持久化到 JSON（明文）。
    public var apiKeys: [String]
    public var apiFormat: String // 例如: "openai-compatible"
    public var models: [Model]
    public var headerOverrides: [String: String]
    /// 提供商独立代理。为 `nil` 时回退到全局代理设置。
    public var proxyConfiguration: NetworkProxyConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKeys: [String],
        apiFormat: String,
        models: [Model] = [],
        headerOverrides: [String: String] = [:],
        proxyConfiguration: NetworkProxyConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeys = apiKeys
        self.apiFormat = apiFormat
        self.models = models
        self.headerOverrides = headerOverrides
        self.proxyConfiguration = proxyConfiguration
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKeys, apiFormat, models, headerOverrides, proxyConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.apiKeys = try container.decodeIfPresent([String].self, forKey: .apiKeys) ?? []
        self.apiFormat = try container.decode(String.self, forKey: .apiFormat)
        self.models = try container.decodeIfPresent([Model].self, forKey: .models) ?? []
        self.headerOverrides = try container.decodeIfPresent([String: String].self, forKey: .headerOverrides) ?? [:]
        self.proxyConfiguration = try container.decodeIfPresent(NetworkProxyConfiguration.self, forKey: .proxyConfiguration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        if !apiKeys.isEmpty {
            try container.encode(apiKeys, forKey: .apiKeys)
        }
        try container.encode(apiFormat, forKey: .apiFormat)
        try container.encode(models, forKey: .models)
        if !headerOverrides.isEmpty {
            try container.encode(headerOverrides, forKey: .headerOverrides)
        }
        if let proxyConfiguration {
            try container.encode(proxyConfiguration, forKey: .proxyConfiguration)
        }
    }
}

public extension Provider {
    func applyingInferredModelCapabilityHints() -> Provider {
        var repaired = self
        repaired.models = models.map { $0.applyingInferredCapabilityHints() }
        return repaired
    }
}

/// 代表一个在提供商下的具体模型
public enum ModelKind: String, Codable, Hashable, CaseIterable, Sendable {
    case chat
    case image
    case embedding
    case rerank
    case speechToText
    case textToSpeech

    public var localizedName: String {
        switch self {
        case .chat:
            return NSLocalizedString("聊天", comment: "模型主用途：聊天")
        case .image:
            return NSLocalizedString("图片生成", comment: "模型主用途：图片生成")
        case .embedding:
            return NSLocalizedString("嵌入", comment: "模型主用途：嵌入")
        case .rerank:
            return NSLocalizedString("重排", comment: "模型主用途：重排")
        case .speechToText:
            return NSLocalizedString("语音转文字", comment: "模型主用途：语音转文字")
        case .textToSpeech:
            return NSLocalizedString("文字转语音", comment: "模型主用途：文字转语音")
        }
    }
}

public enum ModelModality: String, Codable, Hashable, CaseIterable, Sendable {
    case text
    case image
    case audio
    case file

    public static let outputCases: [ModelModality] = [.text, .image, .audio]

    public var localizedName: String {
        switch self {
        case .text:
            return NSLocalizedString("文本", comment: "模型模态：文本")
        case .image:
            return NSLocalizedString("图像", comment: "模型模态：图像")
        case .audio:
            return NSLocalizedString("音频", comment: "模型模态：音频")
        case .file:
            return NSLocalizedString("文件", comment: "模型模态：文件")
        }
    }
}

public enum ModelCapability: String, Codable, Hashable, CaseIterable, Sendable {
    case toolCalling
    case reasoning
    case streaming
    case jsonMode
    case speechToText
    case textToSpeech

    public static let editableCases: [ModelCapability] = [
        .toolCalling
    ]

    public var localizedName: String {
        switch self {
        case .toolCalling:
            return NSLocalizedString("工具调用", comment: "模型协议能力：工具调用")
        case .reasoning:
            return NSLocalizedString("推理", comment: "模型协议能力：推理")
        case .streaming:
            return NSLocalizedString("流式输出", comment: "模型协议能力：流式输出")
        case .jsonMode:
            return NSLocalizedString("JSON 模式", comment: "模型协议能力：JSON 模式")
        case .speechToText:
            return NSLocalizedString("语音转文字", comment: "模型兼容能力：语音转文字")
        case .textToSpeech:
            return NSLocalizedString("文字转语音", comment: "模型兼容能力：文字转语音")
        }
    }
}

/// 代表一个在提供商下的具体模型
public struct Model: Codable, Identifiable, Hashable {
    public enum Capability: String, Codable, Hashable, Sendable {
        case chat
        case toolCalling
        case speechToText
        case textToSpeech
        case embedding
        case imageGeneration
    }

    public static let defaultCapabilities: [ModelCapability] = [.toolCalling]

    public enum RequestBodyOverrideMode: String, Codable, Hashable {
        case keyValue
        case expression
        case rawJSON
    }
    
    public var id: UUID
    public var modelName: String // 模型ID，例如: "deepseek-chat"
    public var displayName: String
    public var isActivated: Bool
    public var overrideParameters: [String: JSONValue]
    public var kind: ModelKind
    public var inputModalities: [ModelModality]
    public var outputModalities: [ModelModality]
    public var capabilities: [ModelCapability]
    public var requestBodyOverrideMode: RequestBodyOverrideMode
    public var rawRequestBodyJSON: String?

    public init(
        id: UUID = UUID(),
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        kind: ModelKind? = .chat,
        inputModalities: [ModelModality]? = nil,
        outputModalities: [ModelModality]? = nil,
        capabilities: [ModelCapability]? = nil,
        legacyCapabilityRawValues: [String]? = nil,
        requestBodyOverrideMode: RequestBodyOverrideMode = .keyValue,
        rawRequestBodyJSON: String? = nil
    ) {
        let normalized = Self.normalizedCapabilityShape(
            kind: kind,
            inputModalities: inputModalities,
            outputModalities: outputModalities,
            capabilities: capabilities,
            legacyCapabilityRawValues: legacyCapabilityRawValues
        )
        self.id = id
        self.modelName = modelName
        self.displayName = displayName ?? modelName
        self.isActivated = isActivated
        self.overrideParameters = overrideParameters
        self.kind = normalized.kind
        self.inputModalities = normalized.inputModalities
        self.outputModalities = normalized.outputModalities
        self.capabilities = normalized.capabilities
        self.requestBodyOverrideMode = requestBodyOverrideMode
        self.rawRequestBodyJSON = rawRequestBodyJSON
    }

    public init(
        id: UUID = UUID(),
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        capabilities legacyCapabilities: [Capability],
        requestBodyOverrideMode: RequestBodyOverrideMode = .keyValue,
        rawRequestBodyJSON: String? = nil
    ) {
        self.init(
            id: id,
            modelName: modelName,
            displayName: displayName,
            isActivated: isActivated,
            overrideParameters: overrideParameters,
            kind: nil,
            legacyCapabilityRawValues: legacyCapabilities.map(\.rawValue),
            requestBodyOverrideMode: requestBodyOverrideMode,
            rawRequestBodyJSON: rawRequestBodyJSON
        )
    }
    
    enum CodingKeys: String, CodingKey {
        case id, modelName, displayName, isActivated, overrideParameters
        case kind, inputModalities, outputModalities, capabilities
        case requestBodyOverrideMode
        case rawRequestBodyJSON
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? modelName
        self.isActivated = try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? false
        self.overrideParameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .overrideParameters) ?? [:]
        let decodedKind = try container.decodeIfPresent(ModelKind.self, forKey: .kind)
        let decodedInputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities)
            .map { Self.orderedModalities($0.compactMap(ModelModality.init(rawValue:))) }
        let decodedOutputModalities = try container.decodeIfPresent([String].self, forKey: .outputModalities)
            .map { Self.orderedOutputModalities($0.compactMap(ModelModality.init(rawValue:))) }
        let rawCapabilityValues = try container.decodeIfPresent([String].self, forKey: .capabilities)
        let decodedCapabilities = rawCapabilityValues
            .map { Self.orderedCapabilities($0.compactMap(ModelCapability.init(rawValue:))) }
        let normalized = Self.normalizedCapabilityShape(
            kind: decodedKind,
            inputModalities: decodedInputModalities,
            outputModalities: decodedOutputModalities,
            capabilities: decodedCapabilities,
            legacyCapabilityRawValues: rawCapabilityValues
        )
        self.kind = normalized.kind
        self.inputModalities = normalized.inputModalities
        self.outputModalities = normalized.outputModalities
        self.capabilities = normalized.capabilities
        self.requestBodyOverrideMode = try container.decodeIfPresent(RequestBodyOverrideMode.self, forKey: .requestBodyOverrideMode) ?? .keyValue
        self.rawRequestBodyJSON = try container.decodeIfPresent(String.self, forKey: .rawRequestBodyJSON)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(modelName, forKey: .modelName)
        if displayName != modelName {
            try container.encode(displayName, forKey: .displayName)
        }
        try container.encode(isActivated, forKey: .isActivated)
        if !overrideParameters.isEmpty {
            try container.encode(overrideParameters, forKey: .overrideParameters)
        }
        if kind != .chat {
            try container.encode(kind, forKey: .kind)
        }
        if inputModalities != Self.defaultInputModalities(for: kind) {
            try container.encode(inputModalities, forKey: .inputModalities)
        }
        if outputModalities != Self.defaultOutputModalities(for: kind) {
            try container.encode(outputModalities, forKey: .outputModalities)
        }
        if capabilities != Self.defaultCapabilities(for: kind) {
            try container.encode(capabilities, forKey: .capabilities)
        }
        if requestBodyOverrideMode != .keyValue {
            try container.encode(requestBodyOverrideMode, forKey: .requestBodyOverrideMode)
        }
        if let rawRequestBodyJSON, !rawRequestBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(rawRequestBodyJSON, forKey: .rawRequestBodyJSON)
        }
    }
}

public extension Model {
    mutating func resetCapabilityShape(for kind: ModelKind) {
        self.kind = kind
        inputModalities = Self.defaultInputModalities(for: kind)
        outputModalities = Self.defaultOutputModalities(for: kind)
        capabilities = Self.defaultCapabilities(for: kind)
    }

    static func defaultInputModalities(for kind: ModelKind) -> [ModelModality] {
        switch kind {
        case .chat:
            return [.text]
        case .image:
            return [.text, .image]
        case .embedding, .rerank:
            return [.text]
        case .speechToText:
            return [.audio]
        case .textToSpeech:
            return [.text]
        }
    }

    static func defaultOutputModalities(for kind: ModelKind) -> [ModelModality] {
        switch kind {
        case .chat:
            return [.text]
        case .image:
            return [.image]
        case .embedding:
            return []
        case .rerank:
            return [.text]
        case .speechToText:
            return [.text]
        case .textToSpeech:
            return [.audio]
        }
    }

    static func defaultCapabilities(for kind: ModelKind) -> [ModelCapability] {
        switch kind {
        case .chat:
            return defaultCapabilities
        case .image, .embedding, .rerank, .speechToText, .textToSpeech:
            return []
        }
    }

    static func orderedModalities(_ modalities: [ModelModality]) -> [ModelModality] {
        let modalitySet = Set(modalities)
        return ModelModality.allCases.filter { modalitySet.contains($0) }
    }

    static func orderedOutputModalities(_ modalities: [ModelModality]) -> [ModelModality] {
        let modalitySet = Set(modalities)
        return ModelModality.outputCases.filter { modalitySet.contains($0) }
    }

    static func orderedCapabilities(_ capabilities: [ModelCapability]) -> [ModelCapability] {
        let capabilitySet = Set(capabilities)
        return ModelCapability.allCases.filter { capabilitySet.contains($0) }
    }

    static func inferred(
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        supportedGenerationMethods: [String]? = nil
    ) -> Model {
        let profile = inferredCapabilityShape(
            modelName: modelName,
            displayName: displayName,
            supportedGenerationMethods: supportedGenerationMethods
        )
        return Model(
            modelName: modelName,
            displayName: displayName,
            isActivated: isActivated,
            kind: profile.kind,
            inputModalities: profile.inputModalities,
            outputModalities: profile.outputModalities,
            capabilities: profile.capabilities
        )
    }

    func applyingInferredCapabilityHints() -> Model {
        let inferred = Self.inferredCapabilityShape(
            modelName: modelName,
            displayName: displayName,
            supportedGenerationMethods: nil
        )

        let originalKind = kind
        let originalInputModalities = inputModalities
        let originalOutputModalities = outputModalities
        let originalCapabilities = capabilities
        var repaired = self

        if repaired.kind == .chat, inferred.kind != .chat {
            repaired.kind = inferred.kind
        }

        let shouldApplyInferredShape = originalKind == .chat || inferred.kind == originalKind
        guard shouldApplyInferredShape else {
            return repaired
        }

        if originalInputModalities == Self.defaultInputModalities(for: originalKind) {
            repaired.inputModalities = inferred.inputModalities
        }
        if originalOutputModalities == Self.defaultOutputModalities(for: originalKind) {
            repaired.outputModalities = inferred.outputModalities
        }
        if originalCapabilities == Self.defaultCapabilities(for: originalKind) {
            repaired.capabilities = inferred.capabilities
        }
        return repaired
    }
}

private extension Model {
    enum LegacyCapability: String {
        case chat
        case toolCalling
        case speechToText
        case textToSpeech
        case embedding
        case imageGeneration
    }

    struct CapabilityShape {
        var kind: ModelKind
        var inputModalities: [ModelModality]
        var outputModalities: [ModelModality]
        var capabilities: [ModelCapability]
    }

    static func normalizedCapabilityShape(
        kind explicitKind: ModelKind? = nil,
        inputModalities explicitInputModalities: [ModelModality]? = nil,
        outputModalities explicitOutputModalities: [ModelModality]? = nil,
        capabilities explicitCapabilities: [ModelCapability]? = nil,
        legacyCapabilityRawValues: [String]? = nil
    ) -> CapabilityShape {
        let legacyCapabilities = legacyCapabilityRawValues?.compactMap(LegacyCapability.init(rawValue:)) ?? []
        let legacySet = Set(legacyCapabilities)

        let resolvedKind: ModelKind
        if let explicitKind {
            resolvedKind = explicitKind
        } else if legacySet.contains(.embedding) {
            resolvedKind = .embedding
        } else if legacySet.contains(.speechToText) {
            resolvedKind = .speechToText
        } else if legacySet.contains(.textToSpeech) {
            resolvedKind = .textToSpeech
        } else if legacySet.contains(.imageGeneration), !legacySet.contains(.chat) {
            resolvedKind = .image
        } else {
            resolvedKind = .chat
        }

        var resolvedInputModalities = explicitInputModalities ?? defaultInputModalities(for: resolvedKind)
        var resolvedOutputModalities = explicitOutputModalities ?? defaultOutputModalities(for: resolvedKind)
        var resolvedCapabilities = explicitCapabilities ?? (legacyCapabilityRawValues == nil ? defaultCapabilities(for: resolvedKind) : [])

        if legacySet.contains(.toolCalling), !resolvedCapabilities.contains(.toolCalling) {
            resolvedCapabilities.append(.toolCalling)
        }
        if legacySet.contains(.speechToText), !resolvedInputModalities.contains(.audio) {
            resolvedInputModalities.append(.audio)
        }
        if legacySet.contains(.speechToText), !resolvedCapabilities.contains(.speechToText) {
            resolvedCapabilities.append(.speechToText)
        }
        if legacySet.contains(.textToSpeech), !resolvedOutputModalities.contains(.audio) {
            resolvedOutputModalities.append(.audio)
        }
        if legacySet.contains(.textToSpeech), !resolvedCapabilities.contains(.textToSpeech) {
            resolvedCapabilities.append(.textToSpeech)
        }
        if legacySet.contains(.imageGeneration) {
            if resolvedKind == .image {
                if !resolvedOutputModalities.contains(.image) {
                    resolvedOutputModalities.append(.image)
                }
            } else {
                if !resolvedOutputModalities.contains(.image) {
                    resolvedOutputModalities.append(.image)
                }
            }
        }

        return CapabilityShape(
            kind: resolvedKind,
            inputModalities: orderedModalities(resolvedInputModalities),
            outputModalities: orderedOutputModalities(resolvedOutputModalities),
            capabilities: orderedCapabilities(resolvedCapabilities)
        )
    }

    static func inferredCapabilityShape(
        modelName: String,
        displayName: String?,
        supportedGenerationMethods: [String]?
    ) -> CapabilityShape {
        let searchableName = [modelName, displayName].compactMap { $0?.lowercased() }.joined(separator: " ")
        let normalizedName = searchableName
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        let supportsGenerateContent = supportedGenerationMethods?.contains(where: { method in
            method == "generateContent" || method == "streamGenerateContent"
        }) ?? true
        let supportsEmbedding = supportedGenerationMethods?.contains(where: { method in
            method == "embedContent" || method == "batchEmbedContents" || method == "asyncBatchEmbedContent"
        }) ?? false

        let imageModelSignals = [
            "dall-e",
            "gpt-image",
            "imagen",
            "flux",
            "stable-diffusion",
            "qwen-image"
        ]
        let rerankSignals = ["rerank", "re-rank"]
        let embeddingSignals = ["embedding", "embed"]
        let speechToTextSignals = ["transcribe", "transcription", "whisper", "speech-to-text", "stt"]
        let textToSpeechSignals = ["text-to-speech", "tts", "speech"]

        let kind: ModelKind
        if containsAny(normalizedName, signals: embeddingSignals) || (supportsEmbedding && !supportsGenerateContent) {
            kind = .embedding
        } else if containsAny(normalizedName, signals: rerankSignals) {
            kind = .rerank
        } else if containsAny(normalizedName, signals: imageModelSignals) {
            kind = .image
        } else if containsAny(normalizedName, signals: speechToTextSignals) {
            kind = .speechToText
        } else if containsAny(normalizedName, signals: textToSpeechSignals) {
            kind = .textToSpeech
        } else {
            kind = .chat
        }

        var inputModalities = defaultInputModalities(for: kind)
        let outputModalities = defaultOutputModalities(for: kind)
        let capabilities = defaultCapabilities(for: kind)

        if kind == .chat {
            let visionSignals = [
                "gpt-4o",
                "gpt-4.1",
                "gpt-5",
                "claude-3",
                "claude-4",
                "gemini",
                "qwen-vl",
                "qwen2-vl",
                "qwen2.5-vl",
                "qwen-omni",
                "llava",
                "pixtral"
            ]
            if containsAny(normalizedName, signals: visionSignals), !inputModalities.contains(.image) {
                inputModalities.append(.image)
            }

        }

        return CapabilityShape(
            kind: kind,
            inputModalities: orderedModalities(inputModalities),
            outputModalities: orderedOutputModalities(outputModalities),
            capabilities: orderedCapabilities(capabilities)
        )
    }

    static func containsAny(_ text: String, signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }
}

public enum ModelOrderIndex {
    public static func merge(storedIDs: [String], currentIDs: [String]) -> [String] {
        let currentSet = Set(currentIDs)
        var result: [String] = []
        result.reserveCapacity(currentIDs.count)
        var seen = Set<String>()

        for id in storedIDs where currentSet.contains(id) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in currentIDs {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public static func move(ids: [String], fromPosition source: Int, toPosition destination: Int) -> [String] {
        var orderedIDs = ids
        guard source >= 0 && source < orderedIDs.count else { return ids }
        guard destination >= 0 && destination < orderedIDs.count else { return ids }
        guard source != destination else { return ids }

        let moved = orderedIDs.remove(at: source)
        orderedIDs.insert(moved, at: destination)
        return orderedIDs
    }
}

public extension Provider {
    /// 仅重排已添加模型（isActivated = true）的相对顺序，不影响未添加模型的相对顺序。
    /// - Parameters:
    ///   - offsets: 拖拽源索引（基于“已添加模型”子列表）
    ///   - destination: 拖拽目标索引（基于“已添加模型”子列表）
    mutating func moveActivatedModels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard destination >= 0 && destination <= activatedCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < activatedCount }) else { return }
        guard !offsets.isEmpty else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        moveElements(in: &activatedModels, fromOffsets: offsets, toOffset: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }

    /// 将已添加模型子列表中的某一项移动到目标位置。
    /// - Parameters:
    ///   - source: 源位置（基于“已添加模型”子列表）
    ///   - destination: 目标位置（基于“已添加模型”子列表）
    mutating func moveActivatedModel(fromPosition source: Int, toPosition destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard source >= 0 && source < activatedCount else { return }
        guard destination >= 0 && destination < activatedCount else { return }
        guard source != destination else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        let moved = activatedModels.remove(at: source)
        activatedModels.insert(moved, at: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }
}

public extension Model {
    var supportsToolCalling: Bool {
        capabilities.contains(.toolCalling)
    }

    var supportsReasoning: Bool {
        capabilities.contains(.reasoning)
    }

    var supportsStreaming: Bool {
        capabilities.contains(.streaming)
    }

    var supportsJSONMode: Bool {
        capabilities.contains(.jsonMode)
    }

    var supportsSpeechToText: Bool {
        kind == .speechToText || capabilities.contains(.speechToText)
    }

    var supportsTextToSpeech: Bool {
        kind == .textToSpeech || capabilities.contains(.textToSpeech)
    }
    
    var supportsEmbedding: Bool {
        kind == .embedding
    }

    var supportsRerank: Bool {
        kind == .rerank
    }

    var supportsVisionInput: Bool {
        inputModalities.contains(.image)
    }

    var supportsImageGeneration: Bool {
        kind == .image || outputModalities.contains(.image)
    }

    var isChatModel: Bool {
        kind == .chat
    }

    /// 识别是否属于主流模型家族（用于模型列表分组与筛选）
    var mainstreamFamily: MainstreamModelFamily? {
        MainstreamModelFamily.detect(
            modelName: modelName,
            displayName: displayName
        )
    }

    var isMainstreamModel: Bool {
        mainstreamFamily != nil
    }
}

/// 常见主流模型家族（用于“主流/其他”分组）
public enum MainstreamModelFamily: String, Codable, Hashable, CaseIterable, Sendable {
    case chatgpt
    case gemini
    case claude
    case deepseek
    case qwen
    case kimi
    case doubao
    case grok
    case llama
    case mistral
    case glm

    public var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return "Qwen"
        case .kimi:
            return "Kimi"
        case .doubao:
            return "Doubao"
        case .grok:
            return "Grok"
        case .llama:
            return "Llama"
        case .mistral:
            return "Mistral"
        case .glm:
            return "GLM"
        }
    }

    public static func detect(modelName: String, displayName: String? = nil) -> MainstreamModelFamily? {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchableText = "\(normalizedModelName) \(normalizedDisplayName)"

        if let matched = detectByKeyword(in: searchableText, modelName: normalizedModelName) {
            return matched
        }
        if isChatGPTFamily(modelName: normalizedModelName, displayName: normalizedDisplayName) {
            return .chatgpt
        }
        return nil
    }

    private static let keywordRules: [(family: MainstreamModelFamily, keywords: [String])] = [
        (.gemini, ["gemini"]),
        (.claude, ["claude"]),
        (.deepseek, ["deepseek"]),
        (.qwen, ["qwen"]),
        (.kimi, ["kimi", "moonshot"]),
        (.doubao, ["doubao", "豆包"]),
        (.grok, ["grok"]),
        (.llama, ["llama", "meta-llama"]),
        (.mistral, ["mistral", "mixtral"]),
        (.glm, ["chatglm", "glm-"])
    ]

    private static func detectByKeyword(in searchableText: String, modelName: String) -> MainstreamModelFamily? {
        for rule in keywordRules {
            if rule.keywords.contains(where: { searchableText.contains($0) }) {
                return rule.family
            }
        }
        if modelName.hasPrefix("glm") {
            return .glm
        }
        return nil
    }

    private static func isChatGPTFamily(modelName: String, displayName: String) -> Bool {
        if displayName.contains("chatgpt") || displayName.contains("openai") {
            return true
        }
        if modelName.contains("chatgpt") || modelName.contains("openai") {
            return true
        }
        if modelName.hasPrefix("gpt-") || modelName.contains("/gpt-") {
            return true
        }
        if modelName.hasPrefix("o1") || modelName.hasPrefix("o3") || modelName.hasPrefix("o4") {
            return true
        }
        if modelName.contains("gpt-4")
            || modelName.contains("gpt-5")
            || modelName.contains("gpt-3.5")
            || modelName.contains("gpt4o") {
            return true
        }
        return false
    }
}
