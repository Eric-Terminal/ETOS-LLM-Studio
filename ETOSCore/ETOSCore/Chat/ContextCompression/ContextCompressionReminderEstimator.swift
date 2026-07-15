// ============================================================================
// ContextCompressionReminderEstimator.swift
// ============================================================================
// ETOS LLM Studio
//
// 在后台估算完整会话分支规模，为手动上下文压缩提供非阻塞提醒。
// ============================================================================

import Foundation

public enum ContextCompressionReminderPolicy {
    public static let defaultTokenThreshold = 32_000
    public static let minimumTokenThreshold = 1_000
    public static let maximumTokenThreshold = 2_000_000

    public static func normalizedTokenThreshold(_ value: Int) -> Int {
        min(max(value, minimumTokenThreshold), maximumTokenThreshold)
    }

    public static func shouldRemind(
        estimatedTokens: Int,
        isEnabled: Bool,
        tokenThreshold: Int
    ) -> Bool {
        isEnabled
            && estimatedTokens >= normalizedTokenThreshold(tokenThreshold)
    }
}

public enum ContextCompressionReminderEstimator {
    private static let messageProtocolOverhead = 12
    private static let toolCallProtocolOverhead = 16
    private static let attachmentPlaceholderEstimate = 256
    private static let continuationProtocolOverhead = 32

    /// 估算完整当前分支和已有续聊交接的 Token 数，不受 `maxChatHistory` 限制。
    public static func estimate(
        messages: [ChatMessage],
        continuationContext: ConversationContinuationContext? = nil
    ) -> Int {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
            .filter { $0.role != .error }
        var total = visibleMessages.reduce(0) { result, message in
            result + estimate(message: message)
        }

        if let continuationContext {
            total += continuationProtocolOverhead
            total += estimate(text: continuationContext.sourceSessionNameSnapshot)
            total += estimate(text: continuationContext.summary)
            total += continuationContext.retainedMessages.reduce(0) { result, message in
                result + estimate(message: message)
            }
        }
        return total
    }

    /// ASCII 文本按约四字符一个 Token，非 ASCII 文本按约三个 UTF-8 字节一个 Token。
    public static func estimate(text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var asciiByteCount = 0
        var nonASCIIByteCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                asciiByteCount += 1
            } else {
                nonASCIIByteCount += scalar.utf8.count
            }
        }
        return (asciiByteCount + 3) / 4 + (nonASCIIByteCount + 2) / 3
    }

    private static func estimate(message: ChatMessage) -> Int {
        var total = messageProtocolOverhead + estimate(text: message.content)
        for toolCall in message.toolCalls ?? [] {
            total += toolCallProtocolOverhead
            total += estimate(text: toolCall.toolName)
            total += estimate(text: toolCall.arguments)
            if let result = toolCall.result {
                total += estimate(text: result)
            }
        }

        let attachmentCount = (message.audioFileName == nil ? 0 : 1)
            + (message.imageFileNames?.count ?? 0)
            + (message.fileFileNames?.count ?? 0)
        total += attachmentCount * attachmentPlaceholderEstimate
        return total
    }
}
