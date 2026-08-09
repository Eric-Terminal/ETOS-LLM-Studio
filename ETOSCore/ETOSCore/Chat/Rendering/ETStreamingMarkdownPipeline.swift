// ============================================================================
// ETStreamingMarkdownPipeline.swift
// ============================================================================
// ETOSCore
//
// 在后台维护每条消息的稳定 Markdown 区与唯一活动区，避免后续 Token
// 反复扫描和解析已经提交的历史内容。
// ============================================================================

import Foundation
import Markdown

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
        var lastCommittedBottomSpacingEm = 0.0
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
        // 流式增量可能每个 Token 都进入这里；不要为高频热路径逐次写 MetricKit Signpost。
        // 整次响应与最终 Markdown 预计算仍有低频区间，足以定位实际性能瓶颈。
        let split = ETStreamingMarkdownASTParser.split(workingSource)
        let didReset = !isStrictAppend
        let committedCountBeforeUpdate = state.committedBlocks.count

        for committed in split.committedBlocks where !committed.source.isEmpty {
            let leadingSpacingEm = state.committedBlocks.isEmpty
                ? 0
                : max(state.lastCommittedBottomSpacingEm, committed.topSpacingEm)
            let block = ETStreamingMarkdownBlock(
                id: ETStreamingMarkdownBlockID(
                    messageID: messageID,
                    channel: channel,
                    generation: state.generation,
                    ordinal: state.nextOrdinal
                ),
                source: committed.source,
                kind: committed.kind,
                leadingSpacingEm: leadingSpacingEm
            )
            state.committedBlocks.append(block)
            state.lastCommittedBottomSpacingEm = committed.bottomSpacingEm
            state.nextOrdinal += 1
        }

        // 结束信号抵达时仍保留活动 Block，让 UI 在静态 Markdown 预计算完成前继续
        // 展示同一个 TextKit/SwiftUI 尾部，避免最后一段短暂退回未经解析的纯文本。
        let active = split.activeBlock

        let activeBlock: ETStreamingMarkdownActiveBlock?
        let activeDisplayText: String
        if let active {
            let presentation = active.presentation
            activeDisplayText = active.displayText
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
                source: active.source,
                displayText: activeDisplayText,
                presentation: presentation,
                updateKind: updateKind,
                leadingSpacingEm: state.committedBlocks.isEmpty
                    ? 0
                    : max(state.lastCommittedBottomSpacingEm, active.topSpacingEm)
            )
        } else {
            activeBlock = nil
            activeDisplayText = ""
        }

        state.sourceText = sourceText
        state.activeSource = active?.source ?? ""
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

enum ETStreamingMarkdownASTParser {
    struct ParsedBlock: Equatable {
        let source: String
        let kind: ETStreamingMarkdownBlockKind
        let presentation: ETStreamingMarkdownActivePresentation
        let displayText: String
        let topSpacingEm: Double
        let bottomSpacingEm: Double
    }

    struct SplitResult: Equatable {
        let committedBlocks: [ParsedBlock]
        let activeBlock: ParsedBlock?
    }

    static func split(_ source: String) -> SplitResult {
        guard !source.isEmpty else {
            return SplitResult(committedBlocks: [], activeBlock: nil)
        }

        let children = Array(Document(parsing: source).children)
        guard !children.isEmpty else {
            return SplitResult(
                committedBlocks: [],
                activeBlock: parsedBlock(source: source, markup: nil)
            )
        }

        let converter = SourceIndexConverter(source: source)
        var segmentStarts = [source.startIndex]
        for child in children.dropFirst() {
            guard let location = child.range?.lowerBound,
                  converter.index(for: location) != nil,
                  let lineStart = converter.lineStart(for: location.line),
                  lineStart >= segmentStarts[segmentStarts.count - 1] else {
                return SplitResult(
                    committedBlocks: [],
                    activeBlock: parsedBlock(source: source, markup: children.last)
                )
            }
            segmentStarts.append(lineStart)
        }

        var parsedBlocks: [ParsedBlock] = []
        parsedBlocks.reserveCapacity(children.count)
        for index in children.indices {
            let end = index + 1 < segmentStarts.count
                ? segmentStarts[index + 1]
                : source.endIndex
            let blockSource = String(source[segmentStarts[index]..<end])
            guard !blockSource.isEmpty else { continue }
            parsedBlocks.append(parsedBlock(source: blockSource, markup: children[index]))
        }

        guard let activeBlock = parsedBlocks.popLast() else {
            return SplitResult(
                committedBlocks: [],
                activeBlock: parsedBlock(source: source, markup: children.last)
            )
        }
        return SplitResult(committedBlocks: parsedBlocks, activeBlock: activeBlock)
    }

    private static func parsedBlock(source: String, markup: Markup?) -> ParsedBlock {
        let spacing = blockSpacing(for: markup)
        guard let codeBlock = markup as? CodeBlock else {
            return ParsedBlock(
                source: source,
                kind: .markdown,
                presentation: .markdownSource,
                displayText: source,
                topSpacingEm: spacing.top,
                bottomSpacingEm: spacing.bottom
            )
        }

        let language = codeBlock.language?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() }
        if language == "mermaid" || language == "mmd" {
            return ParsedBlock(
                source: source,
                kind: .mermaid,
                presentation: .mermaidSource,
                displayText: codeBody(source: source, parsedCode: codeBlock.code),
                topSpacingEm: spacing.top,
                bottomSpacingEm: spacing.bottom
            )
        }
        return ParsedBlock(
            source: source,
            kind: .fencedCode(language: language),
            presentation: .code(language: language),
            displayText: codeBody(source: source, parsedCode: codeBlock.code),
            topSpacingEm: spacing.top,
            bottomSpacingEm: spacing.bottom
        )
    }

    /// 与 MarkdownUI Basic Theme 及聊天自定义 BlockStyle 的 margin 合并规则保持一致。
    private static func blockSpacing(for markup: Markup?) -> (top: Double, bottom: Double) {
        switch markup {
        case is Heading:
            return (1.5, 1)
        case is ThematicBreak:
            return (2, 2)
        case is CodeBlock:
            return (0.2, 0.75)
        case is BlockQuote:
            return (0.2, 1)
        default:
            return (0, 1)
        }
    }

    private static func codeBody(source: String, parsedCode: String) -> String {
        guard let openingLineEnd = source.firstIndex(of: "\n") else {
            return parsedCode
        }

        let firstLineSource = source[..<openingLineEnd]
        let openingIndent = firstLineSource.prefix(while: { $0 == " " }).count
        guard openingIndent <= 3 else { return parsedCode }
        let firstLine = firstLineSource.dropFirst(openingIndent)
        guard let marker = firstLine.first,
              marker == "`" || marker == "~",
              firstLine.prefix(while: { $0 == marker }).count >= 3 else {
            return parsedCode
        }
        let openingMarkerCount = firstLine.prefix(while: { $0 == marker }).count

        let bodyStart = source.index(after: openingLineEnd)
        var candidateEnd = source.endIndex
        while candidateEnd > bodyStart {
            let previousNewline = source[..<candidateEnd].lastIndex(of: "\n")
            let candidateStart = previousNewline.map { source.index(after: $0) } ?? bodyStart
            let candidateSource = source[candidateStart..<candidateEnd]
            let closingIndent = candidateSource.prefix(while: { $0 == " " }).count
            let candidate = candidateSource.dropFirst(closingIndent)
            let closingMarkerCount = candidate.prefix(while: { $0 == marker }).count

            if closingIndent <= 3,
               closingMarkerCount >= openingMarkerCount,
               candidate.dropFirst(closingMarkerCount).allSatisfy(\.isWhitespace) {
                return String(source[bodyStart..<candidateStart])
            }
            guard candidate.allSatisfy(\.isWhitespace), let previousNewline else { break }
            candidateEnd = previousNewline
        }
        return String(source[bodyStart...])
    }

    // swift-markdown 的列号按 UTF-8 字节计数，不能直接作为 Swift 字符偏移使用。
    private struct SourceIndexConverter {
        let source: String
        let lineStarts: [String.UTF8View.Index]

        init(source: String) {
            self.source = source
            var starts = [source.utf8.startIndex]
            var index = source.utf8.startIndex
            while index < source.utf8.endIndex {
                let nextIndex = source.utf8.index(after: index)
                if source.utf8[index] == 0x0A {
                    starts.append(nextIndex)
                }
                index = nextIndex
            }
            lineStarts = starts
        }

        func index(for location: SourceLocation) -> String.Index? {
            guard location.line > 0,
                  location.line <= lineStarts.count,
                  location.column > 0 else {
                return nil
            }
            let lineStart = lineStarts[location.line - 1]
            let lineEnd = location.line < lineStarts.count
                ? lineStarts[location.line]
                : source.utf8.endIndex
            guard let utf8Index = source.utf8.index(
                lineStart,
                offsetBy: location.column - 1,
                limitedBy: lineEnd
            ) else {
                return nil
            }
            return utf8Index.samePosition(in: source)
        }

        func lineStart(for line: Int) -> String.Index? {
            guard line > 0, line <= lineStarts.count else { return nil }
            return lineStarts[line - 1].samePosition(in: source)
        }
    }
}
