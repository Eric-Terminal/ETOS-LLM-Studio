// ============================================================================
// LocalLLMEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// Swift 侧本地推理入口，底层由 C shim 隔离 llama.cpp 细节。
// ============================================================================

import Foundation
import Darwin

public struct LocalLLMGenerationOptions: Hashable, Sendable {
    public var contextSize: Int
    public var maxOutputTokens: Int
    public var gpuLayers: Int
    public var batchSize: Int
    public var ubatchSize: Int
    public var kvOffload: Bool
    public var flashAttention: LocalLLMFlashAttentionMode
    public var useModelCache: Bool
    public var seed: UInt32
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    public var minP: Double
    public var repeatLastN: Int
    public var repeatPenalty: Double
    public var frequencyPenalty: Double
    public var presencePenalty: Double
    public var grammar: String
    public var ignoreEOS: Bool
    public var samplerKinds: [LocalLLMSamplerKind]
    public var chatTemplateKwargs: [String: JSONValue]
    public var advancedArguments: String

    public init(
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double = LocalModelRecord.defaultTemperature,
        topP: Double = LocalModelRecord.defaultTopP,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers,
        batchSize: Int = LocalModelRecord.defaultBatchSize,
        ubatchSize: Int = LocalModelRecord.defaultUbatchSize,
        kvOffload: Bool = LocalModelRecord.defaultKVOffload,
        flashAttention: LocalLLMFlashAttentionMode = LocalModelRecord.defaultFlashAttention,
        useModelCache: Bool = true,
        seed: UInt32 = LocalModelRecord.defaultSeed,
        topK: Int = LocalModelRecord.defaultTopK,
        minP: Double = LocalModelRecord.defaultMinP,
        repeatLastN: Int = LocalModelRecord.defaultRepeatLastN,
        repeatPenalty: Double = LocalModelRecord.defaultRepeatPenalty,
        frequencyPenalty: Double = LocalModelRecord.defaultFrequencyPenalty,
        presencePenalty: Double = LocalModelRecord.defaultPresencePenalty,
        grammar: String = LocalModelRecord.defaultGrammar,
        ignoreEOS: Bool = LocalModelRecord.defaultIgnoreEOS,
        samplerKinds: [LocalLLMSamplerKind] = LocalLLMSamplerKind.defaultChain,
        chatTemplateKwargs: [String: JSONValue] = [:],
        advancedArguments: String = LocalModelRecord.defaultAdvancedArguments
    ) {
        self.contextSize = contextSize.clamped(to: 1...1_048_576)
        self.maxOutputTokens = maxOutputTokens.clamped(to: 1...131_072)
        self.gpuLayers = gpuLayers
        self.batchSize = batchSize.clamped(to: 0...1_048_576)
        self.ubatchSize = ubatchSize.clamped(to: 0...1_048_576)
        self.kvOffload = kvOffload
        self.flashAttention = flashAttention
        self.useModelCache = useModelCache
        self.seed = seed
        self.temperature = temperature.clamped(to: 0...5)
        self.topK = topK.clamped(to: 0...1_000)
        self.topP = topP.clamped(to: 0...1)
        self.minP = minP.clamped(to: 0...1)
        self.repeatLastN = repeatLastN.clamped(to: -1...1_048_576)
        self.repeatPenalty = repeatPenalty.clamped(to: 0...4)
        self.frequencyPenalty = frequencyPenalty.clamped(to: -2...2)
        self.presencePenalty = presencePenalty.clamped(to: -2...2)
        self.grammar = grammar.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ignoreEOS = ignoreEOS
        let uniqueSamplerKinds = LocalLLMSamplerKind.unique(samplerKinds)
        self.samplerKinds = uniqueSamplerKinds.isEmpty ? LocalLLMSamplerKind.defaultChain : uniqueSamplerKinds
        self.chatTemplateKwargs = chatTemplateKwargs
        self.advancedArguments = advancedArguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LocalLLMEmbeddingOptions: Hashable, Sendable {
    public var contextSize: Int
    public var gpuLayers: Int

    public init(
        contextSize: Int,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers
    ) {
        self.contextSize = max(1, contextSize)
        self.gpuLayers = gpuLayers
    }
}

public struct LocalLLMToolCallParseResult: Hashable, Sendable {
    public var content: String
    public var reasoningContent: String?
    public var toolCalls: [InternalToolCall]

    public init(content: String, reasoningContent: String? = nil, toolCalls: [InternalToolCall]) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }
}

public enum LocalLLMEngineError: LocalizedError {
    case backendUnavailable
    case modelFileMissing(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return NSLocalizedString("本地推理后端尚未完成编译接入。", comment: "Local LLM backend unavailable")
        case .modelFileMissing(let fileName):
            return String(format: NSLocalizedString("本地模型文件不存在：%@", comment: "Local model file missing"), fileName)
        case .generationFailed(let message):
            return message
        }
    }
}

public final class LocalLLMEngine: @unchecked Sendable {
    public static let shared = LocalLLMEngine()

    public init() {}

    public func generate(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition] = [],
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        let cancellationState = LocalLLMCancellationState()
        let task = Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.generateChat(
                messages: messages,
                tools: tools,
                modelPath: modelURL.path,
                options: options,
                cancellationState: cancellationState
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellationState.cancel()
            task.cancel()
        }
    }

    public func generateParsed(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition] = [],
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) async throws -> LocalLLMToolCallParseResult {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        let cancellationState = LocalLLMCancellationState()
        let task = Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.generateChatResponse(
                messages: messages,
                tools: tools,
                modelPath: modelURL.path,
                options: options,
                cancellationState: cancellationState
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellationState.cancel()
            task.cancel()
        }
    }

    public func stream(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition] = [],
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) throws -> AsyncThrowingStream<String, Error> {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return try LocalLLMBridge.streamChat(
            messages: messages,
            tools: tools,
            modelPath: modelURL.path,
            options: options
        )
    }

    public func streamParsed(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition] = [],
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) throws -> AsyncThrowingStream<LocalLLMToolCallParseResult, Error> {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return try LocalLLMBridge.streamChatResponse(
            messages: messages,
            tools: tools,
            modelPath: modelURL.path,
            options: options
        )
    }

    public func parseToolCalls(
        from generatedText: String,
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelURL: URL
    ) async throws -> LocalLLMToolCallParseResult {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }
        return try await parseGeneratedOutput(
            from: generatedText,
            messages: messages,
            tools: tools,
            modelURL: modelURL,
            isPartial: false
        )
    }

    public func parseGeneratedOutput(
        from generatedText: String,
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition] = [],
        modelURL: URL,
        isPartial: Bool = false
    ) async throws -> LocalLLMToolCallParseResult {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }
        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.parseChatResponse(
                generatedText: generatedText,
                isPartial: isPartial,
                messages: messages,
                tools: tools,
                modelPath: modelURL.path
            )
        }.value
    }

    public func embed(
        texts: [String],
        modelURL: URL,
        options: LocalLLMEmbeddingOptions
    ) async throws -> [[Float]] {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.embed(
                texts: texts,
                modelPath: modelURL.path,
                contextSize: options.contextSize,
                gpuLayers: options.gpuLayers
            )
        }.value
    }

    public func clearModelCache() {
        LocalLLMBridge.clearModelCache()
    }
}

private enum LocalLLMBridge {
    private static let cancelledStatus: Int32 = -2

    static func clearModelCache() {
        etos_local_llm_clear_model_cache()
    }

    static func generateChat(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        options: LocalLLMGenerationOptions,
        cancellationState: LocalLLMCancellationState
    ) throws -> String {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let generationConfig = try LocalLLMGenerationConfig(options: options)
        let preparedConfig = try PreparedLocalLLMGenerationConfig(generationConfig)
        let payload = try LocalLLMChatTemplatePayload(messages: messages, tools: tools)
        let statePointer = Unmanaged.passUnretained(cancellationState).toOpaque()
        let status = modelPath.withCString { modelPathCString in
            payload.withUnsafeCStrings { messagesJSON, toolsJSON in
                preparedConfig.withUnsafePointer { configPointer in
                    etos_local_llm_generate_chat(
                        modelPathCString,
                        messagesJSON,
                        toolsJSON,
                        configPointer,
                        localLLMGenerationShouldCancel,
                        statePointer,
                        &outputPointer,
                        &errorPointer
                    )
                }
            }
        }
        defer {
            if let outputPointer {
                etos_local_llm_free(outputPointer)
            }
            if let errorPointer {
                etos_local_llm_free(errorPointer)
            }
        }

        guard status == 0, let outputPointer else {
            if status == cancelledStatus {
                throw CancellationError()
            }
            let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(message)
        }
        return String(cString: outputPointer)
    }

    static func generateChatResponse(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        options: LocalLLMGenerationOptions,
        cancellationState: LocalLLMCancellationState
    ) throws -> LocalLLMToolCallParseResult {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let generationConfig = try LocalLLMGenerationConfig(options: options)
        let preparedConfig = try PreparedLocalLLMGenerationConfig(generationConfig)
        let payload = try LocalLLMChatTemplatePayload(messages: messages, tools: tools)
        let statePointer = Unmanaged.passUnretained(cancellationState).toOpaque()
        let status = modelPath.withCString { modelPathCString in
            payload.withUnsafeCStrings { messagesJSON, toolsJSON in
                preparedConfig.withUnsafePointer { configPointer in
                    etos_local_llm_generate_chat_response(
                        modelPathCString,
                        messagesJSON,
                        toolsJSON,
                        configPointer,
                        localLLMGenerationShouldCancel,
                        statePointer,
                        &outputPointer,
                        &errorPointer
                    )
                }
            }
        }
        defer {
            if let outputPointer {
                etos_local_llm_free(outputPointer)
            }
            if let errorPointer {
                etos_local_llm_free(errorPointer)
            }
        }

        guard status == 0, let outputPointer else {
            if status == cancelledStatus {
                throw CancellationError()
            }
            let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(message)
        }
        return try parseChatResponseJSON(String(cString: outputPointer))
    }

    static func streamChat(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        options: LocalLLMGenerationOptions
    ) throws -> AsyncThrowingStream<String, Error> {
        let generationConfig = try LocalLLMGenerationConfig(options: options)
        return AsyncThrowingStream<String, Error> { continuation in
            guard !messages.isEmpty else {
                continuation.finish(throwing: LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages")))
                return
            }

            let state = LocalLLMStreamState(continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                state.cancel()
            }

            Task.detached(priority: .userInitiated) {
                let statePointer = Unmanaged.passRetained(state).toOpaque()
                defer {
                    Unmanaged<LocalLLMStreamState>.fromOpaque(statePointer).release()
                }

                var errorPointer: UnsafeMutablePointer<CChar>?
                do {
                    let preparedConfig = try PreparedLocalLLMGenerationConfig(generationConfig)
                    let payload = try LocalLLMChatTemplatePayload(messages: messages, tools: tools)
                    let status = modelPath.withCString { modelPathCString in
                        payload.withUnsafeCStrings { messagesJSON, toolsJSON in
                            preparedConfig.withUnsafePointer { configPointer in
                                etos_local_llm_generate_chat_stream(
                                    modelPathCString,
                                    messagesJSON,
                                    toolsJSON,
                                    configPointer,
                                    localLLMStreamCallback,
                                    localLLMStreamShouldCancel,
                                    statePointer,
                                    &errorPointer
                                )
                            }
                        }
                    }
                    defer {
                        if let errorPointer {
                            etos_local_llm_free(errorPointer)
                        }
                    }

                    guard status == 0 else {
                        if status == cancelledStatus {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
                        continuation.finish(throwing: LocalLLMEngineError.generationFailed(message))
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func streamChatResponse(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        options: LocalLLMGenerationOptions
    ) throws -> AsyncThrowingStream<LocalLLMToolCallParseResult, Error> {
        let generationConfig = try LocalLLMGenerationConfig(options: options)
        return AsyncThrowingStream<LocalLLMToolCallParseResult, Error> { continuation in
            guard !messages.isEmpty else {
                continuation.finish(throwing: LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages")))
                return
            }

            let state = LocalLLMParsedStreamState(continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                state.cancel()
            }

            Task.detached(priority: .userInitiated) {
                let statePointer = Unmanaged.passRetained(state).toOpaque()
                defer {
                    Unmanaged<LocalLLMParsedStreamState>.fromOpaque(statePointer).release()
                }

                var errorPointer: UnsafeMutablePointer<CChar>?
                do {
                    let preparedConfig = try PreparedLocalLLMGenerationConfig(generationConfig)
                    let payload = try LocalLLMChatTemplatePayload(messages: messages, tools: tools)
                    let status = modelPath.withCString { modelPathCString in
                        payload.withUnsafeCStrings { messagesJSON, toolsJSON in
                            preparedConfig.withUnsafePointer { configPointer in
                                etos_local_llm_generate_chat_response_stream(
                                    modelPathCString,
                                    messagesJSON,
                                    toolsJSON,
                                    configPointer,
                                    localLLMParsedStreamCallback,
                                    localLLMParsedStreamShouldCancel,
                                    statePointer,
                                    &errorPointer
                                )
                            }
                        }
                    }
                    defer {
                        if let errorPointer {
                            etos_local_llm_free(errorPointer)
                        }
                    }

                    guard status == 0 else {
                        if status == cancelledStatus {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
                        continuation.finish(throwing: LocalLLMEngineError.generationFailed(message))
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func parseChatResponse(
        generatedText: String,
        isPartial: Bool,
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String
    ) throws -> LocalLLMToolCallParseResult {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let payload = try LocalLLMChatTemplatePayload(messages: messages, tools: tools)
        let status = modelPath.withCString { modelPathCString in
            generatedText.withCString { generatedTextCString in
                payload.withUnsafeCStrings { messagesJSON, toolsJSON in
                    etos_local_llm_parse_chat_response(
                        modelPathCString,
                        messagesJSON,
                        toolsJSON,
                        generatedTextCString,
                        isPartial ? 1 : 0,
                        &outputPointer,
                        &errorPointer
                    )
                }
            }
        }
        defer {
            if let outputPointer {
                etos_local_llm_free(outputPointer)
            }
            if let errorPointer {
                etos_local_llm_free(errorPointer)
            }
        }

        guard status == 0, let outputPointer else {
            let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(message)
        }
        return try parseChatResponseJSON(String(cString: outputPointer))
    }

    static func embed(
        texts: [String],
        modelPath: String,
        contextSize: Int,
        gpuLayers: Int
    ) throws -> [[Float]] {
        let normalizedTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !normalizedTexts.isEmpty, normalizedTexts.allSatisfy({ !$0.isEmpty }) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地嵌入文本为空。", comment: "Local LLM empty embedding texts"))
        }

        let textPointers = normalizedTexts.compactMap { strdup($0) }
        defer {
            textPointers.forEach { free($0) }
        }
        guard textPointers.count == normalizedTexts.count else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地嵌入文本内存分配失败。", comment: "Local LLM embedding text allocation failed"))
        }
        let bridgedTextPointers: [UnsafePointer<CChar>?] = textPointers.map { UnsafePointer($0) }

        var outputPointer: UnsafeMutablePointer<Float>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        var embeddingCount: Int32 = 0
        var embeddingDimension: Int32 = 0
        let status = modelPath.withCString { modelPathCString in
            bridgedTextPointers.withUnsafeBufferPointer { textsPointer in
                etos_local_llm_embed(
                    modelPathCString,
                    textsPointer.baseAddress,
                    Int32(textsPointer.count),
                    Int32(max(1, contextSize)),
                    Int32(gpuLayers),
                    &outputPointer,
                    &embeddingCount,
                    &embeddingDimension,
                    &errorPointer
                )
            }
        }
        defer {
            if let outputPointer {
                etos_local_llm_free_float(outputPointer)
            }
            if let errorPointer {
                etos_local_llm_free(errorPointer)
            }
        }

        guard status == 0,
              let outputPointer,
              embeddingCount == normalizedTexts.count,
              embeddingDimension > 0 else {
            let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(message)
        }

        let dimension = Int(embeddingDimension)
        let buffer = UnsafeBufferPointer(start: outputPointer, count: Int(embeddingCount) * dimension)
        return (0..<Int(embeddingCount)).map { index in
            let start = index * dimension
            return Array(buffer[start..<(start + dimension)])
        }
    }
}

private struct LocalLLMParsedChatMessage: Decodable {
    var content: String?
    var reasoningContent: String?
    var toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }

    struct ToolCall: Decodable {
        var id: String?
        var function: FunctionCall?
    }

    struct FunctionCall: Decodable {
        var name: String?
        var arguments: String?
    }
}

private func parseChatResponseJSON(_ json: String) throws -> LocalLLMToolCallParseResult {
    guard let data = json.data(using: .utf8) else {
        throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地模型结构化输出不是有效 UTF-8。", comment: "Local LLM structured output invalid UTF-8"))
    }
    let message = try JSONDecoder().decode(LocalLLMParsedChatMessage.self, from: data)
    let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
    let toolCalls = (message.toolCalls ?? []).enumerated().compactMap { index, toolCall -> InternalToolCall? in
        let name = toolCall.function?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let id = toolCall.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return InternalToolCall(
            id: id?.isEmpty == false ? id! : "local_tool_\(index + 1)",
            toolName: name,
            arguments: toolCall.function?.arguments ?? "{}"
        )
    }
    return LocalLLMToolCallParseResult(
        content: message.content ?? "",
        reasoningContent: reasoning?.isEmpty == false ? reasoning : nil,
        toolCalls: toolCalls
    )
}

private struct ETOSLocalLLMGenerationConfig {
    var contextSize: Int32
    var maxOutputTokens: Int32
    var gpuLayers: Int32
    var batchSize: Int32
    var ubatchSize: Int32
    var kvOffload: Int32
    var flashAttention: Int32
    var useModelCache: Int32
    var seed: UInt32
    var minKeep: Int32
    var topK: Int32
    var topP: Float
    var minP: Float
    var typicalP: Float
    var temperature: Float
    var dynatempRange: Float
    var dynatempExponent: Float
    var xtcProbability: Float
    var xtcThreshold: Float
    var topNSigma: Float
    var repeatLastN: Int32
    var repeatPenalty: Float
    var frequencyPenalty: Float
    var presencePenalty: Float
    var dryMultiplier: Float
    var dryBase: Float
    var dryAllowedLength: Int32
    var dryPenaltyLastN: Int32
    var drySequenceBreakers: UnsafePointer<UnsafePointer<CChar>?>?
    var drySequenceBreakerCount: Int32
    var samplerKinds: UnsafePointer<Int32>?
    var samplerKindCount: Int32
    var mirostat: Int32
    var mirostatTau: Float
    var mirostatEta: Float
    var adaptiveTarget: Float
    var adaptiveDecay: Float
    var grammar: UnsafePointer<CChar>?
    var ignoreEOS: Int32
    var chatTemplateKwargKeys: UnsafePointer<UnsafePointer<CChar>?>?
    var chatTemplateKwargValues: UnsafePointer<UnsafePointer<CChar>?>?
    var chatTemplateKwargCount: Int32
}

private final class PreparedLocalLLMGenerationConfig {
    private let drySequenceBreakerPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedDrySequenceBreakers: [UnsafePointer<CChar>?]
    private let bridgedSamplerKinds: [Int32]
    private let grammarPointer: UnsafeMutablePointer<CChar>
    private let chatTemplateKwargKeyPointers: [UnsafeMutablePointer<CChar>]
    private let chatTemplateKwargValuePointers: [UnsafeMutablePointer<CChar>]
    private let bridgedChatTemplateKwargKeys: [UnsafePointer<CChar>?]
    private let bridgedChatTemplateKwargValues: [UnsafePointer<CChar>?]
    private var bridgedConfig: ETOSLocalLLMGenerationConfig

    init(_ config: LocalLLMGenerationConfig) throws {
        let drySequenceBreakerPointers = try config.drySequenceBreakers.map(Self.duplicate)
        let grammarPointer = try Self.duplicate(config.grammar)
        let chatTemplateKwargs = try Self.encodedChatTemplateKwargs(config.chatTemplateKwargs)
        let chatTemplateKwargKeyPointers = try chatTemplateKwargs.map { try Self.duplicate($0.key) }
        let chatTemplateKwargValuePointers = try chatTemplateKwargs.map { try Self.duplicate($0.value) }

        self.drySequenceBreakerPointers = drySequenceBreakerPointers
        self.bridgedDrySequenceBreakers = drySequenceBreakerPointers.map { UnsafePointer($0) }
        self.bridgedSamplerKinds = config.samplerKinds.map(\.rawValue)
        self.grammarPointer = grammarPointer
        self.chatTemplateKwargKeyPointers = chatTemplateKwargKeyPointers
        self.chatTemplateKwargValuePointers = chatTemplateKwargValuePointers
        self.bridgedChatTemplateKwargKeys = chatTemplateKwargKeyPointers.map { UnsafePointer($0) }
        self.bridgedChatTemplateKwargValues = chatTemplateKwargValuePointers.map { UnsafePointer($0) }
        self.bridgedConfig = ETOSLocalLLMGenerationConfig(
            contextSize: config.contextSize,
            maxOutputTokens: config.maxOutputTokens,
            gpuLayers: config.gpuLayers,
            batchSize: config.batchSize,
            ubatchSize: config.ubatchSize,
            kvOffload: config.kvOffload ? 1 : 0,
            flashAttention: config.flashAttention.rawValue,
            useModelCache: config.useModelCache ? 1 : 0,
            seed: config.seed,
            minKeep: config.minKeep,
            topK: config.topK,
            topP: config.topP,
            minP: config.minP,
            typicalP: config.typicalP,
            temperature: config.temperature,
            dynatempRange: config.dynatempRange,
            dynatempExponent: config.dynatempExponent,
            xtcProbability: config.xtcProbability,
            xtcThreshold: config.xtcThreshold,
            topNSigma: config.topNSigma,
            repeatLastN: config.repeatLastN,
            repeatPenalty: config.repeatPenalty,
            frequencyPenalty: config.frequencyPenalty,
            presencePenalty: config.presencePenalty,
            dryMultiplier: config.dryMultiplier,
            dryBase: config.dryBase,
            dryAllowedLength: config.dryAllowedLength,
            dryPenaltyLastN: config.dryPenaltyLastN,
            drySequenceBreakers: nil,
            drySequenceBreakerCount: Int32(drySequenceBreakerPointers.count),
            samplerKinds: nil,
            samplerKindCount: Int32(config.samplerKinds.count),
            mirostat: config.mirostat,
            mirostatTau: config.mirostatTau,
            mirostatEta: config.mirostatEta,
            adaptiveTarget: config.adaptiveTarget,
            adaptiveDecay: config.adaptiveDecay,
            grammar: UnsafePointer(grammarPointer),
            ignoreEOS: config.ignoreEOS ? 1 : 0,
            chatTemplateKwargKeys: nil,
            chatTemplateKwargValues: nil,
            chatTemplateKwargCount: Int32(chatTemplateKwargs.count)
        )
    }

    deinit {
        drySequenceBreakerPointers.forEach { free($0) }
        free(grammarPointer)
        chatTemplateKwargKeyPointers.forEach { free($0) }
        chatTemplateKwargValuePointers.forEach { free($0) }
    }

    func withUnsafePointer<Result>(
        _ body: (UnsafePointer<ETOSLocalLLMGenerationConfig>) throws -> Result
    ) rethrows -> Result {
        try bridgedDrySequenceBreakers.withUnsafeBufferPointer { breakersPointer in
            try bridgedSamplerKinds.withUnsafeBufferPointer { samplerPointer in
                try bridgedChatTemplateKwargKeys.withUnsafeBufferPointer { kwargKeysPointer in
                    try bridgedChatTemplateKwargValues.withUnsafeBufferPointer { kwargValuesPointer in
                        bridgedConfig.drySequenceBreakers = breakersPointer.baseAddress
                        bridgedConfig.drySequenceBreakerCount = Int32(breakersPointer.count)
                        bridgedConfig.samplerKinds = samplerPointer.baseAddress
                        bridgedConfig.samplerKindCount = Int32(samplerPointer.count)
                        bridgedConfig.chatTemplateKwargKeys = kwargKeysPointer.baseAddress
                        bridgedConfig.chatTemplateKwargValues = kwargValuesPointer.baseAddress
                        bridgedConfig.chatTemplateKwargCount = Int32(kwargKeysPointer.count)
                        return try Swift.withUnsafePointer(to: &bridgedConfig, body)
                    }
                }
            }
        }
    }

    private static func encodedChatTemplateKwargs(_ kwargs: [String: JSONValue]) throws -> [(key: String, value: String)] {
        try kwargs
            .map { key, value -> (key: String, value: String) in
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty else {
                    throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话模板参数 key 不能为空。", comment: "Local LLM empty chat template kwarg key"))
                }
                let encodedValue = try encodeJSONValue(value)
                return (trimmedKey, encodedValue)
            }
            .sorted(by: { $0.key < $1.key })
    }

    private static func encodeJSONValue(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话模板参数不是有效 UTF-8。", comment: "Local LLM chat template kwarg invalid UTF-8"))
        }
        return string
    }

    private static func duplicate(_ value: String) throws -> UnsafeMutablePointer<CChar> {
        guard let pointer = strdup(value) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地推理配置内存分配失败。", comment: "Local LLM config allocation failed"))
        }
        return pointer
    }
}

private final class LocalLLMCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

private final class LocalLLMStreamState: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let cancellationState = LocalLLMCancellationState()

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func cancel() {
        cancellationState.cancel()
    }

    func isCancelled() -> Bool {
        cancellationState.isCancelled()
    }

    func yield(_ text: String) -> Bool {
        guard !isCancelled() else { return false }

        let result = continuation.yield(text)
        switch result {
        case .terminated:
            cancel()
            return false
        case .dropped, .enqueued:
            return true
        @unknown default:
            return true
        }
    }
}

private final class LocalLLMParsedStreamState: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<LocalLLMToolCallParseResult, Error>.Continuation
    private let cancellationState = LocalLLMCancellationState()

    init(continuation: AsyncThrowingStream<LocalLLMToolCallParseResult, Error>.Continuation) {
        self.continuation = continuation
    }

    func cancel() {
        cancellationState.cancel()
    }

    func isCancelled() -> Bool {
        cancellationState.isCancelled()
    }

    func yield(json: String) -> Bool {
        guard !isCancelled() else { return false }

        do {
            let result = continuation.yield(try parseChatResponseJSON(json))
            switch result {
            case .terminated:
                cancel()
                return false
            case .dropped, .enqueued:
                return true
            @unknown default:
                return true
            }
        } catch {
            continuation.finish(throwing: error)
            cancel()
            return false
        }
    }
}

private let localLLMStreamCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { text, userData in
    guard let text, let userData else { return 0 }
    let state = Unmanaged<LocalLLMStreamState>.fromOpaque(userData).takeUnretainedValue()
    return state.yield(String(cString: text)) ? 1 : 0
}

private let localLLMParsedStreamCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { messageJSON, userData in
    guard let messageJSON, let userData else { return 0 }
    let state = Unmanaged<LocalLLMParsedStreamState>.fromOpaque(userData).takeUnretainedValue()
    return state.yield(json: String(cString: messageJSON)) ? 1 : 0
}

private let localLLMStreamShouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    let state = Unmanaged<LocalLLMStreamState>.fromOpaque(userData).takeUnretainedValue()
    return state.isCancelled() ? 1 : 0
}

private let localLLMParsedStreamShouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    let state = Unmanaged<LocalLLMParsedStreamState>.fromOpaque(userData).takeUnretainedValue()
    return state.isCancelled() ? 1 : 0
}

private let localLLMGenerationShouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    let state = Unmanaged<LocalLLMCancellationState>.fromOpaque(userData).takeUnretainedValue()
    return state.isCancelled() ? 1 : 0
}

@_silgen_name("etos_local_llm_generate")
private func etos_local_llm_generate(
    _ modelPath: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat")
private func etos_local_llm_generate_chat(
    _ modelPath: UnsafePointer<CChar>,
    _ messagesJSON: UnsafePointer<CChar>,
    _ toolsJSON: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat_response")
private func etos_local_llm_generate_chat_response(
    _ modelPath: UnsafePointer<CChar>,
    _ messagesJSON: UnsafePointer<CChar>,
    _ toolsJSON: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ outputJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_stream")
private func etos_local_llm_generate_stream(
    _ modelPath: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat_stream")
private func etos_local_llm_generate_chat_stream(
    _ modelPath: UnsafePointer<CChar>,
    _ messagesJSON: UnsafePointer<CChar>,
    _ toolsJSON: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat_response_stream")
private func etos_local_llm_generate_chat_response_stream(
    _ modelPath: UnsafePointer<CChar>,
    _ messagesJSON: UnsafePointer<CChar>,
    _ toolsJSON: UnsafePointer<CChar>,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ snapshotCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_parse_chat_response")
private func etos_local_llm_parse_chat_response(
    _ modelPath: UnsafePointer<CChar>,
    _ messagesJSON: UnsafePointer<CChar>,
    _ toolsJSON: UnsafePointer<CChar>,
    _ generatedText: UnsafePointer<CChar>,
    _ isPartial: Int32,
    _ outputJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_embed")
private func etos_local_llm_embed(
    _ modelPath: UnsafePointer<CChar>,
    _ texts: UnsafePointer<UnsafePointer<CChar>?>?,
    _ textCount: Int32,
    _ contextSize: Int32,
    _ gpuLayers: Int32,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
    _ embeddingCount: UnsafeMutablePointer<Int32>,
    _ embeddingDimension: UnsafeMutablePointer<Int32>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_free")
private func etos_local_llm_free(_ pointer: UnsafeMutablePointer<CChar>)

@_silgen_name("etos_local_llm_free_float")
private func etos_local_llm_free_float(_ pointer: UnsafeMutablePointer<Float>)

@_silgen_name("etos_local_llm_clear_model_cache")
private func etos_local_llm_clear_model_cache()

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
