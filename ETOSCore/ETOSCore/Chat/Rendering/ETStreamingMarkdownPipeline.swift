// ============================================================================
// ETStreamingMarkdownPipeline.swift
// ============================================================================
// ETOSCore
//
// 在后台维护每条消息的稳定 Markdown 区与唯一活动区，避免后续 Token
// 反复扫描和解析已经提交的历史内容。
// ============================================================================

import Foundation

public actor ETStreamingMarkdownPipeline {
    public static let shared = ETStreamingMarkdownPipeline()

    private struct MessageState {
        var sourceText = ""
        var revision = 0
        var generation = 0
        var committedBlocks: [ETStreamingMarkdownBlock] = []
        var activeSource = ""
        var activeDisplayText = ""
        var nextOrdinal = 0
        var lastSnapshot: ETStreamingMarkdownSnapshot?
    }

    private var states: [ETStreamingMarkdownStreamID: MessageState] = [:]

    public init() {}

    public func prepare(
        messageID: UUID,
        channel: ETStreamingMarkdownChannel = .content,
        sourceText: String,
        isFinal: Bool
    ) -> ETStreamingMarkdownSnapshot {
        let streamID = ETStreamingMarkdownStreamID(messageID: messageID, channel: channel)
        var state = states[streamID] ?? MessageState()
        if state.sourceText == sourceText,
           state.lastSnapshot?.isFinal == isFinal,
           let snapshot = state.lastSnapshot {
            return snapshot
        }

        let previousSource = state.sourceText
        let previousActiveDisplayText = state.activeDisplayText
        let isStrictAppend = sourceText.hasPrefix(previousSource)
        let appendedText: String

        if isStrictAppend {
            let suffixStart = sourceText.index(sourceText.startIndex, offsetBy: previousSource.count)
            appendedText = String(sourceText[suffixStart...])
        } else {
            let nextGeneration = state.generation &+ 1
            state = MessageState(generation: nextGeneration)
            appendedText = sourceText
        }

        let workingSource = state.activeSource + appendedText
        let signpost = TelemetrySignpost.begin(
            TelemetrySignpost.markdownInterval(characterCount: workingSource.count)
        )
        defer { TelemetrySignpost.end(signpost) }
        let split = ETStreamingMarkdownBoundaryScanner.split(workingSource)
        let didReset = !isStrictAppend
        let committedCountBeforeUpdate = state.committedBlocks.count

        for committedSource in split.committedSources where !committedSource.isEmpty {
            let block = ETStreamingMarkdownBlock(
                id: ETStreamingMarkdownBlockID(
                    messageID: messageID,
                    channel: channel,
                    generation: state.generation,
                    ordinal: state.nextOrdinal
                ),
                source: committedSource,
                kind: ETStreamingMarkdownBoundaryScanner.blockKind(for: committedSource)
            )
            state.committedBlocks.append(block)
            state.nextOrdinal += 1
        }

        var activeSource = split.activeSource
        if isFinal, !activeSource.isEmpty {
            let block = ETStreamingMarkdownBlock(
                id: ETStreamingMarkdownBlockID(
                    messageID: messageID,
                    channel: channel,
                    generation: state.generation,
                    ordinal: state.nextOrdinal
                ),
                source: activeSource,
                kind: ETStreamingMarkdownBoundaryScanner.blockKind(for: activeSource)
            )
            state.committedBlocks.append(block)
            state.nextOrdinal += 1
            activeSource = ""
        }

        let activeBlock: ETStreamingMarkdownActiveBlock?
        let activeDisplayText: String
        if activeSource.isEmpty {
            activeBlock = nil
            activeDisplayText = ""
        } else {
            let presentation = ETStreamingMarkdownBoundaryScanner.activePresentation(for: activeSource)
            activeDisplayText = ETStreamingMarkdownBoundaryScanner.displayText(
                for: activeSource,
                presentation: presentation
            )
            let updateKind: ETStreamingMarkdownUpdateKind
            let committedNewBlock = state.committedBlocks.count != committedCountBeforeUpdate
            if !didReset,
               !committedNewBlock,
               activeDisplayText.hasPrefix(previousActiveDisplayText) {
                updateKind = .append(previousUTF16Length: previousActiveDisplayText.utf16.count)
            } else {
                updateKind = .reset
            }
            activeBlock = ETStreamingMarkdownActiveBlock(
                id: ETStreamingMarkdownBlockID(
                    messageID: messageID,
                    channel: channel,
                    generation: state.generation,
                    ordinal: state.nextOrdinal
                ),
                source: activeSource,
                displayText: activeDisplayText,
                presentation: presentation,
                updateKind: updateKind
            )
        }

        state.sourceText = sourceText
        state.activeSource = activeSource
        state.activeDisplayText = activeDisplayText
        state.revision &+= 1

        let snapshot = ETStreamingMarkdownSnapshot(
            messageID: messageID,
            channel: channel,
            sourceText: sourceText,
            revision: state.revision,
            committedBlocks: state.committedBlocks,
            activeBlock: activeBlock,
            isFinal: isFinal
        )
        state.lastSnapshot = snapshot
        states[streamID] = state
        return snapshot
    }

    public func remove(messageID: UUID) {
        states = states.filter { $0.key.messageID != messageID }
    }

    public func retain(messageIDs: Set<UUID>) {
        states = states.filter { messageIDs.contains($0.key.messageID) }
    }
}

enum ETStreamingMarkdownBoundaryScanner {
    private struct SourceLine {
        let range: Range<String.Index>
        let content: Substring
    }

    private enum ContainerKind: Equatable {
        case regular
        case blockquote
        case list(ListMarkerKind)
        case indented
        case fenced
    }

    private enum ListMarkerKind: Equatable {
        case unordered
        case ordered
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let info: String?
    }

    struct SplitResult: Equatable {
        let committedSources: [String]
        let activeSource: String
    }

    static func split(_ source: String) -> SplitResult {
        guard !source.isEmpty else {
            return SplitResult(committedSources: [], activeSource: "")
        }

        let lines = sourceLines(in: source)
        var committedSources: [String] = []
        var segmentStart = source.startIndex
        var segmentContainer: ContainerKind?
        var openFence: Fence?
        var pendingBlankBoundary = false
        var pendingFenceBoundary = false

        for line in lines {
            let content = line.content
            let isBlank = content.allSatisfy(\.isWhitespace)

            if let fence = openFence {
                if isClosingFence(content, matching: fence) {
                    openFence = nil
                    pendingFenceBoundary = true
                }
                continue
            }

            if isBlank {
                pendingBlankBoundary = segmentContainer != nil
                continue
            }

            if pendingFenceBoundary {
                appendCommittedSource(
                    source,
                    range: segmentStart..<line.range.lowerBound,
                    into: &committedSources
                )
                segmentStart = line.range.lowerBound
                segmentContainer = nil
                pendingBlankBoundary = false
                pendingFenceBoundary = false
            } else if pendingBlankBoundary,
                      let container = segmentContainer,
                      !continues(container: container, with: content) {
                appendCommittedSource(
                    source,
                    range: segmentStart..<line.range.lowerBound,
                    into: &committedSources
                )
                segmentStart = line.range.lowerBound
                segmentContainer = nil
                pendingBlankBoundary = false
            } else {
                pendingBlankBoundary = false
            }

            if segmentContainer == nil {
                if let fence = openingFence(content) {
                    segmentContainer = .fenced
                    openFence = fence
                } else {
                    segmentContainer = containerKind(for: content)
                }
            }
        }

        let activeSource = String(source[segmentStart...])
        return SplitResult(
            committedSources: committedSources,
            activeSource: activeSource
        )
    }

    static func blockKind(for source: String) -> ETStreamingMarkdownBlockKind {
        guard let firstContentLine = sourceLines(in: source).first(where: {
            !$0.content.allSatisfy(\.isWhitespace)
        }), let fence = openingFence(firstContentLine.content) else {
            return .markdown
        }

        let language = fence.info?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() }
        if language == "mermaid" || language == "mmd" {
            return .mermaid
        }
        return .fencedCode(language: language)
    }

    static func activePresentation(
        for source: String
    ) -> ETStreamingMarkdownActivePresentation {
        switch blockKind(for: source) {
        case .markdown:
            return .markdownSource
        case .fencedCode(let language):
            return .code(language: language)
        case .mermaid:
            return .mermaidSource
        }
    }

    static func displayText(
        for source: String,
        presentation: ETStreamingMarkdownActivePresentation
    ) -> String {
        switch presentation {
        case .markdownSource:
            return source
        case .code, .mermaidSource:
            return fencedBody(in: source)
        }
    }

    private static func sourceLines(in source: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var lineStart = source.startIndex
        var cursor = source.startIndex

        while cursor < source.endIndex {
            if source[cursor] == "\n" {
                let afterNewline = source.index(after: cursor)
                lines.append(SourceLine(
                    range: lineStart..<afterNewline,
                    content: source[lineStart..<cursor]
                ))
                lineStart = afterNewline
            }
            cursor = source.index(after: cursor)
        }

        if lineStart < source.endIndex {
            lines.append(SourceLine(
                range: lineStart..<source.endIndex,
                content: source[lineStart..<source.endIndex]
            ))
        }
        return lines
    }

    private static func appendCommittedSource(
        _ source: String,
        range: Range<String.Index>,
        into result: inout [String]
    ) {
        guard !range.isEmpty else { return }
        result.append(String(source[range]))
    }

    private static func containerKind(for line: Substring) -> ContainerKind {
        let leadingSpaces = line.prefix { $0 == " " }.count
        if leadingSpaces >= 4 {
            return .indented
        }
        let trimmed = line.dropFirst(min(leadingSpaces, line.count))
        if trimmed.first == ">" {
            return .blockquote
        }
        if let marker = listMarkerKind(in: line) {
            return .list(marker)
        }
        return .regular
    }

    private static func continues(container: ContainerKind, with line: Substring) -> Bool {
        switch container {
        case .regular, .fenced:
            return false
        case .blockquote:
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.first == ">"
        case .list(let marker):
            if listMarkerKind(in: line) == marker {
                return true
            }
            return line.prefix { $0 == " " }.count >= 2
        case .indented:
            return line.prefix { $0 == " " }.count >= 4
        }
    }

    private static func listMarkerKind(in line: Substring) -> ListMarkerKind? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let content = line.dropFirst(spaces)
        guard let first = content.first else { return nil }

        if first == "-" || first == "+" || first == "*" {
            let next = content.index(after: content.startIndex)
            guard next < content.endIndex, content[next].isWhitespace else { return nil }
            return .unordered
        }

        var cursor = content.startIndex
        var digitCount = 0
        while cursor < content.endIndex,
              content[cursor].isNumber,
              digitCount < 9 {
            digitCount += 1
            cursor = content.index(after: cursor)
        }
        guard digitCount > 0,
              cursor < content.endIndex,
              content[cursor] == "." || content[cursor] == ")" else {
            return nil
        }
        cursor = content.index(after: cursor)
        guard cursor < content.endIndex, content[cursor].isWhitespace else { return nil }
        return .ordered
    }

    private static func openingFence(_ line: Substring) -> Fence? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let content = line.dropFirst(spaces)
        guard let marker = content.first, marker == "`" || marker == "~" else {
            return nil
        }
        let count = content.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let tailStart = content.index(content.startIndex, offsetBy: count)
        let tail = content[tailStart...]
        if marker == "`", tail.contains("`") {
            return nil
        }
        let info = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return Fence(marker: marker, count: count, info: info.isEmpty ? nil : info)
    }

    private static func isClosingFence(_ line: Substring, matching fence: Fence) -> Bool {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return false }
        let content = line.dropFirst(spaces)
        let count = content.prefix { $0 == fence.marker }.count
        guard count >= fence.count else { return false }
        let tailStart = content.index(content.startIndex, offsetBy: count)
        return content[tailStart...].allSatisfy(\.isWhitespace)
    }

    private static func fencedBody(in source: String) -> String {
        let lines = sourceLines(in: source)
        guard let firstIndex = lines.firstIndex(where: {
            !$0.content.allSatisfy(\.isWhitespace)
        }), let fence = openingFence(lines[firstIndex].content) else {
            return source
        }

        let bodyStart = lines[firstIndex].range.upperBound
        var bodyEnd = source.endIndex
        if let lastContentIndex = lines.lastIndex(where: {
            !$0.content.allSatisfy(\.isWhitespace)
        }), lastContentIndex > firstIndex,
           isClosingFence(lines[lastContentIndex].content, matching: fence) {
            bodyEnd = lines[lastContentIndex].range.lowerBound
        }
        guard bodyStart <= bodyEnd else { return "" }
        return String(source[bodyStart..<bodyEnd])
    }
}
