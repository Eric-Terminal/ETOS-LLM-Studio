// ============================================================================
// MemoryManagerTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 记忆管理器的公共类型定义。
// ============================================================================

import Foundation

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

    public init(processedMemories: Int, chunkCount: Int) {
        self.processedMemories = processedMemories
        self.chunkCount = chunkCount
    }
}

public struct MemoryReembeddingItemResult: Identifiable, Equatable {
    public let memoryID: UUID
    public let chunkCount: Int
    public let errorMessage: String?

    public var id: UUID { memoryID }
    public var succeeded: Bool { errorMessage == nil }

    public init(memoryID: UUID, chunkCount: Int, errorMessage: String?) {
        self.memoryID = memoryID
        self.chunkCount = chunkCount
        self.errorMessage = errorMessage
    }
}

public typealias MemoryReembeddingItemProgressHandler = (MemoryReembeddingItemResult) async -> Void

public enum MemoryReembeddingError: LocalizedError {
    case failedMemories(count: Int, firstMessage: String)

    public var errorDescription: String? {
        switch self {
        case .failedMemories(let count, let firstMessage):
            return String(
                format: NSLocalizedString("%d 条记忆重嵌入失败：%@", comment: "Memory reembedding failed memories error"),
                count,
                firstMessage
            )
        }
    }
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
