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
