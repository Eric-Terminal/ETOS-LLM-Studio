// ============================================================================
// ConversationContinuationRetainedContentPlanner.swift
// ============================================================================
// ETOS LLM Studio
//
// 将续聊保留原文整理为普通消息和可独立折叠的工具调用。
// ============================================================================

import Foundation

public struct ConversationContinuationRetainedMessage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String

    public init(id: UUID, role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public struct ConversationContinuationRetainedTool: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceMessageID: UUID
    public let toolCallID: String?
    public let toolName: String?
    public let arguments: String
    public let result: String

    public init(
        id: String,
        sourceMessageID: UUID,
        toolCallID: String?,
        toolName: String?,
        arguments: String,
        result: String
    ) {
        self.id = id
        self.sourceMessageID = sourceMessageID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
    }
}

public enum ConversationContinuationRetainedItem: Identifiable, Hashable, Sendable {
    case message(ConversationContinuationRetainedMessage)
    case tool(ConversationContinuationRetainedTool)

    public var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .tool(let tool):
            return tool.id
        }
    }
}

public enum ConversationContinuationRetainedContentPlanner {
    public static func makeItems(
        from messages: [ChatMessage]
    ) -> [ConversationContinuationRetainedItem] {
        let assistantToolCallIDs = Set(
            messages.lazy
                .filter { $0.role != .tool }
                .flatMap { ($0.toolCalls ?? []).map(\.id) }
        )
        let toolResultsByCallID = resolvedToolResultsByCallID(in: messages)
        var emittedAssistantToolCallIDs = Set<String>()
        var items: [ConversationContinuationRetainedItem] = []

        for message in messages {
            if message.role == .tool {
                appendOrphanToolItems(
                    from: message,
                    assistantToolCallIDs: assistantToolCallIDs,
                    to: &items
                )
                continue
            }

            let toolItems = (message.toolCalls ?? []).enumerated().compactMap { index, call in
                guard emittedAssistantToolCallIDs.insert(call.id).inserted else { return nil }
                let directResult = normalized(call.result)
                let result = directResult.isEmpty
                    ? toolResultsByCallID[call.id] ?? ""
                    : directResult
                return makeToolItem(
                    sourceMessageID: message.id,
                    call: call,
                    result: result,
                    ordinal: index
                )
            }
            let messageItem = makeMessageItem(message)

            if message.toolCallsPlacement == .afterReasoning {
                items.append(contentsOf: toolItems)
                if let messageItem { items.append(messageItem) }
            } else {
                if let messageItem { items.append(messageItem) }
                items.append(contentsOf: toolItems)
            }
        }
        return items
    }

    private static func resolvedToolResultsByCallID(
        in messages: [ChatMessage]
    ) -> [String: String] {
        var results: [String: String] = [:]
        for message in messages where message.role == .tool {
            for call in message.toolCalls ?? [] {
                let callResult = normalized(call.result)
                let result = callResult.isEmpty ? normalized(message.content) : callResult
                if !result.isEmpty {
                    results[call.id] = result
                }
            }
        }
        return results
    }

    private static func appendOrphanToolItems(
        from message: ChatMessage,
        assistantToolCallIDs: Set<String>,
        to items: inout [ConversationContinuationRetainedItem]
    ) {
        let calls = message.toolCalls ?? []
        if calls.isEmpty {
            let result = normalized(message.content)
            guard !result.isEmpty else { return }
            let tool = ConversationContinuationRetainedTool(
                id: "tool:\(message.id.uuidString):standalone",
                sourceMessageID: message.id,
                toolCallID: nil,
                toolName: nil,
                arguments: "",
                result: result
            )
            items.append(.tool(tool))
            return
        }

        for (index, call) in calls.enumerated() where !assistantToolCallIDs.contains(call.id) {
            let callResult = normalized(call.result)
            let result = callResult.isEmpty ? normalized(message.content) : callResult
            items.append(makeToolItem(
                sourceMessageID: message.id,
                call: call,
                result: result,
                ordinal: index
            ))
        }
    }

    private static func makeMessageItem(
        _ message: ChatMessage
    ) -> ConversationContinuationRetainedItem? {
        guard !message.content.isEmpty else { return nil }
        return .message(ConversationContinuationRetainedMessage(
            id: message.id,
            role: message.role,
            content: message.content
        ))
    }

    private static func makeToolItem(
        sourceMessageID: UUID,
        call: InternalToolCall,
        result: String,
        ordinal: Int
    ) -> ConversationContinuationRetainedItem {
        .tool(ConversationContinuationRetainedTool(
            id: "tool:\(sourceMessageID.uuidString):\(call.id):\(ordinal)",
            sourceMessageID: sourceMessageID,
            toolCallID: call.id,
            toolName: call.toolName,
            arguments: call.arguments,
            result: result
        ))
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
