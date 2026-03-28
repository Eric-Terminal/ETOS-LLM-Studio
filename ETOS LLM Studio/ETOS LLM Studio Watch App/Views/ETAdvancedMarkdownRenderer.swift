// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETAdvancedMarkdownRenderer 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import Shared

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool

    private var shouldUseMathEngine: Bool {
        enableAdvancedRenderer
            && enableMathRendering
            && ETMathContentParser.containsMath(in: content)
    }

    var body: some View {
        let normalizedContent = Self.normalizedMarkdownForStreaming(content)
        if shouldUseMathEngine {
            ETMathAwareMarkdownView(
                content: normalizedContent,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing
            )
        } else {
            baseTextView(normalizedContent)
        }
    }

    private static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var openedFence: (marker: Character, count: Int)?

        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            if let openedFence {
                let isClosingFence = openedFence.marker == fence.marker
                    && fence.count >= openedFence.count
                    && fence.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isClosingFence {
                    openedFence = nil
                }
            } else {
                openedFence = fence
            }
        }

        guard let openedFence else { return text }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if text.hasSuffix("\n") {
            return text + closingFence
        }
        return text + "\n" + closingFence
    }

    private static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        return (marker: marker, count: count, tail: tail)
    }

    @ViewBuilder
    private func baseTextView(_ text: String) -> some View {
        if enableMarkdown {
            let textColor: Color = isOutgoing ? .white : .primary
            Markdown(text)
                .etChatMarkdownBaseStyle(textColor: textColor, isOutgoing: isOutgoing)
        } else {
            Text(text)
                .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        }
    }
}

private struct ETMathAwareMarkdownView: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool

    private var textColor: Color {
        isOutgoing ? .white : .primary
    }

    private var blocks: [ETMathRenderBlock] {
        ETMathRenderBlock.build(from: ETMathContentParser.parseSegments(in: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .emptyLine:
                    Color.clear.frame(height: 6)
                case .blockMath(let latex):
                    ScrollView(.horizontal) {
                        ETMathView(
                            latex: latex,
                            displayMode: .block,
                            style: ETMathStyle(fontSize: 20, textColor: textColor)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    }
                    .padding(.vertical, 2)
                case .line(let parts):
                    renderLine(parts)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderLine(_ parts: [ETInlineRenderPart]) -> some View {
        if parts.contains(where: \.isMath) {
            let tokens = ETInlineRenderToken.tokens(from: parts)
            ETInlineMathFlowLayout(itemSpacing: 0, lineSpacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .text(let text):
                        Text(verbatim: text)
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: true, vertical: true)
                    case .math(let latex):
                        ETMathView(
                            latex: latex,
                            displayMode: .inline,
                            style: ETMathStyle(fontSize: 17, textColor: textColor)
                        )
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let text = parts.compactMap(\.textValue).joined()
            if enableMarkdown {
                Markdown(text)
                    .etChatMarkdownBaseStyle(textColor: textColor, isOutgoing: isOutgoing)
            } else {
                Text(text)
                    .foregroundStyle(textColor)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(textColor: Color, isOutgoing: Bool) -> some View {
        let codeBlockBackground = isOutgoing
            ? Color.white.opacity(0.12)
            : Color.primary.opacity(0.06)
        let codeHeaderBackground = isOutgoing
            ? Color.white.opacity(0.14)
            : Color.primary.opacity(0.05)
        let codeBorderColor = isOutgoing
            ? Color.white.opacity(0.2)
            : Color.primary.opacity(0.12)
        let codeHeaderTextColor = isOutgoing
            ? Color.white.opacity(0.9)
            : Color.secondary

        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownTextStyle {
                ForegroundColor(textColor)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    if let language = configuration.language, !language.isEmpty {
                        Text(language)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(codeHeaderTextColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(codeHeaderBackground)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .relativeLineSpacing(.em(0.12))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.88))
                                ForegroundColor(textColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .background(codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(codeBorderColor, lineWidth: 1)
                )
                .markdownMargin(top: .em(0.2), bottom: .em(0.7))
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
    }
}

private enum ETMathRenderBlock {
    case line([ETInlineRenderPart])
    case blockMath(String)
    case emptyLine

    static func build(from segments: [ETMathContentSegment]) -> [ETMathRenderBlock] {
        var blocks: [ETMathRenderBlock] = []
        var line: [ETInlineRenderPart] = []

        func flushLine() {
            guard !line.isEmpty else { return }
            blocks.append(.line(line))
            line.removeAll(keepingCapacity: true)
        }

        func appendText(_ text: String) {
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                let value = String(part)
                if !value.isEmpty {
                    line.append(.text(value))
                }
                if index < parts.count - 1 {
                    flushLine()
                    if value.isEmpty {
                        blocks.append(.emptyLine)
                    }
                }
            }
        }

        for segment in segments {
            switch segment {
            case .text(let text):
                appendText(text)
            case .inlineMath(let latex):
                line.append(.math(latex))
            case .blockMath(let latex):
                flushLine()
                blocks.append(.blockMath(latex))
            @unknown default:
                break
            }
        }

        flushLine()
        return blocks
    }
}

private enum ETInlineRenderPart {
    case text(String)
    case math(String)

    var isMath: Bool {
        if case .math = self { return true }
        return false
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

private enum ETInlineRenderToken {
    case text(String)
    case math(String)

    static func tokens(from parts: [ETInlineRenderPart]) -> [ETInlineRenderToken] {
        var tokens: [ETInlineRenderToken] = []
        for part in parts {
            switch part {
            case .math(let latex):
                tokens.append(.math(latex))
            case .text(let text):
                for character in text {
                    tokens.append(.text(String(character)))
                }
            }
        }
        return tokens
    }
}

private struct ETInlineMathFlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        guard !subviews.isEmpty else { return .zero }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - itemSpacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, x - itemSpacing)
        y += lineHeight

        let measuredWidth = proposal.width ?? maxLineWidth
        return CGSize(width: measuredWidth, height: y)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude

        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
