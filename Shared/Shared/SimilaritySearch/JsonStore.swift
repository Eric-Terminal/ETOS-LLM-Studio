// ============================================================================
// JsonStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了 JsonStore 类。
// 这是 VectorStoreProtocol 的一个具体实现，使用 JSON 文件来持久化存储向量索引。
// 这与我们项目中现有的持久化策略完全一致。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation

public class JsonStore: VectorStoreProtocol {
    
    /// 将索引项数组编码为 JSON 并保存到磁盘。
    public func saveIndex(items: [IndexItem], to url: URL, as name: String) throws -> URL {
        let encoder = JSONEncoder()
        let data = try encoder.encode(items)

        let fileURL = url.appendingPathComponent("\(name).json")

        do {
            try data.write(to: fileURL)
        } catch {
            throw error
        }

        return fileURL
    }

    /// 从磁盘读取 JSON 文件并解码成索引项数组。
    public func loadIndex(from url: URL) throws -> [IndexItem] {
        do {
            let data = try Data(contentsOf: url)

            let decoder = JSONDecoder()
            let items = try decoder.decode([IndexItem].self, from: data)

            return items
        } catch {
            throw error
        }
    }

    /// 列出指定目录中所有 .json 后缀的文件。
    public func listIndexes(at url: URL) -> [URL] {
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            return jsonFiles
        } catch {
            // 列出索引时出错
            return []
        }
    }
}