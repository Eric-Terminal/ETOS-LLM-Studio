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
    
    /// 嵌入错误发布者，用于通知UI层显示错误弹窗（如400硬错误）。
    public var embeddingErrorPublisher: AnyPublisher<MemoryEmbeddingError, Never> {
        internalEmbeddingErrorPublisher.eraseToAnyPublisher()
    }
    
    /// 维度不匹配警告发布者，用于提示用户需要重新生成嵌入。
    public var dimensionMismatchPublisher: AnyPublisher<(query: Int, index: Int), Never> {
        internalDimensionMismatchPublisher.eraseToAnyPublisher()
    }
    
    /// 嵌入进度发布者，用于 UI 展示全量重嵌入与自动补偿进度。
    public var embeddingProgressPublisher: AnyPublisher<MemoryEmbeddingProgress, Never> {
        internalEmbeddingProgressPublisher.eraseToAnyPublisher()
    }

    // MARK: - 私有属性

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryManager")
    var similarityIndex: SimilarityIndex!
    let rawStore: MemoryRawStore
    let internalMemoriesPublisher = CurrentValueSubject<[MemoryItem], Never>([])
    let internalEmbeddingErrorPublisher = PassthroughSubject<MemoryEmbeddingError, Never>()
    let internalDimensionMismatchPublisher = PassthroughSubject<(query: Int, index: Int), Never>()
    let internalEmbeddingProgressPublisher = PassthroughSubject<MemoryEmbeddingProgress, Never>()
    let persistenceQueue = DispatchQueue(label: "com.etos.memory.persistence.queue")
    var initializationTask: Task<Void, Never>!
    var cachedMemories: [MemoryItem] = []
    let dateFormatter = ISO8601DateFormatter()
    let chunker: MemoryChunker
    let embeddingGenerator: MemoryEmbeddingGenerating
    let embeddingRetryPolicy: MemoryEmbeddingRetryPolicy
    let consistencyCheckDefaultDelay: TimeInterval = 2.0
    let storageRootDirectory: URL?
    let maxAutoReconcileAttemptsPerMemory: Int = 3
    let autoRetryStateQueue = DispatchQueue(label: "com.etos.memory.auto-retry.state.queue")
    var autoReconcileFailureCounts: [UUID: Int] = [:]
    var autoReconcileSuspendedByHardError: Bool = false
    var autoReconcileModelIdentifierSnapshot: String = ""
    var consistencyCheckScheduled: Bool = false

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func defaultStorageRootDirectory(forTests: Bool) -> URL? {
        guard forTests else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - 初始化

    /// 公开的初始化方法，用于生产环境。
    public init(
        embeddingGenerator: MemoryEmbeddingGenerating? = nil,
        chunkSize: Int = 200,
        retryPolicy: MemoryEmbeddingRetryPolicy = .default,
        storageRootDirectory: URL? = nil
    ) {
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        self.embeddingRetryPolicy = retryPolicy
        self.storageRootDirectory = storageRootDirectory ?? Self.defaultStorageRootDirectory(forTests: Self.isRunningUnitTests)
        self.rawStore = MemoryRawStore(rootDirectory: self.storageRootDirectory)
        logger.info("MemoryManager 正在初始化...")
        self.initializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.setup()
        }
    }
    
    /// 内部的初始化方法，用于测试环境，允许注入一个自定义的 SimilarityIndex。
    internal init(
        testIndex: SimilarityIndex,
        embeddingGenerator: MemoryEmbeddingGenerating? = nil,
        chunkSize: Int = 200,
        retryPolicy: MemoryEmbeddingRetryPolicy = .default,
        storageRootDirectory: URL? = nil
    ) {
        logger.info("MemoryManager 正在使用测试索引进行初始化...")
        self.embeddingGenerator = embeddingGenerator ?? CloudEmbeddingService()
        self.chunker = MemoryChunker(chunkSize: chunkSize)
        self.embeddingRetryPolicy = retryPolicy
        self.storageRootDirectory = storageRootDirectory ?? Self.defaultStorageRootDirectory(forTests: Self.isRunningUnitTests)
        self.rawStore = MemoryRawStore(rootDirectory: self.storageRootDirectory)
        self.similarityIndex = testIndex
        self.initializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let loadedItems = (try self.similarityIndex.loadIndex()) ?? self.similarityIndex.indexItems
                let memories = loadedItems
                    .map { MemoryItem(from: $0) }
                    .sorted(by: { $0.createdAt > $1.createdAt })
                self.cachedMemories = memories
                self.internalMemoriesPublisher.send(memories)
                logger.info("  - 测试初始化完成。从磁盘加载了 \(memories.count) 条记忆。")
            } catch {
                logger.error("  - (测试) 加载记忆索引失败: \(error.localizedDescription)")
                self.internalMemoriesPublisher.send([])
            }
        }
    }
    
    // MARK: - 公开方法 (测试辅助)
    
    /// 等待异步初始化过程完成。仅用于测试。
    public func waitForInitialization() async {
        await initializationTask.value
    }

    /// 返回当前内存中的记忆快照，按显示时间倒序排列。
    public func currentMemoriesSnapshot() -> [MemoryItem] {
        cachedMemories.sorted(by: { $0.displayDate > $1.displayDate })
    }
    
    private func setup() async {
        MemoryStoragePaths.ensureRootDirectory(rootDirectory: storageRootDirectory)
        let nativeEmbeddings = NativeEmbeddings(language: NLLanguage.simplifiedChinese)
        let vectorStore = SQLiteVectorStore()
        self.similarityIndex = await SimilarityIndex(
            name: MemoryStoragePaths.vectorStoreName,
            model: nativeEmbeddings,
            vectorStore: vectorStore
        )
        
        do {
            let vectorDirectory = MemoryStoragePaths.vectorStoreDirectory(rootDirectory: storageRootDirectory)
            _ = try self.similarityIndex.loadIndex(
                fromDirectory: vectorDirectory,
                name: MemoryStoragePaths.vectorStoreName
            )
            logger.info("  - 向量索引初始化完成，当前条目: \(self.similarityIndex.indexItems.count)。")
        } catch {
            logger.error("  - 加载记忆索引失败: \(error.localizedDescription)")
        }
        
        var rawMemories = rawStore.loadMemories()
            .sorted(by: { $0.createdAt > $1.createdAt })

        if rawMemories.isEmpty, !self.similarityIndex.indexItems.isEmpty {
            rawMemories = self.similarityIndex.indexItems
                .map { MemoryItem(from: $0) }
                .sorted(by: { $0.createdAt > $1.createdAt })
            do {
                try rawStore.saveMemories(rawMemories)
                logger.info("  - 从旧索引迁移 \(rawMemories.count) 条记忆到原文存储。")
            } catch {
                logger.error("  - 从旧索引补录原文记忆失败: \(error.localizedDescription)")
            }
        }

        cachedMemories = rawMemories
        internalMemoriesPublisher.send(rawMemories)
        logger.info("  - 原文记忆初始化完成，当前条目: \(rawMemories.count)。")
        
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
        
        // 如果没有选择嵌入模型，只保存原文，跳过嵌入生成
        guard hasConfiguredEmbeddingModel() else {
            logger.warning("尚未选择嵌入模型，记忆已保存但无法生成嵌入向量。")
            return
        }
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("已添加新的记忆。")
        } catch {
            logger.error("添加记忆失败：\(error.localizedDescription)")
            notifyEmbeddingErrorIfNeeded(error)
            if shouldScheduleAutoRetry(for: memory.id, error: error) {
                scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
            }
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
        
        // 如果没有选择嵌入模型，只保存原文，跳过嵌入生成
        guard hasConfiguredEmbeddingModel() else {
            logger.warning("尚未选择嵌入模型，记忆已保存但无法生成嵌入向量。")
            return true
        }
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("已恢复外部记忆。")
            return true
        } catch {
            logger.error("恢复外部记忆失败：\(error.localizedDescription)")
            notifyEmbeddingErrorIfNeeded(error)
            if shouldScheduleAutoRetry(for: memory.id, error: error) {
                scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
            }
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
        
        // 更新时设置 updatedAt 为当前时间
        let updatedMemory = MemoryItem(id: item.id, content: trimmed, embedding: [], createdAt: item.createdAt, updatedAt: Date(), isArchived: item.isArchived)
        cacheMemory(updatedMemory)
        
        // 如果没有选择嵌入模型，只更新原文，跳过嵌入生成
        guard hasConfiguredEmbeddingModel() else {
            logger.warning("尚未选择嵌入模型，记忆已更新但无法生成嵌入向量。")
            return
        }
        
        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            removeVectorEntries(for: [item.id])
            await ingest(memory: updatedMemory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("已更新记忆项。")
        } catch {
            logger.error("更新记忆失败：\(error.localizedDescription)")
            notifyEmbeddingErrorIfNeeded(error)
            if shouldScheduleAutoRetry(for: updatedMemory.id, error: error) {
                scheduleConsistencyCheck(after: consistencyCheckDefaultDelay)
            }
        }
    }

    /// 删除一条或多条记忆。
    public func deleteMemories(_ items: [MemoryItem]) async {
        await initializationTask.value
        let idsToDelete = Set(items.map { $0.id })
        cachedMemories.removeAll { idsToDelete.contains($0.id) }
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
        resetAutoRetryState(for: idsToDelete)
        
        removeVectorEntries(for: idsToDelete)
        saveIndex()
        logger.info("已删除 \(items.count) 条记忆。")
    }
    
    /// 归档记忆（被遗忘），不再参与检索，但保留原文和向量。
    public func archiveMemory(_ item: MemoryItem) async {
        await initializationTask.value
        guard let index = cachedMemories.firstIndex(where: { $0.id == item.id }) else { return }
        cachedMemories[index].isArchived = true
        cachedMemories.sort(by: { $0.createdAt > $1.createdAt })
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
        logger.info("记忆已归档：\(item.id.uuidString)")
    }
    
    /// 恢复归档的记忆，使其重新参与检索。
    public func unarchiveMemory(_ item: MemoryItem) async {
        await initializationTask.value
        guard let index = cachedMemories.firstIndex(where: { $0.id == item.id }) else { return }
        cachedMemories[index].isArchived = false
        cachedMemories.sort(by: { $0.createdAt > $1.createdAt })
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
        logger.info("记忆已恢复：\(item.id.uuidString)")
    }
    
    /// 获取所有记忆（包括归档的），用于 UI 显示。
    public func getAllMemories() async -> [MemoryItem] {
        await initializationTask.value
        return cachedMemories
    }
    
    /// 获取激活的记忆（不包括归档的），用于发送给模型。
    public func getActiveMemories() async -> [MemoryItem] {
        await initializationTask.value
        return cachedMemories.filter { !$0.isArchived }
    }

    /// 重新构建所有记忆的嵌入，并清空旧的向量存储。
    @discardableResult
    public func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        await initializationTask.value
        guard hasConfiguredEmbeddingModel() else {
            logger.warning("尚未选择嵌入模型，无法重新生成嵌入。")
            throw MemoryEmbeddingError.noAvailableModel
        }
        logger.info("正在重新生成全部记忆嵌入...")
        resetAllAutoRetryState()
        let memories = cachedMemories
        let totalMemories = memories.count
        let jobID = UUID()
        publishEmbeddingProgress(
            jobID: jobID,
            kind: .reembedAll,
            phase: .running,
            processedMemories: 0,
            totalMemories: totalMemories,
            failedMemories: 0,
            currentMemoryPreview: nil,
            errorMessage: nil
        )
        
        similarityIndex.removeAll()
        purgePersistedVectorStores()
        
        guard !memories.isEmpty else {
            saveIndex()
            publishEmbeddingProgress(
                jobID: jobID,
                kind: .reembedAll,
                phase: .completed,
                processedMemories: 0,
                totalMemories: 0,
                failedMemories: 0,
                currentMemoryPreview: nil,
                errorMessage: nil
            )
            logger.info(" 记忆列表为空，已写入空索引。")
            return MemoryReembeddingSummary(processedMemories: 0, chunkCount: 0)
        }
        
        var processedMemories = 0
        var progressProcessed = 0
        var chunkCount = 0
        
        for memory in memories {
            let memoryPreview = embeddingProgressPreview(for: memory)
            let chunkTexts = chunker.chunk(text: memory.content)
            guard !chunkTexts.isEmpty else {
                logger.error("记忆 \(memory.id.uuidString) 无有效分块，跳过。")
                progressProcessed += 1
                publishEmbeddingProgress(
                    jobID: jobID,
                    kind: .reembedAll,
                    phase: .running,
                    processedMemories: progressProcessed,
                    totalMemories: totalMemories,
                    failedMemories: 0,
                    currentMemoryPreview: memoryPreview,
                    errorMessage: nil
                )
                continue
            }
            
            let embeddings: [[Float]]
            do {
                embeddings = try await embeddingsWithRetry(for: chunkTexts)
            } catch {
                publishEmbeddingProgress(
                    jobID: jobID,
                    kind: .reembedAll,
                    phase: .failed,
                    processedMemories: progressProcessed,
                    totalMemories: totalMemories,
                    failedMemories: 1,
                    currentMemoryPreview: memoryPreview,
                    errorMessage: error.localizedDescription
                )
                throw error
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
                chunkCount += 1
            }
            
            processedMemories += 1
            progressProcessed += 1
            publishEmbeddingProgress(
                jobID: jobID,
                kind: .reembedAll,
                phase: .running,
                processedMemories: progressProcessed,
                totalMemories: totalMemories,
                failedMemories: 0,
                currentMemoryPreview: memoryPreview,
                errorMessage: nil
            )
        }
        
        saveIndex()
        publishEmbeddingProgress(
            jobID: jobID,
            kind: .reembedAll,
            phase: .completed,
            processedMemories: totalMemories,
            totalMemories: totalMemories,
            failedMemories: 0,
            currentMemoryPreview: nil,
            errorMessage: nil
        )
        logger.info("记忆重嵌入完成：\(processedMemories) 条记忆 -> \(chunkCount) 个分块。")
        return MemoryReembeddingSummary(processedMemories: processedMemories, chunkCount: chunkCount)
    }

    // MARK: - 公开方法 (搜索)

    /// 根据查询文本搜索最相关的记忆。
    public func searchMemories(query: String, topK: Int) async -> [MemoryItem] {
        await initializationTask.value
        guard topK > 0 else { return [] }
        
        guard hasConfiguredEmbeddingModel() else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        do {
            let embeddings = try await embeddingGenerator.generateEmbeddings(
                for: [trimmed],
                preferredModelID: preferredEmbeddingModelIdentifier()
            )
            guard let queryEmbedding = embeddings.first else { return [] }
            let totalChunks = similarityIndex.indexItems.count
            guard totalChunks > 0 else { return [] }
            
            // 检测维度不匹配
            let indexDimension = similarityIndex.dimension
            if indexDimension > 0 && indexDimension != queryEmbedding.count {
                logger.fault("嵌入维度不匹配！查询维度: \(queryEmbedding.count), 索引维度: \(indexDimension)。需要重新生成全部嵌入。")
                internalDimensionMismatchPublisher.send((query: queryEmbedding.count, index: indexDimension))
                return []
            }
            
            var requestedCount = min(max(topK * 3, topK), totalChunks)
            var resolvedMemories: [MemoryItem] = []
            var previousRequested = 0
            
            while requestedCount > previousRequested {
                let results = similarityIndex.search(usingQueryEmbedding: queryEmbedding, top: requestedCount)
                resolvedMemories = resolveUniqueMemories(from: results, limit: topK)
                if resolvedMemories.count >= topK || requestedCount >= totalChunks {
                    break
                }
                previousRequested = requestedCount
                requestedCount = min(requestedCount + topK, totalChunks)
            }
            
            return resolvedMemories
        } catch {
            logger.error("记忆检索失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 根据关键词检索相关记忆（不依赖向量）。
    public func searchMemoriesByKeyword(query: String, topK: Int) async -> [MemoryItem] {
        await initializationTask.value
        guard topK > 0 else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = keywordTokens(from: trimmed)
        guard !tokens.isEmpty else { return [] }

        let normalizedQuery = normalizedKeywordSearchText(trimmed)
        let activeMemories = cachedMemories.filter { !$0.isArchived }
        guard !activeMemories.isEmpty else { return [] }

        let scoredMemories: [(memory: MemoryItem, score: Int)] = activeMemories.compactMap { memory in
            let normalizedContent = normalizedKeywordSearchText(memory.content)
            guard !normalizedContent.isEmpty else { return nil }

            var score = 0
            if !normalizedQuery.isEmpty, normalizedContent.contains(normalizedQuery) {
                score += max(5, normalizedQuery.count) * 3
            }

            for token in tokens {
                let hits = occurrenceCount(of: token, in: normalizedContent)
                guard hits > 0 else { continue }
                score += hits * max(1, token.count)
            }

            guard score > 0 else { return nil }
            return (memory: memory, score: score)
        }

        let sorted = scoredMemories.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.memory.createdAt > rhs.memory.createdAt
            }
            return lhs.score > rhs.score
        }

        return Array(sorted.prefix(topK).map(\.memory))
    }
}
