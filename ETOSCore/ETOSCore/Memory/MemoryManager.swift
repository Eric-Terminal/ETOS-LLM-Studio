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

private struct MemoryReembeddingWorkItem {
    let memory: MemoryItem
    let chunkTexts: [String]
}

private struct PreparedMemoryReembedding {
    let memory: MemoryItem
    let chunkTexts: [String]
    let result: Result<[[Float]], Error>
}

public class MemoryManager {

    // MARK: - 单例
    
    private static weak var currentInstance: MemoryManager?
    public static let shared = {
        let instance = MemoryManager()
        currentInstance = instance
        return instance
    }()

    public static func flushCurrentInstancePersistenceWritesForSnapshot() {
        if let currentInstance {
            currentInstance.flushPendingPersistenceWritesForSnapshot()
        } else {
            MemoryRawStore.flushPendingSQLiteWritesForSnapshot()
        }
    }

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
    let persistenceQueueSpecificKey = DispatchSpecificKey<UInt8>()
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
        self.persistenceQueue.setSpecific(key: persistenceQueueSpecificKey, value: 1)
        Self.currentInstance = self
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
        self.persistenceQueue.setSpecific(key: persistenceQueueSpecificKey, value: 1)
        self.similarityIndex = testIndex
        Self.currentInstance = self
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
    
    // MARK: - 公开方法
    
    /// 等待异步初始化过程完成。仅用于测试。
    public func waitForInitialization() async {
        await initializationTask.value
    }

    /// 阻塞等待记忆原文与向量索引的持久化队列清空，确保随后读取拿到最新快照。
    public func flushPendingPersistenceWritesForSnapshot() {
        if DispatchQueue.getSpecific(key: persistenceQueueSpecificKey) == nil {
            persistenceQueue.sync {}
        }
        MemoryRawStore.flushPendingSQLiteWritesForSnapshot()
    }

    /// 快照恢复会替换底层数据库，恢复完成后需要重新加载原文记忆与向量索引。
    public func reloadFromPersistenceAfterSnapshotRestore() {
        initializationTask.cancel()
        resetAllAutoRetryState()
        initializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.setup()
        }
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
        await addMemory(MemoryWriteRequest(content: content))
    }

    /// 添加一条带结构化元数据的新记忆。
    public func addMemory(_ request: MemoryWriteRequest) async {
        await initializationTask.value
        let trimmed = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return }
        
        let memory = MemoryItem(
            id: UUID(),
            content: trimmed,
            embedding: [],
            createdAt: Date(),
            kind: request.kind,
            source: request.source,
            importance: request.importance,
            confidence: request.confidence,
            entities: request.entities,
            validFrom: request.validFrom,
            validUntil: request.validUntil,
            sourceSessionID: request.sourceSessionID
        )
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
        await restoreMemory(
            MemoryItem(
                id: id,
                content: content,
                embedding: [],
                createdAt: createdAt,
                source: .imported
            )
        )
    }

    /// 从同步或备份中恢复完整记忆元数据。
    @discardableResult
    public func restoreMemory(_ restoredMemory: MemoryItem) async -> Bool {
        await initializationTask.value
        let trimmed = restoredMemory.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let chunkTexts = chunker.chunk(text: trimmed)
        guard !chunkTexts.isEmpty else { return false }
        
        var memory = restoredMemory
        memory.content = trimmed
        memory.embedding = []
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
        let existingMemory = cachedMemories.first(where: { $0.id == item.id })
        let contentChanged = existingMemory?.content != trimmed
        
        // 更新时设置 updatedAt 为当前时间
        let updatedMemory = MemoryItem(
            id: item.id,
            content: trimmed,
            embedding: existingMemory?.embedding ?? item.embedding,
            createdAt: item.createdAt,
            updatedAt: Date(),
            isArchived: item.isArchived,
            kind: item.kind,
            source: item.source,
            importance: item.importance,
            confidence: item.confidence,
            entities: item.entities,
            validFrom: item.validFrom,
            validUntil: item.validUntil,
            sourceSessionID: item.sourceSessionID,
            accessCount: item.accessCount,
            lastAccessedAt: item.lastAccessedAt
        )
        cacheMemory(updatedMemory)

        // 仅修改分类、重要度或有效期时，已有文本向量仍然有效。
        guard contentChanged else {
            logger.info("已更新记忆元数据。")
            return
        }
        
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
        let now = Date()
        return cachedMemories.filter { $0.isValid(at: now) }
    }

    /// 重新构建所有记忆的嵌入，并清空旧的向量存储。
    @discardableResult
    public func reembedAllMemories(concurrencyLimit: Int = 1) async throws -> MemoryReembeddingSummary {
        let results = try await reembedAllMemoriesDetailed(concurrencyLimit: concurrencyLimit)
        let failedResults = results.filter { !$0.succeeded }
        if let firstFailure = failedResults.first {
            throw MemoryReembeddingError.failedMemories(
                count: failedResults.count,
                firstMessage: firstFailure.errorMessage ?? NSLocalizedString("未知错误", comment: "")
            )
        }

        return MemoryReembeddingSummary(
            processedMemories: results.count,
            chunkCount: results.reduce(0) { $0 + $1.chunkCount }
        )
    }

    /// 重新构建所有记忆的嵌入，并逐条返回处理结果，供维护页面展示状态。
    @discardableResult
    public func reembedAllMemoriesDetailed(
        concurrencyLimit: Int = 1,
        itemProgressHandler: MemoryReembeddingItemProgressHandler? = nil
    ) async throws -> [MemoryReembeddingItemResult] {
        try await reembedMemories(
            memoryIDs: nil,
            concurrencyLimit: concurrencyLimit,
            shouldResetVectorStore: true,
            itemProgressHandler: itemProgressHandler
        )
    }

    /// 重新构建指定记忆的嵌入，用于失败条目的单独重试。
    @discardableResult
    public func reembedMemories(
        withIDs memoryIDs: Set<UUID>,
        concurrencyLimit: Int = 1,
        itemProgressHandler: MemoryReembeddingItemProgressHandler? = nil
    ) async throws -> [MemoryReembeddingItemResult] {
        guard !memoryIDs.isEmpty else { return [] }
        return try await reembedMemories(
            memoryIDs: memoryIDs,
            concurrencyLimit: concurrencyLimit,
            shouldResetVectorStore: false,
            itemProgressHandler: itemProgressHandler
        )
    }

    private func reembedMemories(
        memoryIDs: Set<UUID>?,
        concurrencyLimit: Int,
        shouldResetVectorStore: Bool,
        itemProgressHandler: MemoryReembeddingItemProgressHandler?
    ) async throws -> [MemoryReembeddingItemResult] {
        await initializationTask.value
        guard hasConfiguredEmbeddingModel() else {
            logger.warning("尚未选择嵌入模型，无法重新生成嵌入。")
            throw MemoryEmbeddingError.noAvailableModel
        }
        logger.info("正在重新生成记忆嵌入...")
        let memories = cachedMemories.filter { memory in
            guard let memoryIDs else { return true }
            return memoryIDs.contains(memory.id)
        }
        if shouldResetVectorStore {
            resetAllAutoRetryState()
        } else {
            resetAutoRetryState(for: Set(memories.map(\.id)))
        }
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

        if shouldResetVectorStore {
            similarityIndex.removeAll()
            purgePersistedVectorStores()
        } else {
            removeVectorEntries(for: Set(memories.map(\.id)))
        }

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
            return []
        }

        let workItems = memories.map { memory in
            MemoryReembeddingWorkItem(
                memory: memory,
                chunkTexts: chunker.chunk(text: memory.content)
            )
        }
        let maxActiveCount = min(max(1, concurrencyLimit), workItems.count)
        var results: [MemoryReembeddingItemResult] = []
        var processedMemories = 0
        var failedMemories = 0
        var chunkCount = 0

        await withTaskGroup(of: PreparedMemoryReembedding.self) { group in
            var nextWorkItemIndex = 0
            var activeTaskCount = 0

            while activeTaskCount < maxActiveCount,
                  nextWorkItemIndex < workItems.count,
                  !Task.isCancelled {
                let workItem = workItems[nextWorkItemIndex]
                nextWorkItemIndex += 1
                group.addTask { [self] in
                    await prepareReembedding(for: workItem)
                }
                activeTaskCount += 1
            }

            while activeTaskCount > 0 {
                guard let prepared = await group.next() else { break }
                activeTaskCount -= 1
                processedMemories += 1

                let memory = prepared.memory
                let memoryPreview = embeddingProgressPreview(for: memory)
                let itemResult: MemoryReembeddingItemResult
                var currentErrorMessage: String?

                switch prepared.result {
                case .success(let embeddings):
                    var memoryChunkCount = 0
                    for (index, chunkText) in prepared.chunkTexts.enumerated() {
                        let chunkID = UUID().uuidString
                        let metadata = chunkMetadata(for: memory, chunkIndex: index, chunkId: chunkID)
                        await similarityIndex.addItem(
                            id: chunkID,
                            text: chunkText,
                            metadata: metadata,
                            embedding: embeddings[index]
                        )
                        memoryChunkCount += 1
                    }
                    chunkCount += memoryChunkCount
                    resetAutoRetryState(for: memory.id)
                    itemResult = MemoryReembeddingItemResult(
                        memoryID: memory.id,
                        chunkCount: memoryChunkCount,
                        errorMessage: nil
                    )

                case .failure(let error):
                    failedMemories += 1
                    notifyEmbeddingErrorIfNeeded(error)
                    let message = error.localizedDescription
                    currentErrorMessage = message
                    logger.error("记忆重嵌入失败：\(message)")
                    itemResult = MemoryReembeddingItemResult(
                        memoryID: memory.id,
                        chunkCount: 0,
                        errorMessage: message
                    )
                }

                results.append(itemResult)
                publishEmbeddingProgress(
                    jobID: jobID,
                    kind: .reembedAll,
                    phase: .running,
                    processedMemories: processedMemories,
                    totalMemories: totalMemories,
                    failedMemories: failedMemories,
                    currentMemoryPreview: memoryPreview,
                    errorMessage: currentErrorMessage
                )
                await itemProgressHandler?(itemResult)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                if nextWorkItemIndex < workItems.count {
                    let workItem = workItems[nextWorkItemIndex]
                    nextWorkItemIndex += 1
                    group.addTask { [self] in
                        await prepareReembedding(for: workItem)
                    }
                    activeTaskCount += 1
                }
            }
        }

        saveIndex()
        publishEmbeddingProgress(
            jobID: jobID,
            kind: .reembedAll,
            phase: failedMemories == 0 ? .completed : .failed,
            processedMemories: totalMemories,
            totalMemories: totalMemories,
            failedMemories: failedMemories,
            currentMemoryPreview: nil,
            errorMessage: failedMemories == 0 ? nil : NSLocalizedString("部分记忆重嵌入失败，可点击失败项单独重试。", comment: "Memory reembedding partial failure message")
        )
        logger.info("记忆重嵌入完成：\(processedMemories) 条记忆 -> \(chunkCount) 个分块，失败 \(failedMemories) 条。")
        return results
    }

    private func prepareReembedding(for workItem: MemoryReembeddingWorkItem) async -> PreparedMemoryReembedding {
        guard !workItem.chunkTexts.isEmpty else {
            return PreparedMemoryReembedding(
                memory: workItem.memory,
                chunkTexts: workItem.chunkTexts,
                result: .failure(MemoryEmbeddingError.emptyInput)
            )
        }

        do {
            let embeddings = try await embeddingsWithRetry(for: workItem.chunkTexts)
            return PreparedMemoryReembedding(
                memory: workItem.memory,
                chunkTexts: workItem.chunkTexts,
                result: .success(embeddings)
            )
        } catch {
            return PreparedMemoryReembedding(
                memory: workItem.memory,
                chunkTexts: workItem.chunkTexts,
                result: .failure(error)
            )
        }
    }

    // MARK: - 公开方法 (搜索)

    /// 使用向量、词法、实体与时间信息进行混合检索；向量不可用时自动退化为本地检索。
    public func searchMemoriesHybrid(query: String, topK: Int) async -> [MemoryItem] {
        await initializationTask.value
        guard topK > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var semanticScores: [UUID: Double] = [:]
        if hasConfiguredEmbeddingModel(), !similarityIndex.indexItems.isEmpty {
            do {
                let embeddings = try await embeddingGenerator.generateEmbeddings(
                    for: [trimmed],
                    preferredModelID: preferredEmbeddingModelIdentifier()
                )
                if let queryEmbedding = embeddings.first,
                   similarityIndex.dimension == 0 || similarityIndex.dimension == queryEmbedding.count {
                    let candidateCount = min(max(topK * 8, 32), similarityIndex.indexItems.count)
                    let results = similarityIndex.search(usingQueryEmbedding: queryEmbedding, top: candidateCount)
                    semanticScores = parentSemanticScores(from: results)
                } else if let queryEmbedding = embeddings.first {
                    internalDimensionMismatchPublisher.send((query: queryEmbedding.count, index: similarityIndex.dimension))
                }
            } catch {
                logger.warning("混合检索的向量通道不可用，继续使用本地词法通道：\(error.localizedDescription)")
            }
        }

        let matches = MemoryHybridRetriever.rank(
            query: trimmed,
            tokens: keywordTokens(from: trimmed),
            memories: cachedMemories,
            semanticScores: semanticScores,
            limit: topK
        )
        let memories = matches.map(\.memory)
        recordMemoryAccess(memories)
        return memories
    }

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
            
            recordMemoryAccess(resolvedMemories)
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

        let matches = MemoryHybridRetriever.rank(
            query: trimmed,
            tokens: tokens,
            memories: cachedMemories,
            semanticScores: [:],
            limit: topK
        )
        let memories = matches.map(\.memory)
        recordMemoryAccess(memories)
        return memories
    }
}
