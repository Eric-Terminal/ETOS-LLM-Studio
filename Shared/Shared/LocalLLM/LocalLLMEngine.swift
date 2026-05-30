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

    public init(
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.contextSize = max(1, contextSize)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.temperature = temperature
        self.topP = topP
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
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.generateChat(
                messages: messages,
                modelPath: modelURL.path,
                contextSize: options.contextSize,
                maxOutputTokens: options.maxOutputTokens,
                temperature: options.temperature,
                topP: options.topP
            )
        }.value
    }

    public func stream(
        messages: [LocalLLMChatMessage],
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) throws -> AsyncThrowingStream<String, Error> {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return LocalLLMBridge.streamChat(
            messages: messages,
            modelPath: modelURL.path,
            contextSize: options.contextSize,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
            topP: options.topP
        )
    }
}

private enum LocalLLMBridge {
    static func generateChat(
        messages: [LocalLLMChatMessage],
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double?
    ) throws -> String {
        guard !messages.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let preparedMessages = PreparedLocalLLMChatMessages(messages)
        let status = modelPath.withCString { modelPathCString in
            preparedMessages.withUnsafeBufferPointer { messagesPointer in
                etos_local_llm_generate_chat(
                    modelPathCString,
                    messagesPointer.baseAddress,
                    Int32(messagesPointer.count),
                    Int32(max(1, contextSize)),
                    Int32(max(1, maxOutputTokens)),
                    Float(temperature ?? 0.8),
                    Float(topP ?? 0.95),
                    &outputPointer,
                    &errorPointer
                )
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
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double?
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
                let status = modelPath.withCString { modelPathCString in
                    preparedMessages.withUnsafeBufferPointer { messagesPointer in
                        etos_local_llm_generate_chat_stream(
                            modelPathCString,
                            messagesPointer.baseAddress,
                            Int32(messagesPointer.count),
                            Int32(max(1, contextSize)),
                            Int32(max(1, maxOutputTokens)),
                            Float(temperature ?? 0.8),
                            Float(topP ?? 0.95),
                            localLLMStreamCallback,
                            statePointer,
                            &errorPointer
                        )
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
}

private struct ETOSLocalLLMChatMessage {
    var role: UnsafePointer<CChar>?
    var content: UnsafePointer<CChar>?
}

private final class PreparedLocalLLMChatMessages {
    private let rolePointers: [UnsafeMutablePointer<CChar>]
    private let contentPointers: [UnsafeMutablePointer<CChar>]
    private let bridgedMessages: [ETOSLocalLLMChatMessage]

    init(_ messages: [LocalLLMChatMessage]) {
        var rolePointers: [UnsafeMutablePointer<CChar>] = []
        var contentPointers: [UnsafeMutablePointer<CChar>] = []
        var bridgedMessages: [ETOSLocalLLMChatMessage] = []

        for message in messages {
            guard let role = strdup(message.role) else { continue }
            guard let content = strdup(message.content) else {
                free(role)
                continue
            }
            rolePointers.append(role)
            contentPointers.append(content)
            bridgedMessages.append(ETOSLocalLLMChatMessage(role: UnsafePointer(role), content: UnsafePointer(content)))
        }

        self.rolePointers = rolePointers
        self.contentPointers = contentPointers
        self.bridgedMessages = bridgedMessages
    }

    deinit {
        rolePointers.forEach { free($0) }
        contentPointers.forEach { free($0) }
    }

    func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<ETOSLocalLLMChatMessage>) throws -> Result
    ) rethrows -> Result {
        try bridgedMessages.withUnsafeBufferPointer(body)
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
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat")
private func etos_local_llm_generate_chat(
    _ modelPath: UnsafePointer<CChar>,
    _ messages: UnsafePointer<ETOSLocalLLMChatMessage>?,
    _ messageCount: Int32,
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
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
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_generate_chat_stream")
private func etos_local_llm_generate_chat_stream(
    _ modelPath: UnsafePointer<CChar>,
    _ messages: UnsafePointer<ETOSLocalLLMChatMessage>?,
    _ messageCount: Int32,
    _ contextSize: Int32,
    _ maxOutputTokens: Int32,
    _ temperature: Float,
    _ topP: Float,
    _ tokenCallback: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_free")
private func etos_local_llm_free(_ pointer: UnsafeMutablePointer<CChar>)
