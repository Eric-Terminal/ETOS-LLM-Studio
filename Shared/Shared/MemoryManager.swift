// ============================================================================
// MemoryManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了新版的 MemoryManager。
// 它作为 SimilaritySearchKit 的一个包装层 (Wrapper)，为上层业务逻辑
// 提供一个简洁、稳定的接口来管理长期记忆。
// ============================================================================

import Foundation
import Combine
import NaturalLanguage
import os.log

public class MemoryManager {

    // MARK: - 单例
    
    public static let shared = MemoryManager()

    // MARK: - 公开属性
    
    /// 一个发布者，当记忆库发生变化时发出通知，并按创建日期降序排列。
    public var memoriesPublisher: AnyPublisher<[MemoryItem], Never> {
        internalMemoriesPublisher.map { indexItems in
            indexItems.map { MemoryItem(from: $0) }.sorted(by: { $0.createdAt > $1.createdAt })
        }.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryManager")
    private var similarityIndex: SimilarityIndex!
    private let internalMemoriesPublisher = CurrentValueSubject<[IndexItem], Never>([])
    private let persistenceQueue = DispatchQueue(label: "com.etos.memory.persistence.queue")
    private var initializationTask: Task<Void, Never>!

    // MARK: - 初始化

    /// 公开的初始化方法，用于生产环境。
    public init() {
        logger.info("🧠 MemoryManager v2 (wrapper) 正在初始化...")
        self.initializationTask = Task {
            await self.setup()
        }
    }
    
    /// 内部的初始化方法，用于测试环境，允许注入一个自定义的 SimilarityIndex。
    internal init(testIndex: SimilarityIndex) {
        logger.info("🧠 MemoryManager v2 (wrapper) 正在使用测试索引进行初始化...")
        self.similarityIndex = testIndex
        self.initializationTask = Task {
            do {
                let loadedItems = try self.similarityIndex.loadIndex()
                self.internalMemoriesPublisher.send(loadedItems ?? [])
                logger.info("  - 测试初始化完成。从磁盘加载了 \(loadedItems?.count ?? 0) 条记忆。")
            } catch {
                logger.error("  - ❌ (测试) 加载记忆索引失败: \(error.localizedDescription)")
                self.internalMemoriesPublisher.send([])
            }
        }
    }
    
    // MARK: - 公开方法 (测试辅助)
    
    /// 等待异步初始化过程完成。仅用于测试。
    public func waitForInitialization() async {
        await initializationTask.value
    }
    
    private func setup() async {
        let nativeEmbeddings = NativeEmbeddings(language: NLLanguage.simplifiedChinese)
        self.similarityIndex = await SimilarityIndex(name: "etos-memory-index", model: nativeEmbeddings)
        
        do {
            let loadedItems = try similarityIndex.loadIndex()
            self.internalMemoriesPublisher.send(loadedItems ?? [])
            logger.info("  - 初始化完成。从磁盘加载了 \(loadedItems?.count ?? 0) 条记忆。")
        } catch {
            logger.error("  - ❌ 加载记忆索引失败: \(error.localizedDescription)")
            self.internalMemoriesPublisher.send([])
        }
    }

    // MARK: - 公开方法 (CRUD)

    /// 添加一条新的记忆。
    public func addMemory(content: String) async {
        await initializationTask.value
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID().uuidString
        let metadata = ["createdAt": ISO8601DateFormatter().string(from: Date())]
        await similarityIndex.addItem(id: id, text: content, metadata: metadata)
        internalMemoriesPublisher.send(similarityIndex.indexItems)
        saveIndex()
        logger.info("✅ 已添加新的记忆。")
    }

    /// 更新一条现有的记忆。
    public func updateMemory(item: MemoryItem) async {
        await initializationTask.value
        // SimilarityIndex.updateItem 会在内部处理数组的更新
        similarityIndex.updateItem(id: item.id.uuidString, text: item.content)
        internalMemoriesPublisher.send(similarityIndex.indexItems)
        saveIndex()
        logger.info("✅ 已更新记忆项。")
    }

    /// 删除一条或多条记忆。
    public func deleteMemories(_ items: [MemoryItem]) async {
        await initializationTask.value
        // SimilarityIndex.removeItem 会在内部处理数组的更新
        for item in items {
            similarityIndex.removeItem(id: item.id.uuidString)
        }
        internalMemoriesPublisher.send(similarityIndex.indexItems)
        saveIndex()
        logger.info("🗑️ 已删除 \(items.count) 条记忆。")
    }
    
    /// 获取所有记忆。
    public func getAllMemories() async -> [MemoryItem] {
        await initializationTask.value
        return similarityIndex.indexItems.map { MemoryItem(from: $0) }.sorted(by: { $0.createdAt > $1.createdAt })
    }

    // MARK: - 公开方法 (搜索)

    /// 根据查询文本搜索最相关的记忆。
    public func searchMemories(query: String, topK: Int) async -> [MemoryItem] {
        await initializationTask.value
        
        let searchTopK: Int
        if topK == 0 {
            searchTopK = similarityIndex.indexItems.count
        } else {
            searchTopK = topK
        }
        
        let results = await similarityIndex.search(query, top: searchTopK)
        return results.map { MemoryItem(from: $0) }
    }
    
    // MARK: - 私有方法
    
    private func saveIndex() {
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                _ = try self.similarityIndex.saveIndex()
                self.logger.info("💾 记忆索引已保存。")
            } catch {
                self.logger.error("❌ 自动保存记忆索引失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 模型转换

fileprivate extension MemoryItem {
    init(from indexItem: IndexItem) {
        self.id = UUID(uuidString: indexItem.id) ?? UUID()
        self.content = indexItem.text
        self.embedding = indexItem.embedding
        
        if let dateString = indexItem.metadata["createdAt"], let date = ISO8601DateFormatter().date(from: dateString) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }
    }
    
    init(from searchResult: SearchResult) {
        self.id = UUID(uuidString: searchResult.id) ?? UUID()
        self.content = searchResult.text
        self.embedding = [] // 搜索结果不包含 embedding
        
        if let dateString = searchResult.metadata["createdAt"], let date = ISO8601DateFormatter().date(from: dateString) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }
    }
}
