// ============================================================================
// NativeEmbeddings.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了如何使用苹果原生的 NaturalLanguage 框架
// 来生成文本嵌入。这是我们应用中将文本向量化的核心实现。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation
import NaturalLanguage

public enum NativeEmbeddingType {
    case wordEmbedding
    case sentenceEmbedding
}

// TODO: 需要从 SimilaritySearchKit 移植 NativeTokenizer.swift 文件。

public class NativeEmbeddings: EmbeddingsProtocol {
    public let model: ModelActor
    public let tokenizer: any TokenizerProtocol

    public init(language: NLLanguage = .english, type: NativeEmbeddingType = .sentenceEmbedding) {
        self.tokenizer = NativeTokenizer()
        self.model = ModelActor(language: language, type: type)
    }

    // MARK: - 密集嵌入 (Dense Embeddings)

    public actor ModelActor {
        private let model: NLEmbedding

        init(language: NLLanguage, type:NativeEmbeddingType = .sentenceEmbedding) {
            switch type {
                case .sentenceEmbedding:
                    guard let nativeModel = NLEmbedding.sentenceEmbedding(for: language) else {
                        fatalError("加载 Core ML 模型失败。")
                    }
                    model = nativeModel
                case .wordEmbedding:
                    guard let nativeModel = NLEmbedding.wordEmbedding(for: language) else {
                        fatalError("加载 Core ML 模型失败。")
                    }
                    model = nativeModel
            }
            
        }

        func vector(for sentence: String) -> [Float]? {
            return model.vector(for: sentence)?.map { Float($0) }
        }
    }

    public func encode(sentence: String) async -> [Float]? {
        return await model.vector(for: sentence)
    }

}