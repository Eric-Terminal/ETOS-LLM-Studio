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
    public var temperature: Double?
    public var topP: Double?
    public var gpuLayers: Int

    public init(
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers
    ) {
        self.contextSize = max(1, contextSize)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = temperature
        self.topP = topP
        self.gpuLayers = gpuLayers
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

        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.generateChat(
                messages: messages,
                tools: tools,
                modelPath: modelURL.path,
                contextSize: options.contextSize,
                maxOutputTokens: options.maxOutputTokens,
                temperature: options.temperature,
                topP: options.topP,
                gpuLayers: options.gpuLayers
            )
        }.value
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

        return LocalLLMBridge.streamChat(
            messages: messages,
            tools: tools,
            modelPath: modelURL.path,
            contextSize: options.contextSize,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
            topP: options.topP,
            gpuLayers: options.gpuLayers
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

        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.parseToolCalls(
                from: generatedText,
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
}

private enum LocalLLMBridge {
    static func generateChat(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double?,
        gpuLayers: Int
    ) throws -> String {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let preparedMessages = PreparedLocalLLMChatMessages(messages)
        let preparedTools = PreparedLocalLLMTools(tools)
        let status = modelPath.withCString { modelPathCString in
            preparedMessages.withUnsafeBufferPointer { messagesPointer in
                preparedTools.withUnsafeBufferPointer { toolsPointer in
                    etos_local_llm_generate_chat(
                        modelPathCString,
                        messagesPointer.baseAddress,
                        Int32(messagesPointer.count),
                        toolsPointer.baseAddress,
                        Int32(toolsPointer.count),
                        Int32(max(1, contextSize)),
                        Int32(max(1, maxOutputTokens)),
                        Float(temperature ?? 0.8),
                        Float(topP ?? 0.95),
                        Int32(gpuLayers),
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
        return String(cString: outputPointer)
    }

    static func streamChat(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double?,
        gpuLayers: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
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
                let preparedMessages = PreparedLocalLLMChatMessages(messages)
                let preparedTools = PreparedLocalLLMTools(tools)
                let status = modelPath.withCString { modelPathCString in
                    preparedMessages.withUnsafeBufferPointer { messagesPointer in
                        preparedTools.withUnsafeBufferPointer { toolsPointer in
                            etos_local_llm_generate_chat_stream(
                                modelPathCString,
                                messagesPointer.baseAddress,
                                Int32(messagesPointer.count),
                                toolsPointer.baseAddress,
                                Int32(toolsPointer.count),
                                Int32(max(1, contextSize)),
                                Int32(max(1, maxOutputTokens)),
                                Float(temperature ?? 0.8),
                                Float(topP ?? 0.95),
                                Int32(gpuLayers),
                                localLLMStreamCallback,
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
                    let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
                    continuation.finish(throwing: LocalLLMEngineError.generationFailed(message))
                    return
                }
                continuation.finish()
            }
        }
    }

    static func parseToolCalls(
        from generatedText: String,
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition],
        modelPath: String
    ) throws -> LocalLLMToolCallParseResult {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var contentPointer: UnsafeMutablePointer<CChar>?
        var callsPointer: UnsafeMutablePointer<ETOSLocalLLMToolCall>?
        var callCount: Int32 = 0
        var errorPointer: UnsafeMutablePointer<CChar>?
        let preparedMessages = PreparedLocalLLMChatMessages(messages)
        let preparedTools = PreparedLocalLLMTools(tools)
        let status = modelPath.withCString { modelPathCString in
            generatedText.withCString { generatedTextCString in
                preparedMessages.withUnsafeBufferPointer { messagesPointer in
                    preparedTools.withUnsafeBufferPointer { toolsPointer in
                        etos_local_llm_parse_tool_calls(
                            modelPathCString,
                            messagesPointer.baseAddress,
                            Int32(messagesPointer.count),
                            toolsPointer.baseAddress,
                            Int32(toolsPointer.count),
                            generatedTextCString,
                            &contentPointer,
                            &callsPointer,
                            &callCount,
                            &errorPointer
                        )
                    }
                }
            }
        }
        defer {
            if let contentPointer {
                etos_local_llm_free(contentPointer)
            }
            if let callsPointer {
                etos_local_llm_free_tool_calls(callsPointer, callCount)
            }
            if let errorPointer {
                etos_local_llm_free(errorPointer)
            }
        }

        guard status == 0 else {
            let message = errorPointer.map { String(cString: $0) } ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(message)
        }

        let content = contentPointer.map { String(cString: $0) } ?? generatedText
        let callsBuffer = UnsafeBufferPointer(start: callsPointer, count: Int(callCount))
        let calls = callsBuffer.enumerated().compactMap { index, call -> InternalToolCall? in
            guard let namePointer = call.name else { return nil }
            let name = String(cString: namePointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let id = call.id.map { String(cString: $0) }.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? "local_tool_\(index + 1)"
            let arguments = call.arguments.map { String(cString: $0) } ?? "{}"
            return InternalToolCall(id: id, toolName: name, arguments: arguments)
        }
        return LocalLLMToolCallParseResult(content: content, toolCalls: calls)
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

private struct ETOSLocalLLMToolCall {
    var id: UnsafeMutablePointer<CChar>?
    var name: UnsafeMutablePointer<CChar>?
    var arguments: UnsafeMutablePointer<CChar>?
}

private final class PreparedLocalLLMChatMessages {
    private let rolePointers: [UnsafeMutablePointer<CChar>]
    private let contentPointers: [UnsafeMutablePointer<CChar>]
    private let namePointers: [UnsafeMutablePointer<CChar>]
    private let toolCallIDPointers: [UnsafeMutablePointer<CChar>]
    private let toolCallsJSONPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedMessages: [ETOSLocalLLMChatMessage]

    init(_ messages: [LocalLLMChatMessage]) {
        var rolePointers: [UnsafeMutablePointer<CChar>] = []
        var contentPointers: [UnsafeMutablePointer<CChar>] = []
        var namePointers: [UnsafeMutablePointer<CChar>] = []
        var toolCallIDPointers: [UnsafeMutablePointer<CChar>] = []
        var toolCallsJSONPointers: [UnsafeMutablePointer<CChar>] = []
        var bridgedMessages: [ETOSLocalLLMChatMessage] = []

        for message in messages {
            guard let role = strdup(message.role) else { continue }
            guard let content = strdup(message.content) else {
                free(role)
                continue
            }
            let name = message.name.flatMap { strdup($0) }
            let toolCallID = message.toolCallID.flatMap { strdup($0) }
            let toolCallsJSON = message.toolCallsJSON.flatMap { strdup($0) }
            rolePointers.append(role)
            contentPointers.append(content)
            if let name {
                namePointers.append(name)
            }
            if let toolCallID {
                toolCallIDPointers.append(toolCallID)
            }
            if let toolCallsJSON {
                toolCallsJSONPointers.append(toolCallsJSON)
            }
            bridgedMessages.append(ETOSLocalLLMChatMessage(
                role: UnsafePointer(role),
                content: UnsafePointer(content),
                name: name.map { UnsafePointer($0) },
                toolCallID: toolCallID.map { UnsafePointer($0) },
                toolCallsJSON: toolCallsJSON.map { UnsafePointer($0) }
            ))
        }

        self.rolePointers = rolePointers
        self.contentPointers = contentPointers
        self.namePointers = namePointers
        self.toolCallIDPointers = toolCallIDPointers
        self.toolCallsJSONPointers = toolCallsJSONPointers
        self.bridgedMessages = bridgedMessages
    }

    deinit {
        rolePointers.forEach { free($0) }
        contentPointers.forEach { free($0) }
        namePointers.forEach { free($0) }
        toolCallIDPointers.forEach { free($0) }
        toolCallsJSONPointers.forEach { free($0) }
    }

    func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<ETOSLocalLLMChatMessage>) throws -> Result
    ) rethrows -> Result {
        try bridgedMessages.withUnsafeBufferPointer(body)
    }
}

private final class PreparedLocalLLMTools {
    private let namePointers: [UnsafeMutablePointer<CChar>]
    private let descriptionPointers: [UnsafeMutablePointer<CChar>]
    private let parametersJSONPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedTools: [ETOSLocalLLMTool]

    init(_ tools: [LocalLLMToolDefinition]) {
        var namePointers: [UnsafeMutablePointer<CChar>] = []
        var descriptionPointers: [UnsafeMutablePointer<CChar>] = []
        var parametersJSONPointers: [UnsafeMutablePointer<CChar>] = []
        var bridgedTools: [ETOSLocalLLMTool] = []

        for tool in tools {
            guard let name = strdup(tool.name) else { continue }
            guard let description = strdup(tool.description) else {
                free(name)
                continue
            }
            guard let parametersJSON = strdup(tool.parametersJSON) else {
                free(name)
                free(description)
                continue
            }
            namePointers.append(name)
            descriptionPointers.append(description)
            parametersJSONPointers.append(parametersJSON)
            bridgedTools.append(ETOSLocalLLMTool(
                name: UnsafePointer(name),
                description: UnsafePointer(description),
                parametersJSON: UnsafePointer(parametersJSON)
            ))
        }

        self.namePointers = namePointers
        self.descriptionPointers = descriptionPointers
        self.parametersJSONPointers = parametersJSONPointers
        self.bridgedTools = bridgedTools
    }

    deinit {
        namePointers.forEach { free($0) }
        descriptionPointers.forEach { free($0) }
        parametersJSONPointers.forEach { free($0) }
    }

    func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<ETOSLocalLLMTool>) throws -> Result
    ) rethrows -> Result {
        try bridgedTools.withUnsafeBufferPointer(body)
    }
}

private final class LocalLLMStreamState: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var cancelled = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func yield(_ text: String) -> Bool {
        lock.lock()
        let shouldStop = cancelled
        lock.unlock()
        guard !shouldStop else { return false }

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

@_silgen_name("etos_local_llm_generate")
private func etos_local_llm_generate(
    _ modelPath: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
    _ gpuLayers: Int32,
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
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
    _ gpuLayers: Int32,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_stream")
private func etos_local_llm_generate_stream(
    _ modelPath: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
    _ gpuLayers: Int32,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
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
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
    _ gpuLayers: Int32,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
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

@_silgen_name("etos_local_llm_parse_tool_calls")
private func etos_local_llm_parse_tool_calls(
    _ modelPath: UnsafePointer<CChar>,
    _ messages: UnsafePointer<ETOSLocalLLMChatMessage>?,
    _ messageCount: Int32,
    _ tools: UnsafePointer<ETOSLocalLLMTool>?,
    _ toolCount: Int32,
    _ generatedText: UnsafePointer<CChar>,
    _ content: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ toolCalls: UnsafeMutablePointer<UnsafeMutablePointer<ETOSLocalLLMToolCall>?>,
    _ toolCallCount: UnsafeMutablePointer<Int32>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_free")
private func etos_local_llm_free(_ pointer: UnsafeMutablePointer<CChar>)

@_silgen_name("etos_local_llm_free_float")
private func etos_local_llm_free_float(_ pointer: UnsafeMutablePointer<Float>)

@_silgen_name("etos_local_llm_free_tool_calls")
private func etos_local_llm_free_tool_calls(_ pointer: UnsafeMutablePointer<ETOSLocalLLMToolCall>, _ count: Int32)
