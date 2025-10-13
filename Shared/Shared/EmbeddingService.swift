// ============================================================================
// EmbeddingService.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了 EmbeddingService。
// 这是一个单例服务，负责使用 Apple 的 Natural Language 框架从文本生成向量嵌入。
// 它为将字符串转换为高维向量提供了统一的接口，这是应用内实现语义搜索和记忆功能的基石。
// ============================================================================

import Foundation
import NaturalLanguage

class EmbeddingService {

    // MARK: - 单例
    
    static let shared = EmbeddingService()

    // MARK: - 私有属性

    private let embedder: NLEmbedding?

    // MARK: - 初始化

    private init() {
        // 初始化英语句子的嵌入器。
        // 根据苹果文档，在支持的系统版本上，此初始化是安全的。
        self.embedder = NLEmbedding.sentenceEmbedding(for: .english)
    }

    // MARK: - 公开方法

    /// 为给定的文本生成一个向量嵌入。
    /// - Parameter text: 需要转换为嵌入的字符串。
    /// - Returns: 一个代表向量嵌入的浮点数数组；如果无法生成，则返回 `nil`。
    func generateEmbedding(for text: String) -> [Float]? {
        // 确保嵌入器可用，且输入文本不为空。
        guard let embedder = embedder, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        
        // NLEmbedding 的 vector(for:) 方法返回 [Double]?，我们必须先安全地解包它。
        guard let vector = embedder.vector(for: text), !vector.isEmpty else {
            return nil
        }
        
        // 将 [Double] 转换为 [Float] 以保持数据一致性，并可能获得存储和性能上的优势。
        return vector.map { Float($0) }
    }
}
