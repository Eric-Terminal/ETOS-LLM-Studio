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
import os.log

public enum NativeEmbeddingType {
    case wordEmbedding
    case sentenceEmbedding
}

// TODO: 需要从 SimilaritySearchKit 移植 NativeTokenizer.swift 文件。

public class NativeEmbeddings: EmbeddingsProtocol {
    public let model: ModelActor
    public let tokenizer: any TokenizerProtocol
    // NOTE: 由于 iOS/watchOS 26 以后系统不再保证内置 zh-Hans 语料，
    // 该实现仅作为临时方案；后续将迁移到项目内置的外部嵌入模型以避免系统依赖。

    public init(
        language: NLLanguage = .english,
        fallbackLanguage: NLLanguage? = .english,
        type: NativeEmbeddingType = .sentenceEmbedding
    ) {
        self.tokenizer = NativeTokenizer()
        self.model = ModelActor(
            preferredLanguage: language,
            fallbackLanguage: fallbackLanguage,
            type: type
        )
    }

    // MARK: - 密集嵌入 (Dense Embeddings)

    public actor ModelActor {
        private let model: NLEmbedding?
        private let languageInUse: NLLanguage?
        private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "NativeEmbeddings")

        init(
            preferredLanguage: NLLanguage,
            fallbackLanguage: NLLanguage? = .english,
            type: NativeEmbeddingType = .sentenceEmbedding
        ) {
            if let nativeModel = ModelActor.loadModel(language: preferredLanguage, type: type) {
                model = nativeModel
                languageInUse = preferredLanguage
            } else if
                let fallbackLanguage,
                fallbackLanguage != preferredLanguage,
                let fallbackModel = ModelActor.loadModel(language: fallbackLanguage, type: type) {
                model = fallbackModel
                languageInUse = fallbackLanguage
                ModelActor.logger.warning("⚠️ 无法加载 \(preferredLanguage.rawValue) 的嵌入模型，已回退到 \(fallbackLanguage.rawValue)。")
            } else {
                model = nil
                languageInUse = nil
                ModelActor.logger.error("❌ 无法加载 \(preferredLanguage.rawValue) 的嵌入模型，且缺少有效回退。记忆搜索将被禁用。")
            }
        }

        func vector(for sentence: String) -> [Float]? {
            guard let model else {
                return nil
            }
            return model.vector(for: sentence)?.map { Float($0) }
        }

        private static func loadModel(language: NLLanguage, type: NativeEmbeddingType) -> NLEmbedding? {
            switch type {
            case .sentenceEmbedding:
                return NLEmbedding.sentenceEmbedding(for: language)
            case .wordEmbedding:
                return NLEmbedding.wordEmbedding(for: language)
            }
        }
    }

    public func encode(sentence: String) async -> [Float]? {
        return await model.vector(for: sentence)
    }

}
