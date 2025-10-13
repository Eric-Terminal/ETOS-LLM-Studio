// ============================================================================
// DistanceMetrics.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了多种计算向量相似度的具体实现方法。
// 它利用 Accelerate 框架进行高性能计算。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Accelerate
import Foundation

/// 使用余弦相似度实现 `DistanceMetricProtocol` 的结构体。
///
/// 余弦相似度是一种度量两个向量之间夹角的余弦值的度量。它非常适合于稀疏嵌入，以及当嵌入的幅度影响相似性时。
///
/// - 注意: 当嵌入的幅度在你的用例中很重要，并且对于稀疏嵌入时，请使用此度量。
public struct CosineSimilarity: DistanceMetricProtocol {
    public init() {}

    public func findNearest(for queryEmbedding: [Float], in neighborEmbeddings: [[Float]], resultsCount: Int) -> [(Float, Int)] {
        let scores = neighborEmbeddings.map { distance(between: queryEmbedding, and: $0) }
        return sortedScores(scores: scores, topK: resultsCount)
    }

    public func distance(between firstEmbedding: [Float], and secondEmbedding: [Float]) -> Float {
        // 确保嵌入具有相同的长度
        if firstEmbedding.count != secondEmbedding.count {
            print("嵌入向量必须具有相同的长度")
            return -1
        }

        var dotProduct: Float = 0
        var firstMagnitude: Float = 0
        var secondMagnitude: Float = 0

        // 使用 Accelerate 计算点积和幅度
        vDSP_dotpr(firstEmbedding, 1, secondEmbedding, 1, &dotProduct, vDSP_Length(firstEmbedding.count))
        vDSP_svesq(firstEmbedding, 1, &firstMagnitude, vDSP_Length(firstEmbedding.count))
        vDSP_svesq(secondEmbedding, 1, &secondMagnitude, vDSP_Length(secondEmbedding.count))

        // 取幅度的平方根
        firstMagnitude = sqrt(firstMagnitude)
        secondMagnitude = sqrt(secondMagnitude)

        // 返回余弦相似度
        return dotProduct / (firstMagnitude * secondMagnitude)
    }
}

// MARK: - 辅助函数

/// 辅助函数，用于对分数进行排序并返回前K个分数及其索引。
///
/// - Parameters:
///   - scores: 代表分数的 Float 数组。
///   - topK: 要返回的最高分数的数量。
///
/// - Returns: 包含前K个分数及其对应索引的元组数组。
public func sortedScores(scores: [Float], topK: Int) -> [(Float, Int)] {
    // 组合索引和分数
    let indexedScores = scores.enumerated().map { index, score in (score, index) }

    // 按分数降序排序
    func compare(a: (Float, Int), b: (Float, Int)) throws -> Bool {
        return a.0 > b.0
    }

    // 取前k个邻居
    do {
        return try indexedScores.topK(topK, by: compare)
    } catch {
        print("在 sortedScores 中比较元素时出错")
        return []
    }
}