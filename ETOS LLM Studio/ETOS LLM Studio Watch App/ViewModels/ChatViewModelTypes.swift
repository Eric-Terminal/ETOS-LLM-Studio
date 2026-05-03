// ============================================================================
// ChatViewModelTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接 ChatViewModel 使用的轻量状态类型，避免主视图模型继续堆积
// 与消息流程无关的辅助结构。
// ============================================================================

import Foundation

extension ChatViewModel {
    enum ImageGenerationFeedbackPhase {
        case idle
        case running
        case success
        case failure
        case cancelled
    }

    struct ImageGenerationFeedback {
        var phase: ImageGenerationFeedbackPhase
        var prompt: String
        var startedAt: Date?
        var finishedAt: Date?
        var imageCount: Int
        var errorMessage: String?
        var referenceCount: Int

        static let idle = ImageGenerationFeedback(
            phase: .idle,
            prompt: "",
            startedAt: nil,
            finishedAt: nil,
            imageCount: 0,
            errorMessage: nil,
            referenceCount: 0
        )
    }

    struct AssistantReplyMarker: Equatable {
        let id: UUID
        let versionIndex: Int
        let normalizedContent: String
        let imageCount: Int
        let hasAudio: Bool
        let fileCount: Int
    }

    struct PendingBackgroundReplyNotificationContext {
        let baselineMarker: AssistantReplyMarker?
        let sessionName: String?
    }
}
