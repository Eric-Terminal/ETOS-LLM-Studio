// ============================================================================
// MemoryEmbeddingService.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过适配器调用云端嵌入 API，为 MemoryManager 提供统一的向量生成能力。
// ============================================================================

import Foundation
import os.log

public protocol MemoryEmbeddingGenerating {
    func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]]
}

enum MemoryEmbeddingError: LocalizedError {
    case emptyInput
    case noAvailableModel
    case adapterMissing(String)
    case requestBuildFailed
    case httpStatus(Int, String?)
    case invalidResponse
    case resultCountMismatch(expected: Int, actual: Int)
    
    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "未提供任何待编码文本。"
        case .noAvailableModel:
            return "尚未配置可用的嵌入模型。"
        case .adapterMissing(let format):
            return "找不到 '\(format)' 对应的嵌入适配器。"
        case .requestBuildFailed:
            return "无法构建嵌入请求，请检查提供商配置。"
        case .httpStatus(let code, let body):
            if let body {
                return "嵌入 API 响应异常 (\(code)): \(body)"
            }
            return "嵌入 API 响应异常，状态码: \(code)"
        case .invalidResponse:
            return "嵌入 API 返回了无效的数据。"
        case .resultCountMismatch(let expected, let actual):
            return "嵌入结果数量与输入不一致：预期 \(expected)，实际 \(actual)。"
        }
    }
}

final class CloudEmbeddingService: MemoryEmbeddingGenerating {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "CloudEmbeddingService")
    private let adapters: [String: APIAdapter]
    private let urlSession: URLSession
    
    init(
        adapters: [String: APIAdapter] = [
            "openai-compatible": OpenAIAdapter()
        ],
        urlSession: URLSession = .shared
    ) {
        self.adapters = adapters
        self.urlSession = urlSession
    }
    
    func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
        if texts.isEmpty {
            throw MemoryEmbeddingError.emptyInput
        }
        
        let runnableModels = loadRunnableModels()
        guard !runnableModels.isEmpty else {
            throw MemoryEmbeddingError.noAvailableModel
        }
        
        let targetModel = resolveModel(preferredID: preferredModelID, from: runnableModels)
        guard let adapter = adapters[targetModel.provider.apiFormat] else {
            throw MemoryEmbeddingError.adapterMissing(targetModel.provider.apiFormat)
        }
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
        logger.debug("✅ 嵌入请求成功，模型: \(targetModel.model.displayName), 条数: \(embeddings.count)")
        return embeddings
    }
    
    private func loadRunnableModels() -> [RunnableModel] {
        let providers = ConfigLoader.loadProviders()
        var runnable: [RunnableModel] = []
        for provider in providers {
            for model in provider.models {
                runnable.append(RunnableModel(provider: provider, model: model))
            }
        }
        return runnable
    }
    
    private func resolveModel(preferredID: String?, from models: [RunnableModel]) -> RunnableModel {
        if let preferredID,
           let match = models.first(where: { $0.id == preferredID }) {
            return match
        }
        return models[0]
    }
}
