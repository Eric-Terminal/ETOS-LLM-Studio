// ============================================================================
// ContextCompressionPromptBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将完整摘要输入与续聊上下文投影为模型可读消息。
// ============================================================================

import Foundation

enum ContextCompressionPromptBuilder {
    private struct MessagePayload: Encodable {
        let sourceMessageID: UUID
        let role: String
        let content: String
    }

    static var systemPrompt: String {
        BuiltInPromptStore.render(.contextCompressionSystem)
    }

    static func summaryUserPrompt(
        _ messages: [ContextCompressionSourceMessage],
        focusInstruction: String?
    ) throws -> String {
        let payload = messages.map {
            MessagePayload(
                sourceMessageID: $0.message.id,
                role: $0.message.role.rawValue,
                content: $0.semanticContent
            )
        }
        return BuiltInPromptStore.render(
            .contextCompressionSummary,
            variables: [
                "conversation": try encode(payload),
                "focus": normalizedFocusInstruction(focusInstruction)
            ]
        )
    }

    static func continuationRequestMessages(
        _ context: ConversationContinuationContext
    ) -> [ChatMessage] {
        let handoff = BuiltInPromptStore.render(
            .conversationContinuation,
            variables: [
                "source_name": context.sourceSessionNameSnapshot,
                "summary": context.summary
            ]
        )
        let handoffMessage = ChatMessage(
            id: context.id,
            role: .user,
            content: handoff,
            requestedAt: context.createdAt
        )
        return [handoffMessage] + context.retainedMessages.map(sanitizedRetainedMessage)
    }

    private static func sanitizedRetainedMessage(_ message: ChatMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            requestedAt: message.requestedAt,
            toolCalls: message.toolCalls,
            toolCallsPlacement: message.toolCallsPlacement,
            audioFileName: message.audioFileName,
            imageFileNames: message.imageFileNames,
            fileFileNames: message.fileFileNames
        )
    }

    private static func normalizedFocusInstruction(_ instruction: String?) -> String {
        let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return NSLocalizedString("无额外侧重点；请均衡保留所有会影响续聊的信息。", comment: "Default context compression focus")
        }
        return trimmed
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw ConversationContinuationPersistenceError.malformedStoredContext
        }
        return result
    }
}
