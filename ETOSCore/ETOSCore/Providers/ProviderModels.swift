// ============================================================================
// ProviderModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义 API 提供商、网络代理与模型核心数据结构。
// ============================================================================

import Foundation

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

public extension Notification.Name {
    static let providerConfigurationDidChange = Notification.Name("com.ETOS.providerConfiguration.didChange")
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
    public static let defaultChatEndpointPath = "/chat/completions"

    public var id: UUID
    public var name: String
    public var baseURL: String
    /// OpenAI 兼容聊天补全端点后缀。
    public var chatEndpointPath: String
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
        chatEndpointPath: String = Provider.defaultChatEndpointPath,
        apiKeys: [String],
        apiFormat: String,
        models: [Model] = [],
        headerOverrides: [String: String] = [:],
        proxyConfiguration: NetworkProxyConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.chatEndpointPath = Self.normalizedChatEndpointPath(chatEndpointPath)
        self.apiKeys = apiKeys
        self.apiFormat = apiFormat
        self.models = models
        self.headerOverrides = headerOverrides
        self.proxyConfiguration = proxyConfiguration
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, chatEndpointPath, chatCompletionsPath, apiKeys, apiFormat, models, headerOverrides, proxyConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        let decodedChatEndpointPath = try container.decodeIfPresent(String.self, forKey: .chatEndpointPath)
            ?? container.decodeIfPresent(String.self, forKey: .chatCompletionsPath)
            ?? Self.defaultChatEndpointPath
        self.chatEndpointPath = Self.normalizedChatEndpointPath(decodedChatEndpointPath)
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
        let normalizedEndpoint = self.normalizedChatEndpointPath
        if normalizedEndpoint != Self.defaultChatEndpointPath {
            try container.encode(normalizedEndpoint, forKey: .chatEndpointPath)
        }
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

    public var normalizedChatEndpointPath: String {
        Self.normalizedChatEndpointPath(chatEndpointPath)
    }

    public static func normalizedChatEndpointPath(_ value: String) -> String {
        normalizedEndpointPath(value, defaultPath: defaultChatEndpointPath)
    }

    public static func normalizedEndpointPath(_ value: String, defaultPath: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return defaultPath
        }
        return "/" + trimmedPath
    }

    public static func appendingEndpointPath(
        _ endpointPath: String,
        to baseURL: URL,
        defaultPath: String
    ) -> URL {
        let normalizedPath = normalizedEndpointPath(endpointPath, defaultPath: defaultPath)
        return normalizedPath
            .split(separator: "/")
            .reduce(baseURL) { url, component in
                url.appendingPathComponent(String(component))
            }
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
    case embedding
    case speechToText
    case textToSpeech

    public static let editableCases: [ModelCapability] = [
        .toolCalling,
        .reasoning
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
        case .embedding:
            return NSLocalizedString("嵌入", comment: "模型兼容能力：嵌入")
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
    public var requestBodyControls: [ModelRequestBodyControl]
    public var pricing: ModelPricing?

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
        rawRequestBodyJSON: String? = nil,
        requestBodyControls: [ModelRequestBodyControl] = [],
        pricing: ModelPricing? = nil
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
        self.requestBodyControls = requestBodyControls
        let normalizedPricing = pricing?.normalized
        self.pricing = normalizedPricing?.isEffectivelyEmpty == true ? nil : normalizedPricing
    }

    public init(
        id: UUID = UUID(),
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        capabilities legacyCapabilities: [Capability],
        requestBodyOverrideMode: RequestBodyOverrideMode = .keyValue,
        rawRequestBodyJSON: String? = nil,
        requestBodyControls: [ModelRequestBodyControl] = [],
        pricing: ModelPricing? = nil
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
            rawRequestBodyJSON: rawRequestBodyJSON,
            requestBodyControls: requestBodyControls,
            pricing: pricing
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, modelName, displayName, isActivated, overrideParameters
        case kind, inputModalities, outputModalities, capabilities
        case requestBodyOverrideMode
        case rawRequestBodyJSON
        case requestBodyControls
        case pricing
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
        self.requestBodyControls = try container.decodeIfPresent([ModelRequestBodyControl].self, forKey: .requestBodyControls) ?? []
        let decodedPricing = try container.decodeIfPresent(ModelPricing.self, forKey: .pricing)?.normalized
        self.pricing = decodedPricing?.isEffectivelyEmpty == true ? nil : decodedPricing
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
        if !requestBodyControls.isEmpty {
            try container.encode(requestBodyControls, forKey: .requestBodyControls)
        }
        if let pricing = pricing?.normalized, !pricing.isEffectivelyEmpty {
            try container.encode(pricing, forKey: .pricing)
        }
    }
}
