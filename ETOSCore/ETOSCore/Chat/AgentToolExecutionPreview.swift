// ============================================================================
// AgentToolExecutionPreview.swift
// ============================================================================
// ETOS LLM Studio
//
// 在消息同步阶段归纳当前会话最值得展示的一次工具执行，避免 SwiftUI 渲染时
// 扫描完整历史或处理可能很大的工具输出。
// ============================================================================

import Foundation

public struct AgentToolExecutionPreviewSnapshot: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case completed
    }

    public let messageID: UUID
    public let toolCallID: String
    public let toolName: String
    public let arguments: String
    public let result: String?
    public let argumentsWereTruncated: Bool
    public let resultWasTruncated: Bool
    public let previewText: String
    public let state: State

    public var id: String { "\(messageID.uuidString)#\(toolCallID)" }

    init(messageID: UUID, toolCall: InternalToolCall) {
        let hasResult = toolCall.result?.isEmpty == false
        self.messageID = messageID
        toolCallID = toolCall.id
        toolName = toolCall.toolName
        let boundedArguments = Self.boundedPrefix(toolCall.arguments, limit: 6_000)
        let boundedResult = Self.boundedTail(toolCall.result ?? "", limit: 6_000)
        arguments = boundedArguments.text
        result = hasResult ? boundedResult.text : nil
        argumentsWereTruncated = boundedArguments.wasTruncated
        resultWasTruncated = hasResult && boundedResult.wasTruncated
        state = hasResult ? .completed : .running
        previewText = hasResult
            ? Self.boundedTail(boundedResult.text, limit: 720).text
            : Self.boundedPrefix(boundedArguments.text, limit: 720).text
    }

    private static func boundedPrefix(_ text: String, limit: Int) -> (text: String, wasTruncated: Bool) {
        let boundary = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return (
            String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines),
            boundary != text.endIndex
        )
    }

    private static func boundedTail(_ text: String, limit: Int) -> (text: String, wasTruncated: Bool) {
        let boundary = text.index(text.endIndex, offsetBy: -limit, limitedBy: text.startIndex) ?? text.startIndex
        return (
            String(text[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines),
            boundary != text.startIndex
        )
    }
}

public struct AgentToolExecutionPreviewAccumulator: Sendable {
    private var latest: AgentToolExecutionPreviewSnapshot?
    private var latestRunning: AgentToolExecutionPreviewSnapshot?

    public init() {}

    public mutating func append(_ message: ChatMessage) {
        guard let toolCalls = message.toolCalls else { return }
        for toolCall in toolCalls {
            let snapshot = AgentToolExecutionPreviewSnapshot(messageID: message.id, toolCall: toolCall)
            latest = snapshot
            if snapshot.state == .running {
                latestRunning = snapshot
            }
        }
    }

    /// 正在执行的工具优先；没有运行项时保留最近完成的工具，便于用户回看结果。
    public var preferred: AgentToolExecutionPreviewSnapshot? {
        latestRunning ?? latest
    }
}
