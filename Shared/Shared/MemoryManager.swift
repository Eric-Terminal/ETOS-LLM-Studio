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

public enum MemoryEmbeddingJobKind: Equatable {
    case reembedAll
    case reconcilePending
}

public enum MemoryEmbeddingJobPhase: Equatable {
    case running
    case completed
    case failed
}

public struct MemoryEmbeddingProgress: Equatable {
    public let jobID: UUID
    public let kind: MemoryEmbeddingJobKind
    public let phase: MemoryEmbeddingJobPhase
    public let processedMemories: Int
    public let totalMemories: Int
    public let failedMemories: Int
    public let currentMemoryPreview: String?
    public let errorMessage: String?
    
    public init(
        jobID: UUID,
        kind: MemoryEmbeddingJobKind,
        phase: MemoryEmbeddingJobPhase,
        processedMemories: Int,
        totalMemories: Int,
        failedMemories: Int,
        currentMemoryPreview: String?,
        errorMessage: String?
    ) {
        self.jobID = jobID
        self.kind = kind
        self.phase = phase
        self.processedMemories = processedMemories
        self.totalMemories = totalMemories
        self.failedMemories = failedMemories
        self.currentMemoryPreview = currentMemoryPreview
        self.errorMessage = errorMessage
    }
}

public class MemoryManager {

    // MARK: - 单例
    
    public static let shared = MemoryManager()

    // MARK: - 公开属性
    
    /// 一个发布者，当记忆库发生变化时发出通知，并按创建日期降序排列。
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
    let preferredEmbeddingModelKey = "memoryEmbeddingModelIdentifier"
    let embeddingRetryPolicy: MemoryEmbeddingRetryPolicy
    let consistencyCheckDefaultDelay: TimeInterval = 2.0
    let storageRootDirectory: URL?
    let maxAutoReconcileAttemptsPerMemory: Int = 3
    let autoRetryStateQueue = DispatchQueue(label: "com.etos.memory.auto-retry.state.queue")
    var autoReconcileFailureCounts: [UUID: Int] = [:]
    var autoReconcileSuspendedByHardError: Bool = false
    var autoReconcileModelIdentifierSnapshot: String = ""
    var consistencyCheckScheduled: Bool = false

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
}

// MARK: - 模型转换

extension MemoryItem {
    init(from indexItem: IndexItem) {
        self.id = UUID(uuidString: indexItem.id) ?? UUID()
        self.content = indexItem.text
        self.embedding = indexItem.embedding
        
        if let dateString = indexItem.metadata["createdAt"], let date = ISO8601DateFormatter().date(from: dateString) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }
        
        // 从旧数据迁移时，默认为激活状态
        self.isArchived = false
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
        
        // 搜索结果默认为激活状态
        self.isArchived = false
    }
}
