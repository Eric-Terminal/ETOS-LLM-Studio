// ============================================================================
// ContextCompressionPromptBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将压缩分块、阶段摘要与续聊上下文投影为模型可读消息。
// ============================================================================

import Foundation

struct ContextCompressionSummaryInput: Sendable {
    let coveredMessageIDs: [UUID]
    let summary: String
}

enum ContextCompressionPromptBuilder {
    private struct FragmentPayload: Encodable {
        let sourceMessageID: UUID
        let role: String
        let fragmentIndex: Int
        let fragmentCount: Int
        let content: String
    }

    private struct SummaryPayload: Encodable {
        let coveredMessageIDs: [UUID]
        let summary: String
    }

    static var systemPrompt: String {
        BuiltInPromptStore.render(.contextCompressionSystem)
    }

    static func chunkUserPrompt(
        _ chunk: ContextCompressionChunk,
        focusInstruction: String?
    ) throws -> String {
        let payload = chunk.fragments.map {
            FragmentPayload(
                sourceMessageID: $0.sourceMessageID,
                role: $0.role.rawValue,
                fragmentIndex: $0.fragmentIndex + 1,
                fragmentCount: $0.fragmentCount,
                content: $0.content
            )
        }
        return BuiltInPromptStore.render(
            .contextCompressionChunk,
            variables: [
                "conversation": try encode(payload),
                "focus": normalizedFocusInstruction(focusInstruction)
            ]
        )
    }

    static func synthesisUserPrompt(
        _ summaries: [ContextCompressionSummaryInput],
        focusInstruction: String?
    ) throws -> String {
        let payload = summaries.map {
            SummaryPayload(
                coveredMessageIDs: $0.coveredMessageIDs,
                summary: $0.summary
            )
        }
        return BuiltInPromptStore.render(
            .contextCompressionSynthesis,
            variables: [
                "partial_summaries": try encode(payload),
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
