// ============================================================================
// ContextCompressionPlanner.swift
// ============================================================================
// ETOS LLM Studio
//
// 将当前回复分支划分为一次性摘要输入与最近原文快照。
// ============================================================================

import Foundation

public struct ContextCompressionSourceMessage: Hashable, Sendable {
    public let message: ChatMessage
    public let semanticContent: String

    public init(
        message: ChatMessage,
        attachmentContents: [ContextCompressionAttachmentContent] = []
    ) throws {
        let expectedAttachments = Self.attachmentIdentifiers(in: message)
        let providedByIdentifier = Dictionary(
            attachmentContents.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let missing = expectedAttachments.filter { identifier in
            guard let attachment = providedByIdentifier[identifier] else { return true }
            return attachment.content.isEmpty
        }
        guard missing.isEmpty else {
            throw ContextCompressionError.unsupportedAttachments(
                messageID: message.id,
                identifiers: missing.sorted()
            )
        }

        self.message = message
        self.semanticContent = Self.makeSemanticContent(
            message: message,
            attachmentContents: attachmentContents
        )
    }

    private static func attachmentIdentifiers(in message: ChatMessage) -> [String] {
        var identifiers: [String] = []
        if let audioFileName = message.audioFileName, !audioFileName.isEmpty {
            identifiers.append(audioFileName)
        }
        identifiers.append(contentsOf: message.imageFileNames ?? [])
        identifiers.append(contentsOf: message.fileFileNames ?? [])
        return identifiers
    }

    private static func makeSemanticContent(
        message: ChatMessage,
        attachmentContents: [ContextCompressionAttachmentContent]
    ) -> String {
        var sections: [String] = []
        if !message.content.isEmpty {
            sections.append(message.content)
        }

        for toolCall in message.toolCalls ?? [] {
            var lines = [
                "<tool_call id=\"\(toolCall.id)\" name=\"\(toolCall.toolName)\">",
                "<arguments>",
                toolCall.arguments,
                "</arguments>"
            ]
            if let result = toolCall.result {
                lines.append(contentsOf: ["<result>", result, "</result>"])
            }
            lines.append("</tool_call>")
            sections.append(lines.joined(separator: "\n"))
        }

        for attachment in attachmentContents {
            sections.append([
                "<attachment kind=\"\(attachment.kind.rawValue)\" identifier=\"\(attachment.identifier)\">",
                attachment.content,
                "</attachment>"
            ].joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

public struct ContextCompressionPlan: Sendable {
    public let summaryMessages: [ContextCompressionSourceMessage]
    public let retainedMessages: [ChatMessage]
    public let retainedRoundCount: Int
    public let sourceThroughMessageID: UUID
    public let sourceMessageCount: Int
    public let summarizedMessageCount: Int
    public let estimatedSourceTokens: Int

    public init(
        summaryMessages: [ContextCompressionSourceMessage],
        retainedMessages: [ChatMessage],
        retainedRoundCount: Int,
        sourceThroughMessageID: UUID,
        sourceMessageCount: Int,
        summarizedMessageCount: Int,
        estimatedSourceTokens: Int
    ) {
        self.summaryMessages = summaryMessages
        self.retainedMessages = retainedMessages
        self.retainedRoundCount = retainedRoundCount
        self.sourceThroughMessageID = sourceThroughMessageID
        self.sourceMessageCount = sourceMessageCount
        self.summarizedMessageCount = summarizedMessageCount
        self.estimatedSourceTokens = estimatedSourceTokens
    }
}

public enum ContextCompressionPlanner {
    public static func prepareTextOnlySourceMessages(
        from messages: [ChatMessage]
    ) throws -> [ContextCompressionSourceMessage] {
        try ChatResponseAttemptSupport.visibleMessages(from: messages)
            .filter { $0.role != .error }
            .map { try ContextCompressionSourceMessage(message: $0) }
            .filter { !$0.semanticContent.isEmpty }
    }

    public static func makePlan(
        sourceMessages: [ContextCompressionSourceMessage],
        retainedRoundCount: Int
    ) throws -> ContextCompressionPlan {
        guard let sourceThroughMessageID = sourceMessages.last?.message.id else {
            throw ContextCompressionError.noCompressibleMessages
        }

        let units = makeUnits(from: sourceMessages)
        let retainedUnitIDs = retainedUnitIDs(
            in: units,
            retainedRoundCount: max(0, retainedRoundCount)
        )
        let summaryUnits = units.filter { !retainedUnitIDs.contains($0.id) }
        let retainedUnits = units.filter { retainedUnitIDs.contains($0.id) }

        return ContextCompressionPlan(
            summaryMessages: summaryUnits.flatMap(\.messages),
            retainedMessages: retainedUnits.flatMap { $0.messages.map(\.message) },
            retainedRoundCount: retainedUnits.filter(\.isDialogueRound).count,
            sourceThroughMessageID: sourceThroughMessageID,
            sourceMessageCount: sourceMessages.count,
            summarizedMessageCount: summaryUnits.reduce(0) { $0 + $1.messages.count },
            estimatedSourceTokens: sourceMessages.reduce(0) {
                $0 + ContextCompressionReminderEstimator.estimate(text: $1.semanticContent)
            }
        )
    }

    private struct CompressionUnit {
        let id: UUID
        let messages: [ContextCompressionSourceMessage]
        let isDialogueRound: Bool
    }

    private static func makeUnits(
        from messages: [ContextCompressionSourceMessage]
    ) -> [CompressionUnit] {
        var units: [CompressionUnit] = []
        var currentMessages: [ContextCompressionSourceMessage] = []
        var currentIsDialogueRound = false

        func finishCurrentUnit() {
            guard !currentMessages.isEmpty else { return }
            units.append(CompressionUnit(
                id: UUID(),
                messages: currentMessages,
                isDialogueRound: currentIsDialogueRound
            ))
            currentMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.message.role == .user {
                finishCurrentUnit()
                currentIsDialogueRound = true
            } else if currentMessages.isEmpty {
                currentIsDialogueRound = false
            }
            currentMessages.append(message)
        }
        finishCurrentUnit()
        return units
    }

    private static func retainedUnitIDs(
        in units: [CompressionUnit],
        retainedRoundCount: Int
    ) -> Set<UUID> {
        guard retainedRoundCount > 0 else { return [] }
        return Set(
            units.reversed()
                .filter(\.isDialogueRound)
                .prefix(retainedRoundCount)
                .map(\.id)
        )
    }
}
