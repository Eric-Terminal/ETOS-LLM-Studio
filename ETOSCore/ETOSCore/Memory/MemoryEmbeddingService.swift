// ============================================================================
// MemoryEmbeddingService.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过适配器调用云端嵌入 API，为 MemoryManager 提供统一的向量生成能力。
// ============================================================================

import Foundation
import os.log

public struct MemoryEmbeddingInput: Sendable {
    /// 文本与图片会由多模态模型编码到同一个稠密向量空间。
    public var text: String
    public var imageAttachments: [ImageAttachment]

    public init(text: String = "", imageAttachments: [ImageAttachment] = []) {
        self.text = text
        self.imageAttachments = imageAttachments
    }
}

public protocol MemoryEmbeddingGenerating {
    func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]]
    func generateEmbeddings(for inputs: [MemoryEmbeddingInput], preferredModelID: String?) async throws -> [[Float]]
}

public extension MemoryEmbeddingGenerating {
    func generateEmbeddings(
        for inputs: [MemoryEmbeddingInput],
        preferredModelID: String?
    ) async throws -> [[Float]] {
        guard inputs.allSatisfy({
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MemoryEmbeddingError.requestBuildFailed
        }
        return try await generateEmbeddings(
            for: inputs.map(\.text),
            preferredModelID: preferredModelID
        )
    }
}

public enum MemoryEmbeddingError: LocalizedError {
    case emptyInput
    case noAvailableModel
    case preferredModelUnavailable(String)
    case adapterMissing(String)
    case requestBuildFailed
    case httpStatus(Int, String?)
    case invalidResponse
    case resultCountMismatch(expected: Int, actual: Int)
    
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return NSLocalizedString("未提供任何待编码文本。", comment: "Memory embedding empty input error")
        case .noAvailableModel:
            return NSLocalizedString("尚未配置可用的嵌入模型。", comment: "Memory embedding no available model error")
        case .preferredModelUnavailable(let identifier):
            return String(format: NSLocalizedString("已选嵌入模型不可用或不支持嵌入：%@", comment: "Memory embedding preferred model unavailable error"), identifier)
        case .adapterMissing(let format):
            return String(format: NSLocalizedString("找不到 '%@' 对应的嵌入适配器。", comment: "Memory embedding adapter missing error"), format)
        case .requestBuildFailed:
            return NSLocalizedString("无法构建嵌入请求，请检查提供商配置。", comment: "Memory embedding request build failed error")
        case .httpStatus(let code, let body):
            if let body {
                return String(format: NSLocalizedString("嵌入 API 响应异常 (%d): %@", comment: "Memory embedding HTTP error with body"), code, body)
            }
            return String(format: NSLocalizedString("嵌入 API 响应异常，状态码: %d", comment: "Memory embedding HTTP error"), code)
        case .invalidResponse:
            return NSLocalizedString("嵌入 API 返回了无效的数据。", comment: "Memory embedding invalid response error")
        case .resultCountMismatch(let expected, let actual):
            return String(format: NSLocalizedString("嵌入结果数量与输入不一致：预期 %d，实际 %d。", comment: "Memory embedding result count mismatch error"), expected, actual)
        }
    }
    
    /// 判断是否为硬错误（不应该重试的错误）
    public var isHardError: Bool {
        switch self {
        case .httpStatus(let code, _):
            // 4xx 客户端错误通常是硬错误，不应重试
            return (400...499).contains(code)
        case .noAvailableModel, .preferredModelUnavailable, .adapterMissing, .requestBuildFailed:
            return true
        default:
            return false
        }
    }
    
    /// 获取HTTP状态码（如果是HTTP错误）
    public var httpStatusCode: Int? {
        if case .httpStatus(let code, _) = self {
            return code
        }
        return nil
    }
}

final class CloudEmbeddingService: MemoryEmbeddingGenerating {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "CloudEmbeddingService")
    private let adapters: [String: APIAdapter]
    private let urlSession: URLSession
    
    init(
        adapters: [String: APIAdapter] = [
            "openai-compatible": OpenAIAdapter(),
            "openai-responses": OpenAIResponsesAdapter(),
            "gemini": GeminiAdapter()
        ],
        urlSession: URLSession = NetworkSessionConfiguration.shared
    ) {
        self.adapters = adapters
        self.urlSession = urlSession
    }
    
    func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
        try await generateEmbeddings(
            for: texts.map { MemoryEmbeddingInput(text: $0) },
            preferredModelID: preferredModelID
        )
    }

    func generateEmbeddings(
        for inputs: [MemoryEmbeddingInput],
        preferredModelID: String?
    ) async throws -> [[Float]] {
        if inputs.isEmpty || inputs.contains(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.imageAttachments.isEmpty
        }) {
            throw MemoryEmbeddingError.emptyInput
        }
        
        let runnableModels = loadRunnableModels()
        let embeddingModels = runnableModels.filter { $0.model.supportsEmbedding }
        guard !embeddingModels.isEmpty else {
            throw MemoryEmbeddingError.noAvailableModel
        }
        
        let targetModel = try resolveModel(preferredID: preferredModelID, from: embeddingModels)
        if LocalModelProviderBridge.isLocalRunnableModel(targetModel) {
            return try await generateLocalEmbeddings(for: inputs, using: targetModel)
        }
        guard inputs.allSatisfy({
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MemoryEmbeddingError.requestBuildFailed
        }
        guard let adapter = adapters[targetModel.provider.apiFormat] else {
            throw MemoryEmbeddingError.adapterMissing(targetModel.provider.apiFormat)
        }
        let texts = inputs.map(\.text)
        guard let request = adapter.buildEmbeddingRequest(for: targetModel, texts: texts) else {
            throw MemoryEmbeddingError.requestBuildFailed
        }
        
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MemoryEmbeddingError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw MemoryEmbeddingError.httpStatus(httpResponse.statusCode, bodyString)
        }
        
        let embeddings = try adapter.parseEmbeddingResponse(data: data)
        guard embeddings.count == texts.count else {
            throw MemoryEmbeddingError.resultCountMismatch(expected: texts.count, actual: embeddings.count)
        }
        logger.debug("嵌入请求成功，模型: \(targetModel.model.displayName), 条数: \(embeddings.count)")
        return embeddings
    }
    
    private func loadRunnableModels() -> [RunnableModel] {
        let localModelStore = LocalModelStore.shared
        let providers = LocalModelProviderBridge.applyingLocalProvider(
            to: ConfigLoader.loadProviders(),
            records: localModelStore.models,
            isEnabled: localModelStore.isProviderEnabled,
            preferRecordBasics: true
        )
        var runnable: [RunnableModel] = []
        for provider in providers {
            for model in provider.models {
                runnable.append(RunnableModel(provider: provider, model: model))
            }
        }
        return runnable
    }
    
    /// 清除缓存，当提供商配置发生变化时调用
    func clearCache() {
    }
    
    private func resolveModel(preferredID: String?, from models: [RunnableModel]) throws -> RunnableModel {
        if let preferredID,
           !preferredID.isEmpty,
           let match = models.first(where: { $0.id == preferredID }) {
            return match
        }

        if let preferredID, !preferredID.isEmpty {
            throw MemoryEmbeddingError.preferredModelUnavailable(preferredID)
        }

        return models[0]
    }

    private func generateLocalEmbeddings(
        for inputs: [MemoryEmbeddingInput],
        using runnableModel: RunnableModel
    ) async throws -> [[Float]] {
        guard let recordID = LocalModelProviderBridge.localRecordID(from: runnableModel.id),
              let record = LocalModelStore.shared.models.first(where: { $0.id == recordID }),
              LocalModelStore.shared.fileExists(for: record) else {
            throw MemoryEmbeddingError.preferredModelUnavailable(runnableModel.id)
        }
        let includesImages = inputs.contains { !$0.imageAttachments.isEmpty }
        if includesImages && !LocalModelStore.shared.mmprojFileExists(for: record) {
            throw MemoryEmbeddingError.requestBuildFailed
        }

        let overrides = runnableModel.effectiveOverrideParameters
        return try await LocalLLMEngine.shared.embed(
            inputs: inputs.enumerated().map { inputIndex, input in
                LocalLLMEmbeddingInput(
                    text: input.text,
                    mediaAttachments: input.imageAttachments.enumerated().map { attachmentIndex, attachment in
                        LocalLLMMediaAttachment(
                            id: "memory-\(inputIndex)-\(attachmentIndex)-\(attachment.id.uuidString.lowercased())",
                            data: attachment.data,
                            mimeType: attachment.mimeType,
                            fileName: attachment.fileName
                        )
                    }
                )
            },
            modelURL: LocalModelStore.shared.fileURL(for: record),
            options: LocalLLMEmbeddingOptions(
                contextSize: max(1, overrides.localIntValue(for: "context_size") ?? overrides.localIntValue(for: "n_ctx") ?? record.effectiveContextSize),
                gpuLayers: overrides.localIntValue(for: "n_gpu_layers") ?? record.effectiveGPULayers,
                mmprojPath: LocalModelStore.shared.mmprojURL(for: record)?.path,
                flashAttention: overrides.localIntValue(for: "flash_attn")
                    .flatMap { LocalLLMFlashAttentionMode(rawValue: Int32(clamping: $0)) }
                    ?? record.effectiveFlashAttention,
                imageMinTokens: overrides.localIntValue(for: "image_min_tokens") ?? record.effectiveImageMinTokens,
                imageMaxTokens: overrides.localIntValue(for: "image_max_tokens") ?? record.effectiveImageMaxTokens
            )
        )
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func localIntValue(for key: String) -> Int? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            return rawValue
        case .double(let rawValue):
            return Int(rawValue)
        case .string(let rawValue):
            return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
