// ============================================================================
// LocalLLMEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// Swift 侧本地推理入口，底层由 C shim 隔离 llama.cpp 细节。
// ============================================================================

import Foundation

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
        prompt: String,
        modelURL: URL,
        options: LocalLLMGenerationOptions
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalLLMEngineError.modelFileMissing(modelURL.lastPathComponent)
        }

        return try await Task.detached(priority: .userInitiated) {
            try LocalLLMBridge.generate(
                prompt: prompt,
                modelPath: modelURL.path,
                contextSize: options.contextSize,
                maxOutputTokens: options.maxOutputTokens,
                temperature: options.temperature,
                topP: options.topP
            )
        }.value
    }
}

private enum LocalLLMBridge {
    static func generate(
        prompt: String,
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double?
    ) throws -> String {
        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = prompt.withCString { promptCString in
            modelPath.withCString { modelPathCString in
                etos_local_llm_generate(
                    modelPathCString,
                    promptCString,
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

@_silgen_name("etos_local_llm_free")
private func etos_local_llm_free(_ pointer: UnsafeMutablePointer<CChar>)
