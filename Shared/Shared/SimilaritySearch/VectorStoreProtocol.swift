// ============================================================================
// VectorStoreProtocol.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了 VectorStoreProtocol。
// 这个协议抽象了向量索引的持久化存储逻辑，使得可以轻松切换不同的存储后端。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation

/// 向量存储协议
public protocol VectorStoreProtocol {
    /// 保存索引项到指定的 URL。
    /// - Parameters:
    ///   - items: 要保存的 `IndexItem` 数组。
    ///   - url: 保存到的目录 URL。
    ///   - name: 索引的名称。
    /// - Returns: 保存文件的最终 URL。
    func saveIndex(items: [IndexItem], to url: URL, as name: String) throws -> URL

    /// 从指定的 URL 加载索引项。
    /// - Parameter url: 要加载的索引文件的 URL。
    /// - Returns: 一个 `IndexItem` 数组。
    func loadIndex(from url: URL) throws -> [IndexItem]

    /// 列出指定 URL 目录下的所有索引文件。
    /// - Parameter url: 要搜索索引文件的目录 URL。
    /// - Returns: 一个包含所有找到的索引文件 URL 的数组。
    func listIndexes(at url: URL) -> [URL]
}