// ============================================================================
// WatchChatViewModelContextCompression.swift
// ============================================================================
// ETOS LLM Studio
//
// 为 watchOS 聊天界面提供续聊上下文读取与压缩任务入口。
// ============================================================================

import Foundation
import ETOSCore

extension ChatViewModel {
    func loadConversationContinuationContext(
        for sessionID: UUID
    ) async throws -> ConversationContinuationContext? {
        try await Task.detached(priority: .userInitiated) {
            try Persistence.loadConversationContinuationContext(for: sessionID)
        }.value
    }

    func loadConversationContinuationContexts(
        from sessionID: UUID
    ) async throws -> [ConversationContinuationContext] {
        try await Task.detached(priority: .userInitiated) {
            try Persistence.loadConversationContinuationContexts(from: sessionID)
        }.value
    }

    func hideConversationContinuationLink(
        in context: ConversationContinuationContext,
        kind: ConversationContinuationLinkKind
    ) async throws -> ConversationContinuationContext {
        try await Task.detached(priority: .userInitiated) {
            let updatedContext = context.hidingLink(kind)
            try Persistence.saveConversationContinuationContext(updatedContext)
            return updatedContext
        }.value
    }

    @discardableResult
    func createCompressedContinuation(
        from sessionID: UUID,
        options: ContextCompressionOptions,
        progress: @escaping @MainActor @Sendable (ContextCompressionProgress) -> Void
    ) async throws -> ChatSession {
        try await chatService.createCompressedContinuation(
            from: sessionID,
            options: options,
            progress: progress
        )
    }
}
