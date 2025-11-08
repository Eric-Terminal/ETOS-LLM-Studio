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
        internalMemoriesPublisher.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryManager")
    private var similarityIndex: SimilarityIndex!
    private let rawStore = MemoryRawStore()
    private let internalMemoriesPublisher = CurrentValueSubject<[MemoryItem], Never>([])
    private let persistenceQueue = DispatchQueue(label: "com.etos.memory.persistence.queue")
    private var initializationTask: Task<Void, Never>!
    private var cachedMemories: [MemoryItem] = []
    private let dateFormatter = ISO8601DateFormatter()
    private let chunker: MemoryChunker
    private let embeddingGenerator: MemoryEmbeddingGenerating
    private let preferredEmbeddingModelKey = "memoryEmbeddingModelIdentifier"

    // MARK: - 初始化

    /// 公开的初始化方法，用于生产环境。
    public init(embeddingGenerator: MemoryEmbeddingGenerating? = nil, chunkSize: Int = 200) {
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        logger.info("🧠 MemoryManager v2 (wrapper) 正在初始化...")
        self.initializationTask = Task {
            await self.setup()
        }
    }
    
    /// 内部的初始化方法，用于测试环境，允许注入一个自定义的 SimilarityIndex。
    internal init(testIndex: SimilarityIndex, embeddingGenerator: MemoryEmbeddingGenerating? = nil, chunkSize: Int = 200) {
        logger.info("🧠 MemoryManager v2 (wrapper) 正在使用测试索引进行初始化...")
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        self.similarityIndex = testIndex
        self.initializationTask = Task {
            do {
                let loadedItems = try self.similarityIndex.loadIndex() ?? []
                let memories = loadedItems.map { MemoryItem(from: $0) }.sorted(by: { $0.createdAt > $1.createdAt })
                self.cachedMemories = memories
                self.internalMemoriesPublisher.send(memories)
                logger.info("  - 测试初始化完成。从磁盘加载了 \(memories.count) 条记忆。")
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
        MemoryStoragePaths.ensureRootDirectory()
        let nativeEmbeddings = NativeEmbeddings(language: NLLanguage.simplifiedChinese)
        let vectorStore = SQLiteVectorStore()
        self.similarityIndex = await SimilarityIndex(
            name: MemoryStoragePaths.vectorStoreName,
            model: nativeEmbeddings,
            vectorStore: vectorStore
        )
        
        do {
            let vectorDirectory = MemoryStoragePaths.vectorStoreDirectory()
            _ = try self.similarityIndex.loadIndex(
                fromDirectory: vectorDirectory,
                name: MemoryStoragePaths.vectorStoreName
            )
            logger.info("  - 向量索引初始化完成，当前条目: \(self.similarityIndex.indexItems.count)。")
        } catch {
            logger.error("  - ❌ 加载记忆索引失败: \(error.localizedDescription)")
        }
        
        var rawMemories = rawStore.loadMemories().sorted(by: { $0.createdAt > $1.createdAt })
        if rawMemories.isEmpty, !self.similarityIndex.indexItems.isEmpty {
            rawMemories = self.similarityIndex.indexItems
                .map { MemoryItem(from: $0) }
                .sorted(by: { $0.createdAt > $1.createdAt })
            cachedMemories = rawMemories
            internalMemoriesPublisher.send(rawMemories)
            persistRawMemories()
            logger.info("  - 从旧索引迁移 \(rawMemories.count) 条记忆到 JSON。")
        } else {
            cachedMemories = rawMemories
            internalMemoriesPublisher.send(rawMemories)
            logger.info("  - 原文记忆初始化完成，当前条目: \(rawMemories.count)。")
        }
    }

    // MARK: - 公开方法 (CRUD)

    /// 添加一条新的记忆。
    public func addMemory(content: String) async {
        await initializationTask.value
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return }
        
        do {
            let embeddings = try await embeddingGenerator.generateEmbeddings(
                for: chunkTexts,
                preferredModelID: preferredEmbeddingModelIdentifier()
            )
            let memory = MemoryItem(id: UUID(), content: trimmed, embedding: [], createdAt: Date())
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("✅ 已添加新的记忆。")
        } catch {
            logger.error("❌ 添加记忆失败：\(error.localizedDescription)")
        }
    }
    
    /// 从外部导入一条记忆（用于设备同步等场景）。
    @discardableResult
    public func restoreMemory(id: UUID, content: String, createdAt: Date) async -> Bool {
        await initializationTask.value
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return false }
        
        do {
            let embeddings = try await embeddingGenerator.generateEmbeddings(
                for: chunkTexts,
                preferredModelID: preferredEmbeddingModelIdentifier()
            )
            let memory = MemoryItem(id: id, content: trimmed, embedding: [], createdAt: createdAt)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("🔁 已恢复外部记忆。")
            return true
        } catch {
            logger.error("❌ 恢复外部记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 更新一条现有的记忆。
    public func updateMemory(item: MemoryItem) async {
        await initializationTask.value
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await deleteMemories([item])
            return
        }
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return }
        
        do {
            let embeddings = try await embeddingGenerator.generateEmbeddings(
                for: chunkTexts,
                preferredModelID: preferredEmbeddingModelIdentifier()
            )
            removeVectorEntries(for: [item.id])
            let updatedMemory = MemoryItem(id: item.id, content: trimmed, embedding: [], createdAt: item.createdAt)
            await ingest(memory: updatedMemory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("✅ 已更新记忆项。")
        } catch {
            logger.error("❌ 更新记忆失败：\(error.localizedDescription)")
        }
    }

    /// 删除一条或多条记忆。
    public func deleteMemories(_ items: [MemoryItem]) async {
        await initializationTask.value
        let idsToDelete = Set(items.map { $0.id })
        cachedMemories.removeAll { idsToDelete.contains($0.id) }
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
        
        removeVectorEntries(for: idsToDelete)
        saveIndex()
        logger.info("🗑️ 已删除 \(items.count) 条记忆。")
    }
    
    /// 获取所有记忆。
    public func getAllMemories() async -> [MemoryItem] {
        await initializationTask.value
        return cachedMemories
    }

    // MARK: - 公开方法 (搜索)

    /// 根据查询文本搜索最相关的记忆。
    public func searchMemories(query: String, topK: Int) async -> [MemoryItem] {
        await initializationTask.value
        guard topK > 0 else { return [] }
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        do {
            let embeddings = try await embeddingGenerator.generateEmbeddings(
                for: [trimmed],
                preferredModelID: preferredEmbeddingModelIdentifier()
            )
            guard let queryEmbedding = embeddings.first else { return [] }
            let results = similarityIndex.search(usingQueryEmbedding: queryEmbedding, top: topK)
            return results.map { MemoryItem(from: $0) }
        } catch {
            logger.error("❌ 记忆检索失败：\(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 私有方法
    
    private func saveIndex() {
        let directory = MemoryStoragePaths.vectorStoreDirectory()
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                _ = try self.similarityIndex.saveIndex(
                    toDirectory: directory,
                    name: MemoryStoragePaths.vectorStoreName
                )
                self.logger.info("💾 向量索引已保存。")
            } catch {
                self.logger.error("❌ 自动保存记忆索引失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func ingest(memory: MemoryItem, chunkTexts: [String], embeddings: [[Float]]) async {
        guard chunkTexts.count == embeddings.count else {
            logger.error("❌ 嵌入数量与分块数量不一致，取消写入。")
            return
        }
        
        for (index, chunkText) in chunkTexts.enumerated() {
            let chunkID = UUID().uuidString
            let metadata = [
                "createdAt": dateFormatter.string(from: memory.createdAt),
                "parentMemoryId": memory.id.uuidString,
                "chunkIndex": String(index),
                "chunkId": chunkID
            ]
            
            await similarityIndex.addItem(
                id: chunkID,
                text: chunkText,
                metadata: metadata,
                embedding: embeddings[index]
            )
        }
        
        cacheMemory(memory)
        saveIndex()
    }
    
    private func cacheMemory(_ memory: MemoryItem) {
        if let index = cachedMemories.firstIndex(where: { $0.id == memory.id }) {
            cachedMemories[index] = memory
        } else {
            cachedMemories.append(memory)
        }
        cachedMemories.sort(by: { $0.createdAt > $1.createdAt })
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
    }
    
    private func preferredEmbeddingModelIdentifier() -> String? {
        UserDefaults.standard.string(forKey: preferredEmbeddingModelKey)
    }
    
    private func persistRawMemories() {
        let memoriesToPersist = cachedMemories
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.rawStore.saveMemories(memoriesToPersist)
                self.logger.info("💾 原文记忆已保存。")
            } catch {
                self.logger.error("❌ 保存原文记忆失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func removeVectorEntries(for ids: Set<UUID>) {
        let idsAsString = Set(ids.map { $0.uuidString })
        let itemsToRemove = similarityIndex.indexItems.filter { item in
            if idsAsString.contains(item.id) { return true }
            if let parentID = item.metadata["parentMemoryId"], idsAsString.contains(parentID) {
                return true
            }
            return false
        }
        
        for item in itemsToRemove {
            similarityIndex.removeItem(id: item.id)
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
