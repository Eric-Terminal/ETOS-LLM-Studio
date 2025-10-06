// ============================================================================
// EmbeddingProtocols.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了与嵌入、相似度计算等相关的核心协议。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation
import CoreML
import NaturalLanguage
import Combine

/// 一个用于嵌入模型的协议，可以生成文本的向量表示。
/// 实现此协议以支持不同的文本向量化编码模型。
@available(macOS 11.0, iOS 15.0, *)
public protocol EmbeddingsProtocol {
    /// 嵌入模型关联的分词器类型。
    associatedtype TokenizerType

    /// 嵌入模型关联的 Core ML 模型类型。
    associatedtype ModelType

    /// 用于对输入文本进行分词的分词器。
    var tokenizer: TokenizerType { get }

    /// 用于生成嵌入的 Core ML 模型。
    var model: ModelType { get }

    /// 将输入句子编码为向量表示。
    ///
    /// - Parameter sentence: 要编码的输入句子。
    /// - Returns: 一个可选的 `Float` 数组，代表编码后的句子。
    func encode(sentence: String) async -> [Float]?
}

/// 一个用于计算向量之间相似度的任意方法的协议。
public protocol DistanceMetricProtocol {
    /// 给定一个查询嵌入向量和一组嵌入向量，查找最近的邻居。
    ///
    /// - Parameters:
    ///   - queryEmbedding: 代表查询嵌入向量的 `[Float]` 数组。
    ///   - itemEmbeddings: 代表要在其中搜索的嵌入向量列表的 `[[Float]]` 数组。
    ///   - resultsCount: 要返回的最近邻居的数量。
    ///
    /// - Returns: 一个 `[(Float, Int)]` 数组，其中每个元组包含相似度得分和 `neighborEmbeddings` 中对应项的索引。数组按相似度降序排列。
    func findNearest(for queryEmbedding: [Float], in neighborEmbeddings: [[Float]], resultsCount: Int) -> [(Float, Int)]

    /// 计算两个嵌入向量之间的距离。
    ///
    /// - Parameters:
    ///   - firstEmbedding: 代表第一个嵌入向量的 `[Float]` 数组。
    ///   - secondEmbedding: 代表第二个嵌入向量的 `[Float]` 数组。
    ///
    /// - Returns: 一个 `Float` 值，代表两个输入嵌入向量之间的距离。根据相似度度量实现的不同，距离可以代表不同的相似性或不相似性概念。
    func distance(between firstEmbedding: [Float], and secondEmbedding: [Float]) -> Float
}

/// 文本分割器协议
public protocol TextSplitterProtocol {
    /// 将输入文本分割成块的元组和可选的词元ID。
    ///
    /// - Parameters:
    ///   - text: 要分块的输入文本。
    ///   - chunkSize: 每个块的词元数。
    ///   - overlapSize: 连续块之间的重叠词元数。
    /// - Returns: 一个包含分块文本数组和可选的词元ID数组的元组。
    func split(text: String, chunkSize: Int, overlapSize: Int) -> ([String], [[String]]?)
}

/// 分词器协议
public protocol TokenizerProtocol {
    /// 将文本分词
    func tokenize(text: String) -> [String]
    /// 将词元反分词成文本
    func detokenize(tokens: [String]) -> String
}