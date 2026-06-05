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
    public var advancedArguments: String

    public init(
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double = LocalModelRecord.defaultTemperature,
        topP: Double = LocalModelRecord.defaultTopP,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers,
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
        advancedArguments: String = LocalModelRecord.defaultAdvancedArguments
    ) {
        self.contextSize = contextSize.clamped(to: 1...1_048_576)
        self.maxOutputTokens = maxOutputTokens.clamped(to: 1...131_072)
        self.gpuLayers = gpuLayers
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
    public var toolCalls: [InternalToolCall]

    public init(content: String, toolCalls: [InternalToolCall]) {
        self.content = content
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
        return LocalLLMChatMessageBuilder.parseToolCalls(from: generatedText, tools: tools)
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
}

private enum LocalLLMBridge {
    private static let cancelledStatus: Int32 = -2

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
        let preparedMessages = try PreparedLocalLLMChatMessages(messages)
        let preparedTools = try PreparedLocalLLMTools(tools)
        let statePointer = Unmanaged.passUnretained(cancellationState).toOpaque()
        let status = modelPath.withCString { modelPathCString in
            preparedMessages.withUnsafeBufferPointer { messagesPointer in
                preparedTools.withUnsafeBufferPointer { toolsPointer in
                    preparedConfig.withUnsafePointer { configPointer in
                        etos_local_llm_generate_chat(
                            modelPathCString,
                            messagesPointer.baseAddress,
                            Int32(messagesPointer.count),
                            toolsPointer.baseAddress,
                            Int32(toolsPointer.count),
                            configPointer,
                            localLLMGenerationShouldCancel,
                            statePointer,
                            &outputPointer,
                            &errorPointer
                        )
                    }
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
                    let preparedMessages = try PreparedLocalLLMChatMessages(messages)
                    let preparedTools = try PreparedLocalLLMTools(tools)
                    let status = modelPath.withCString { modelPathCString in
                        preparedMessages.withUnsafeBufferPointer { messagesPointer in
                            preparedTools.withUnsafeBufferPointer { toolsPointer in
                                preparedConfig.withUnsafePointer { configPointer in
                                    etos_local_llm_generate_chat_stream(
                                        modelPathCString,
                                        messagesPointer.baseAddress,
                                        Int32(messagesPointer.count),
                                        toolsPointer.baseAddress,
                                        Int32(toolsPointer.count),
                                        configPointer,
                                        localLLMStreamCallback,
                                        localLLMStreamShouldCancel,
                                        statePointer,
                                        &errorPointer
                                    )
                                }
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

private struct ETOSLocalLLMChatMessage {
    var role: UnsafePointer<CChar>?
    var content: UnsafePointer<CChar>?
    var name: UnsafePointer<CChar>?
    var toolCallID: UnsafePointer<CChar>?
    var toolCallsJSON: UnsafePointer<CChar>?
}

private struct ETOSLocalLLMTool {
    var name: UnsafePointer<CChar>?
    var description: UnsafePointer<CChar>?
    var parametersJSON: UnsafePointer<CChar>?
}

private final class PreparedLocalLLMChatMessages {
    private let stringPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedMessages: [ETOSLocalLLMChatMessage]

    init(_ messages: [LocalLLMChatMessage]) throws {
        var stringPointers: [UnsafeMutablePointer<CChar>] = []
        var bridgedMessages: [ETOSLocalLLMChatMessage] = []

        do {
            for message in messages {
                let role = try Self.duplicate(message.role)
                let content = try Self.duplicate(message.content)
                stringPointers.append(role)
                stringPointers.append(content)

                let name = try Self.duplicateOptional(message.name, keepingIn: &stringPointers)
                let toolCallID = try Self.duplicateOptional(message.toolCallID, keepingIn: &stringPointers)
                let toolCallsJSON = try Self.duplicateOptional(message.toolCallsJSON, keepingIn: &stringPointers)

                bridgedMessages.append(ETOSLocalLLMChatMessage(
                    role: UnsafePointer(role),
                    content: UnsafePointer(content),
                    name: name.map { UnsafePointer($0) },
                    toolCallID: toolCallID.map { UnsafePointer($0) },
                    toolCallsJSON: toolCallsJSON.map { UnsafePointer($0) }
                ))
            }
        } catch {
            stringPointers.forEach { free($0) }
            throw error
        }

        self.stringPointers = stringPointers
        self.bridgedMessages = bridgedMessages
    }

    deinit {
        stringPointers.forEach { free($0) }
    }

    func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<ETOSLocalLLMChatMessage>) throws -> Result
    ) rethrows -> Result {
        try bridgedMessages.withUnsafeBufferPointer(body)
    }

    private static func duplicateOptional(
        _ value: String?,
        keepingIn pointers: inout [UnsafeMutablePointer<CChar>]
    ) throws -> UnsafeMutablePointer<CChar>? {
        guard let value else { return nil }
        let pointer = try duplicate(value)
        pointers.append(pointer)
        return pointer
    }

    private static func duplicate(_ value: String) throws -> UnsafeMutablePointer<CChar> {
        guard let pointer = strdup(value) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息内存分配失败。", comment: "Local LLM chat message allocation failed"))
        }
        return pointer
    }
}

private final class PreparedLocalLLMTools {
    private let stringPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedTools: [ETOSLocalLLMTool]

    init(_ tools: [LocalLLMToolDefinition]) throws {
        var stringPointers: [UnsafeMutablePointer<CChar>] = []
        var bridgedTools: [ETOSLocalLLMTool] = []

        do {
            for tool in tools {
                let name = try Self.duplicate(tool.name)
                let description = try Self.duplicate(tool.description)
                let parametersJSON = try Self.duplicate(tool.parametersJSON)
                stringPointers.append(contentsOf: [name, description, parametersJSON])
                bridgedTools.append(ETOSLocalLLMTool(
                    name: UnsafePointer(name),
                    description: UnsafePointer(description),
                    parametersJSON: UnsafePointer(parametersJSON)
                ))
            }
        } catch {
            stringPointers.forEach { free($0) }
            throw error
        }

        self.stringPointers = stringPointers
        self.bridgedTools = bridgedTools
    }

    deinit {
        stringPointers.forEach { free($0) }
    }

    func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<ETOSLocalLLMTool>) throws -> Result
    ) rethrows -> Result {
        try bridgedTools.withUnsafeBufferPointer(body)
    }

    private static func duplicate(_ value: String) throws -> UnsafeMutablePointer<CChar> {
        guard let pointer = strdup(value) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地工具定义内存分配失败。", comment: "Local LLM tool allocation failed"))
        }
        return pointer
    }
}

private struct ETOSLocalLLMGenerationConfig {
    var contextSize: Int32
    var maxOutputTokens: Int32
    var gpuLayers: Int32
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
}

private final class PreparedLocalLLMGenerationConfig {
    private let drySequenceBreakerPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedDrySequenceBreakers: [UnsafePointer<CChar>?]
    private let bridgedSamplerKinds: [Int32]
    private let grammarPointer: UnsafeMutablePointer<CChar>
    private var bridgedConfig: ETOSLocalLLMGenerationConfig

    init(_ config: LocalLLMGenerationConfig) throws {
        let drySequenceBreakerPointers = try config.drySequenceBreakers.map(Self.duplicate)
        let grammarPointer = try Self.duplicate(config.grammar)

        self.drySequenceBreakerPointers = drySequenceBreakerPointers
        self.bridgedDrySequenceBreakers = drySequenceBreakerPointers.map { UnsafePointer($0) }
        self.bridgedSamplerKinds = config.samplerKinds.map(\.rawValue)
        self.grammarPointer = grammarPointer
        self.bridgedConfig = ETOSLocalLLMGenerationConfig(
            contextSize: config.contextSize,
            maxOutputTokens: config.maxOutputTokens,
            gpuLayers: config.gpuLayers,
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
            ignoreEOS: config.ignoreEOS ? 1 : 0
        )
    }

    deinit {
        drySequenceBreakerPointers.forEach { free($0) }
        free(grammarPointer)
    }

    func withUnsafePointer<Result>(
        _ body: (UnsafePointer<ETOSLocalLLMGenerationConfig>) throws -> Result
    ) rethrows -> Result {
        try bridgedDrySequenceBreakers.withUnsafeBufferPointer { breakersPointer in
            try bridgedSamplerKinds.withUnsafeBufferPointer { samplerPointer in
                bridgedConfig.drySequenceBreakers = breakersPointer.baseAddress
                bridgedConfig.drySequenceBreakerCount = Int32(breakersPointer.count)
                bridgedConfig.samplerKinds = samplerPointer.baseAddress
                bridgedConfig.samplerKindCount = Int32(samplerPointer.count)
                return try Swift.withUnsafePointer(to: &bridgedConfig, body)
            }
        }
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

private let localLLMStreamCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { text, userData in
    guard let text, let userData else { return 0 }
    let state = Unmanaged<LocalLLMStreamState>.fromOpaque(userData).takeUnretainedValue()
    return state.yield(String(cString: text)) ? 1 : 0
}

private let localLLMStreamShouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userData in
    guard let userData else { return 0 }
    let state = Unmanaged<LocalLLMStreamState>.fromOpaque(userData).takeUnretainedValue()
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
    _ messages: UnsafePointer<ETOSLocalLLMChatMessage>?,
    _ messageCount: Int32,
    _ tools: UnsafePointer<ETOSLocalLLMTool>?,
    _ toolCount: Int32,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
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
    _ messages: UnsafePointer<ETOSLocalLLMChatMessage>?,
    _ messageCount: Int32,
    _ tools: UnsafePointer<ETOSLocalLLMTool>?,
    _ toolCount: Int32,
    _ config: UnsafePointer<ETOSLocalLLMGenerationConfig>,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
