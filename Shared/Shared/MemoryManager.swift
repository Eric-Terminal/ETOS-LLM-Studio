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

public struct MemoryEmbeddingRetryPolicy {
    public static let `default` = MemoryEmbeddingRetryPolicy()
    
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let backoffMultiplier: Double
    
    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.5, backoffMultiplier: Double = 2.0) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.backoffMultiplier = max(1.0, backoffMultiplier)
    }
}

public struct MemoryReembeddingSummary {
    public let processedMemories: Int
    public let chunkCount: Int
}

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
    private let embeddingRetryPolicy: MemoryEmbeddingRetryPolicy
    private let consistencyCheckDefaultDelay: TimeInterval = 2.0

    // MARK: - 初始化

    /// 公开的初始化方法，用于生产环境。
    public init(
        embeddingGenerator: MemoryEmbeddingGenerating? = nil,
        chunkSize: Int = 200,
        retryPolicy: MemoryEmbeddingRetryPolicy = .default
    ) {
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        self.embeddingRetryPolicy = retryPolicy
        logger.info("🧠 MemoryManager v2 (wrapper) 正在初始化...")
        self.initializationTask = Task {
            await self.setup()
        }
    }
    
    /// 内部的初始化方法，用于测试环境，允许注入一个自定义的 SimilarityIndex。
    internal init(
        testIndex: SimilarityIndex,
        embeddingGenerator: MemoryEmbeddingGenerating? = nil,
        chunkSize: Int = 200,
        retryPolicy: MemoryEmbeddingRetryPolicy = .default
    ) {
        logger.info("🧠 MemoryManager v2 (wrapper) 正在使用测试索引进行初始化...")
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        self.embeddingRetryPolicy = retryPolicy
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
        
        await reconcilePendingEmbeddings()
    }

    // MARK: - 公开方法 (CRUD)

    /// 添加一条新的记忆。
    public func addMemory(content: String) async {
        await initializationTask.value
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return }
        
        let memory = MemoryItem(id: UUID(), content: trimmed, embedding: [], createdAt: Date())
        cacheMemory(memory)
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("✅ 已添加新的记忆。")
        } catch {
            logger.error("❌ 添加记忆失败：\(error.localizedDescription)")
            scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
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
        
        let memory = MemoryItem(id: id, content: trimmed, embedding: [], createdAt: createdAt)
        cacheMemory(memory)
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("🔁 已恢复外部记忆。")
            return true
        } catch {
            logger.error("❌ 恢复外部记忆失败：\(error.localizedDescription)")
            scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
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
        
        let updatedMemory = MemoryItem(id: item.id, content: trimmed, embedding: [], createdAt: item.createdAt)
        cacheMemory(updatedMemory)
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            removeVectorEntries(for: [item.id])
            await ingest(memory: updatedMemory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("✅ 已更新记忆项。")
        } catch {
            logger.error("❌ 更新记忆失败：\(error.localizedDescription)")
            scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
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

    /// 重新构建所有记忆的嵌入，并清空旧的向量存储。
    @discardableResult
    public func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        await initializationTask.value
        logger.info("🔁 正在重新生成全部记忆嵌入...")
        let memories = cachedMemories
        similarityIndex.removeAll()
        purgePersistedVectorStores()
        
        guard !memories.isEmpty else {
            saveIndex()
            logger.info("ℹ️ 记忆列表为空，已写入空索引。")
            return MemoryReembeddingSummary(processedMemories: 0, chunkCount: 0)
        }
        
        var processedMemories = 0
        var chunkCount = 0
        
        for memory in memories {
            let chunkTexts = chunker.chunk(text: memory.content)
            guard !chunkTexts.isEmpty else {
                logger.error("⚠️ 记忆 \(memory.id.uuidString) 无有效分块，跳过。")
                continue
            }
            
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            for (index, chunkText) in chunkTexts.enumerated() {
                let chunkID = UUID().uuidString
                let metadata = chunkMetadata(for: memory, chunkIndex: index, chunkId: chunkID)
                await similarityIndex.addItem(
                    id: chunkID,
                    text: chunkText,
                    metadata: metadata,
                    embedding: embeddings[index]
                )
                chunkCount += 1
            }
            
            processedMemories += 1
        }
        
        saveIndex()
        logger.info("✅ 记忆重嵌入完成：\(processedMemories) 条记忆 -> \(chunkCount) 个分块。")
        return MemoryReembeddingSummary(processedMemories: processedMemories, chunkCount: chunkCount)
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
    
    private func embeddingsWithRetry(for chunkTexts: [String]) async throws -> [[Float]] {
        let preferredModelID = preferredEmbeddingModelIdentifier()
        var attempt = 0
        var currentDelay = embeddingRetryPolicy.initialDelay
        
        while attempt < embeddingRetryPolicy.maxAttempts {
            attempt += 1
            do {
                let embeddings = try await embeddingGenerator.generateEmbeddings(
                    for: chunkTexts,
                    preferredModelID: preferredModelID
                )
                try validateEmbeddings(embeddings, matches: chunkTexts)
                return embeddings
            } catch {
                logger.error("❌ 嵌入生成失败（第 \(attempt) 次）：\(error.localizedDescription)")
                if attempt >= embeddingRetryPolicy.maxAttempts {
                    logger.fault("❌ 超过最大嵌入重试次数，放弃本次记忆写入。")
                    throw error
                }
                
                if currentDelay > 0 {
                    let nanoseconds = UInt64(currentDelay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
                currentDelay *= embeddingRetryPolicy.backoffMultiplier
            }
        }
        
        throw MemoryEmbeddingError.invalidResponse
    }
    
    private func validateEmbeddings(_ embeddings: [[Float]], matches texts: [String]) throws {
        guard embeddings.count == texts.count else {
            throw MemoryEmbeddingError.resultCountMismatch(expected: texts.count, actual: embeddings.count)
        }
        
        guard embeddings.allSatisfy({ !$0.isEmpty }) else {
            throw MemoryEmbeddingError.invalidResponse
        }
    }

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
            let metadata = chunkMetadata(for: memory, chunkIndex: index, chunkId: chunkID)
            
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
    
    private func scheduleConsistencyCheck(after delay: TimeInterval = 0) {
        Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            _ = await self.reconcilePendingEmbeddings()
        }
    }
    
    @discardableResult
    internal func reconcilePendingEmbeddings() async -> Int {
        let memoryIDs = Set(cachedMemories.map { $0.id })
        guard !memoryIDs.isEmpty else { return 0 }
        
        removeOrphanedVectorEntries(validMemoryIDs: memoryIDs)
        let missingMemories = memoriesMissingEmbeddings(validMemoryIDs: memoryIDs)
        guard !missingMemories.isEmpty else { return 0 }
        
        logger.info("🔍 检测到 \(missingMemories.count) 条记忆缺少嵌入，尝试自动补偿。")
        for memory in missingMemories {
            await backfillEmbedding(for: memory)
        }
        return missingMemories.count
    }
    
    private func memoriesMissingEmbeddings(validMemoryIDs: Set<UUID>) -> [MemoryItem] {
        guard !similarityIndex.indexItems.isEmpty else {
            return cachedMemories.filter { validMemoryIDs.contains($0.id) }
        }
        
        let indexedParentIDs = Set(similarityIndex.indexItems.compactMap { item -> UUID? in
            if let parentId = item.metadata["parentMemoryId"], let uuid = UUID(uuidString: parentId) {
                return uuid
            }
            return UUID(uuidString: item.id)
        })
        
        return cachedMemories.filter { validMemoryIDs.contains($0.id) && !indexedParentIDs.contains($0.id) }
    }
    
    private func backfillEmbedding(for memory: MemoryItem) async {
        let chunkTexts = chunker.chunk(text: memory.content)
        guard !chunkTexts.isEmpty else {
            logger.error("⚠️ 记忆 \(memory.id.uuidString) 内容无法分块，跳过补偿。")
            return
        }
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("🔁 已补齐记忆嵌入：\(memory.id.uuidString)。")
        } catch {
            logger.error("❌ 补写记忆嵌入失败：\(error.localizedDescription)")
            scheduleConsistencyCheck(after: max(consistencyCheckDefaultDelay, embeddingRetryPolicy.initialDelay))
        }
    }
    
    private func removeOrphanedVectorEntries(validMemoryIDs: Set<UUID>) {
        guard !similarityIndex.indexItems.isEmpty else { return }
        let orphanChunkIDs = similarityIndex.indexItems.compactMap { item -> String? in
            guard let parentId = item.metadata["parentMemoryId"],
                  let uuid = UUID(uuidString: parentId) else {
                return nil
            }
            return validMemoryIDs.contains(uuid) ? nil : item.id
        }
        guard !orphanChunkIDs.isEmpty else { return }
        
        for chunkId in orphanChunkIDs {
            similarityIndex.removeItem(id: chunkId)
        }
        logger.info("🧹 已移除 \(orphanChunkIDs.count) 条孤立的向量分块。")
        saveIndex()
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
    
    private func purgePersistedVectorStores() {
        let directory = MemoryStoragePaths.vectorStoreDirectory()
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let sqliteFiles = files.filter {
                $0.pathExtension == "sqlite" &&
                $0.deletingPathExtension().lastPathComponent.contains(MemoryStoragePaths.vectorStoreName)
            }
            for file in sqliteFiles {
                try fileManager.removeItem(at: file)
                logger.info("🗑️ 已删除旧向量存储：\(file.lastPathComponent)")
            }
        } catch {
            logger.error("⚠️ 清理旧向量存储失败：\(error.localizedDescription)")
        }
    }
    
    private func chunkMetadata(for memory: MemoryItem, chunkIndex: Int, chunkId: String) -> [String: String] {
        [
            "createdAt": dateFormatter.string(from: memory.createdAt),
            "parentMemoryId": memory.id.uuidString,
            "chunkIndex": String(chunkIndex),
            "chunkId": chunkId
        ]
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
