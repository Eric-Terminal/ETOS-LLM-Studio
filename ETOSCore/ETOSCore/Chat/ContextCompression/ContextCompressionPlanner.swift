// ============================================================================
// ContextCompressionPlanner.swift
// ============================================================================
// ETOS LLM Studio
//
// 将当前回复分支按完整轮次整理为无截断、可验证覆盖的压缩分块。
// ============================================================================

import Foundation

public enum ContextCompressionTokenEstimator {
    /// UTF-8 字节数是跨 Provider 的保守估算；这里只决定分块，不决定丢弃内容。
    public static func estimate(_ text: String) -> Int {
        text.utf8.count
    }
}

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

public struct ContextCompressionFragment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceUnitID: UUID
    public let sourceMessageID: UUID
    public let role: MessageRole
    public let fragmentIndex: Int
    public let fragmentCount: Int
    public let content: String
    public let estimatedTokens: Int

    public init(
        id: UUID = UUID(),
        sourceUnitID: UUID,
        sourceMessageID: UUID,
        role: MessageRole,
        fragmentIndex: Int,
        fragmentCount: Int,
        content: String,
        estimatedTokens: Int
    ) {
        self.id = id
        self.sourceUnitID = sourceUnitID
        self.sourceMessageID = sourceMessageID
        self.role = role
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.content = content
        self.estimatedTokens = estimatedTokens
    }
}

public struct ContextCompressionChunk: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fragments: [ContextCompressionFragment]
    public let estimatedTokens: Int

    public init(id: UUID = UUID(), fragments: [ContextCompressionFragment]) {
        self.id = id
        self.fragments = fragments
        self.estimatedTokens = fragments.reduce(0) { $0 + $1.estimatedTokens }
    }
}

public struct ContextCompressionPlan: Sendable {
    public let chunks: [ContextCompressionChunk]
    public let retainedMessages: [ChatMessage]
    public let retainedRoundCount: Int
    public let sourceThroughMessageID: UUID
    public let sourceMessageCount: Int
    public let summarizedMessageCount: Int
    public let estimatedSourceTokens: Int

    public init(
        chunks: [ContextCompressionChunk],
        retainedMessages: [ChatMessage],
        retainedRoundCount: Int,
        sourceThroughMessageID: UUID,
        sourceMessageCount: Int,
        summarizedMessageCount: Int,
        estimatedSourceTokens: Int
    ) {
        self.chunks = chunks
        self.retainedMessages = retainedMessages
        self.retainedRoundCount = retainedRoundCount
        self.sourceThroughMessageID = sourceThroughMessageID
        self.sourceMessageCount = sourceMessageCount
        self.summarizedMessageCount = summarizedMessageCount
        self.estimatedSourceTokens = estimatedSourceTokens
    }
}

public enum ContextCompressionPlanner {
    /// 每个片段预留角色、消息 ID、片段序号与提示词标签的协议开销。
    private static let fragmentMetadataTokenEstimate = 96
    private static let minimumInputBudget = fragmentMetadataTokenEstimate + 16

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
        retainedRoundCount: Int,
        inputTokenBudget: Int
    ) throws -> ContextCompressionPlan {
        guard inputTokenBudget >= minimumInputBudget else {
            throw ContextCompressionError.invalidInputBudget(inputTokenBudget)
        }
        guard let sourceThroughMessageID = sourceMessages.last?.message.id else {
            throw ContextCompressionError.noCompressibleMessages
        }

        let units = makeUnits(from: sourceMessages)
        let retainedUnitIDs = retainedUnitIDs(
            in: units,
            retainedRoundCount: max(0, retainedRoundCount)
        )
        let summarizedUnits = units.filter { !retainedUnitIDs.contains($0.id) }
        let retainedUnits = units.filter { retainedUnitIDs.contains($0.id) }
        let actualRetainedRoundCount = retainedUnits.filter(\.isDialogueRound).count

        let chunks = try makeChunks(
            from: summarizedUnits,
            inputTokenBudget: inputTokenBudget
        )
        try verifyCoverage(of: summarizedUnits, by: chunks)

        return ContextCompressionPlan(
            chunks: chunks,
            retainedMessages: retainedUnits.flatMap { $0.messages.map(\.message) },
            retainedRoundCount: actualRetainedRoundCount,
            sourceThroughMessageID: sourceThroughMessageID,
            sourceMessageCount: sourceMessages.count,
            summarizedMessageCount: summarizedUnits.reduce(0) { $0 + $1.messages.count },
            estimatedSourceTokens: units.reduce(0) { $0 + $1.estimatedTokens }
        )
    }

    private struct CompressionUnit {
        let id: UUID
        let messages: [ContextCompressionSourceMessage]
        let isDialogueRound: Bool

        var estimatedTokens: Int {
            messages.reduce(0) {
                $0 + ContextCompressionTokenEstimator.estimate($1.semanticContent)
                    + fragmentMetadataTokenEstimate
            }
        }
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

    private static func makeChunks(
        from units: [CompressionUnit],
        inputTokenBudget: Int
    ) throws -> [ContextCompressionChunk] {
        var chunks: [ContextCompressionChunk] = []
        var pendingFragments: [ContextCompressionFragment] = []
        var pendingTokenCount = 0

        func finishPendingChunk() {
            guard !pendingFragments.isEmpty else { return }
            chunks.append(ContextCompressionChunk(fragments: pendingFragments))
            pendingFragments.removeAll(keepingCapacity: true)
            pendingTokenCount = 0
        }

        for unit in units {
            let unitFragments = try makeFragments(
                for: unit,
                inputTokenBudget: inputTokenBudget
            )
            let unitTokenCount = unitFragments.reduce(0) { $0 + $1.estimatedTokens }

            if unitTokenCount <= inputTokenBudget {
                if pendingTokenCount + unitTokenCount > inputTokenBudget {
                    finishPendingChunk()
                }
                pendingFragments.append(contentsOf: unitFragments)
                pendingTokenCount += unitTokenCount
                continue
            }

            finishPendingChunk()
            for fragment in unitFragments {
                if pendingTokenCount + fragment.estimatedTokens > inputTokenBudget {
                    finishPendingChunk()
                }
                pendingFragments.append(fragment)
                pendingTokenCount += fragment.estimatedTokens
            }
            finishPendingChunk()
        }

        finishPendingChunk()
        return chunks
    }

    private static func makeFragments(
        for unit: CompressionUnit,
        inputTokenBudget: Int
    ) throws -> [ContextCompressionFragment] {
        let contentBudget = inputTokenBudget - fragmentMetadataTokenEstimate
        var fragments: [ContextCompressionFragment] = []

        for sourceMessage in unit.messages {
            let pieces = try splitText(
                sourceMessage.semanticContent,
                messageID: sourceMessage.message.id,
                maxEstimatedTokens: contentBudget
            )
            for (index, piece) in pieces.enumerated() {
                fragments.append(ContextCompressionFragment(
                    sourceUnitID: unit.id,
                    sourceMessageID: sourceMessage.message.id,
                    role: sourceMessage.message.role,
                    fragmentIndex: index,
                    fragmentCount: pieces.count,
                    content: piece,
                    estimatedTokens: ContextCompressionTokenEstimator.estimate(piece)
                        + fragmentMetadataTokenEstimate
                ))
            }
        }
        return fragments
    }

    private enum SplitLevel: Int {
        case paragraph
        case newline
        case sentence
        case grapheme

        var next: SplitLevel? {
            SplitLevel(rawValue: rawValue + 1)
        }
    }

    private static func splitText(
        _ text: String,
        messageID: UUID,
        maxEstimatedTokens: Int,
        level: SplitLevel = .paragraph
    ) throws -> [String] {
        guard ContextCompressionTokenEstimator.estimate(text) > maxEstimatedTokens else {
            return [text]
        }

        switch level {
        case .paragraph:
            return try refineAndPack(
                segmentsEndingWithDelimiter(text, delimiter: "\n\n"),
                originalText: text,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens,
                nextLevel: level.next
            )
        case .newline:
            return try refineAndPack(
                segmentsEndingWithDelimiter(text, delimiter: "\n"),
                originalText: text,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens,
                nextLevel: level.next
            )
        case .sentence:
            return try refineAndPack(
                sentenceSegments(text),
                originalText: text,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens,
                nextLevel: level.next
            )
        case .grapheme:
            return try packGraphemes(
                text,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens
            )
        }
    }

    private static func refineAndPack(
        _ segments: [String],
        originalText: String,
        messageID: UUID,
        maxEstimatedTokens: Int,
        nextLevel: SplitLevel?
    ) throws -> [String] {
        guard let nextLevel else {
            return try packGraphemes(
                originalText,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens
            )
        }
        if segments.count <= 1 {
            return try splitText(
                originalText,
                messageID: messageID,
                maxEstimatedTokens: maxEstimatedTokens,
                level: nextLevel
            )
        }

        var refined: [String] = []
        for segment in segments {
            if ContextCompressionTokenEstimator.estimate(segment) <= maxEstimatedTokens {
                refined.append(segment)
            } else {
                refined.append(contentsOf: try splitText(
                    segment,
                    messageID: messageID,
                    maxEstimatedTokens: maxEstimatedTokens,
                    level: nextLevel
                ))
            }
        }
        return packSegments(refined, maxEstimatedTokens: maxEstimatedTokens)
    }

    private static func segmentsEndingWithDelimiter(
        _ text: String,
        delimiter: String
    ) -> [String] {
        guard !delimiter.isEmpty else { return [text] }
        var segments: [String] = []
        var start = text.startIndex

        while start < text.endIndex,
              let range = text.range(
                of: delimiter,
                range: start..<text.endIndex
              ) {
            segments.append(String(text[start..<range.upperBound]))
            start = range.upperBound
        }
        if start < text.endIndex {
            segments.append(String(text[start..<text.endIndex]))
        }
        return segments.isEmpty ? [text] : segments
    }

    private static func sentenceSegments(_ text: String) -> [String] {
        let boundaries: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var segments: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if boundaries.contains(character) {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments.isEmpty ? [text] : segments
    }

    private static func packSegments(
        _ segments: [String],
        maxEstimatedTokens: Int
    ) -> [String] {
        var packed: [String] = []
        var current = ""

        for segment in segments {
            let candidate = current + segment
            if !current.isEmpty,
               ContextCompressionTokenEstimator.estimate(candidate) > maxEstimatedTokens {
                packed.append(current)
                current = segment
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            packed.append(current)
        }
        return packed
    }

    private static func packGraphemes(
        _ text: String,
        messageID: UUID,
        maxEstimatedTokens: Int
    ) throws -> [String] {
        var pieces: [String] = []
        var current = ""

        for character in text {
            let grapheme = String(character)
            let graphemeTokens = ContextCompressionTokenEstimator.estimate(grapheme)
            guard graphemeTokens <= maxEstimatedTokens else {
                throw ContextCompressionError.minimalTextUnitExceedsBudget(
                    messageID: messageID,
                    estimatedTokens: graphemeTokens,
                    budget: maxEstimatedTokens
                )
            }
            let candidate = current + grapheme
            if !current.isEmpty,
               ContextCompressionTokenEstimator.estimate(candidate) > maxEstimatedTokens {
                pieces.append(current)
                current = grapheme
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func verifyCoverage(
        of units: [CompressionUnit],
        by chunks: [ContextCompressionChunk]
    ) throws {
        let allFragments = chunks.flatMap(\.fragments)
        let expectedMessages = units.flatMap(\.messages)

        for expectedMessage in expectedMessages {
            let fragments = allFragments
                .filter { $0.sourceMessageID == expectedMessage.message.id }
                .sorted { $0.fragmentIndex < $1.fragmentIndex }
            guard !fragments.isEmpty,
                  fragments.enumerated().allSatisfy({ index, fragment in
                      fragment.fragmentIndex == index && fragment.fragmentCount == fragments.count
                  }),
                  fragments.map(\.content).joined() == expectedMessage.semanticContent else {
                throw ContextCompressionError.incompleteCoverage(messageID: expectedMessage.message.id)
            }
        }

        let expectedMessageIDs = Set(expectedMessages.map { $0.message.id })
        guard allFragments.allSatisfy({ expectedMessageIDs.contains($0.sourceMessageID) }) else {
            let unexpectedID = allFragments.first {
                !expectedMessageIDs.contains($0.sourceMessageID)
            }?.sourceMessageID ?? UUID()
            throw ContextCompressionError.incompleteCoverage(messageID: unexpectedID)
        }
    }
}
