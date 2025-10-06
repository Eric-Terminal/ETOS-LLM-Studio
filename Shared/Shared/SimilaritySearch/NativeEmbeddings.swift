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

@available(macOS 11.0, iOS 15.0, *)
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

    // MARK: - 稀疏嵌入 (Sparse Embeddings) - BM25

    public class func encodeSparse(sentences: [String]) -> [[(index: Int, value: Double)]]? {
        let k1: Double = 1.5
        let b: Double = 0.75

        guard let wordEmbedding = NLEmbedding.wordEmbedding(for: .english) else {
            print("加载英语 NLEmbedding 失败。")
            return nil
        }
        let tokenizedSentences = sentences.map { tokenize(sentence: $0, wordEmbedding: wordEmbedding) }
        let vocabulary = createVocabulary(from: tokenizedSentences)
        let idf = computeIDF(vocabulary: vocabulary, sentences: tokenizedSentences)
        let avgDocLength = Double(tokenizedSentences.reduce(0) { $0 + $1.count }) / Double(tokenizedSentences.count)
        let embeddings = computeBM25(tokenizedSentences: tokenizedSentences, vocabulary: vocabulary, idf: idf, avgDocLength: avgDocLength, k1: k1, b: b)
        return embeddings
    }

    class func tokenize(sentence: String, wordEmbedding _: NLEmbedding) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        return tokenizer.tokens(for: sentence.startIndex..<sentence.endIndex).map { String(sentence[$0]) }
    }

    class func createVocabulary(from sentences: [[String]]) -> [String] {
        var vocabulary: Set<String> = []
        for sentence in sentences {
            for word in sentence {
                vocabulary.insert(word)
            }
        }
        return Array(vocabulary)
    }

    class func computeIDF(vocabulary: [String], sentences: [[String]]) -> [String: Double] {
        var idf: [String: Double] = [:]
        let numDocs = Double(sentences.count)
        for word in vocabulary {
            let numDocsWithWord = Double(sentences.filter { $0.contains(word) }.count)
            idf[word] = log((numDocs - numDocsWithWord + 0.5) / (numDocsWithWord + 0.5))
        }
        return idf
    }

    class func computeBM25(tokenizedSentences: [[String]], vocabulary: [String], idf: [String: Double], avgDocLength: Double, k1: Double, b: Double) -> [[(index: Int, value: Double)]] {
        var embeddings: [[(index: Int, value: Double)]] = []
        for sentence in tokenizedSentences {
            var sparseVector: [(index: Int, value: Double)] = []
            for (index, word) in vocabulary.enumerated() {
                let tf = Double(sentence.filter { $0 == word }.count)
                let docLength = Double(sentence.count)
                let bm25 = idf[word]! * ((tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (docLength / avgDocLength))))
                if bm25 != 0 {
                    sparseVector.append((index: index, value: bm25))
                }
            }
            embeddings.append(sparseVector)
        }
        return embeddings
    }
}