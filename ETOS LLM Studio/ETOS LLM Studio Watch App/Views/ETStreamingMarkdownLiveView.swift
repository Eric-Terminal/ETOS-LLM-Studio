// ============================================================================
// ETStreamingMarkdownLiveView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 使用低频 SwiftUI Text 展示活动 Block，稳定 Block 继续复用 MarkdownUI。
// ============================================================================

import ETOSCore
@preconcurrency import MarkdownUI
import SwiftUI

private struct ETWatchPreparedStreamingMarkdownBlock: @unchecked Sendable {
    let id: ETStreamingMarkdownBlockID
    let markdownContent: MarkdownContent
}

private actor ETWatchStreamingMarkdownBlockWorker {
    static let shared = ETWatchStreamingMarkdownBlockWorker()

    private struct CacheEntry {
        let source: String
        let prepared: ETWatchPreparedStreamingMarkdownBlock
    }

    private var cache: [ETStreamingMarkdownBlockID: CacheEntry] = [:]
    private var keyOrder: [ETStreamingMarkdownBlockID] = []
    private let cacheLimit = 96

    func prepare(
        _ blocks: [ETStreamingMarkdownBlock]
    ) -> [ETStreamingMarkdownBlockID: ETWatchPreparedStreamingMarkdownBlock] {
        var result: [ETStreamingMarkdownBlockID: ETWatchPreparedStreamingMarkdownBlock] = [:]
        result.reserveCapacity(blocks.count)

        for block in blocks {
            if let cached = cache[block.id], cached.source == block.source {
                result[block.id] = cached.prepared
                continue
            }
            let prepared = ETWatchPreparedStreamingMarkdownBlock(
                id: block.id,
                markdownContent: MarkdownContent(block.source)
            )
            cache[block.id] = CacheEntry(source: block.source, prepared: prepared)
            keyOrder.append(block.id)
            result[block.id] = prepared
        }

        while keyOrder.count > cacheLimit {
            cache.removeValue(forKey: keyOrder.removeFirst())
        }
        return result
    }
}

struct ETWatchStreamingMarkdownLiveView: View {
    @ObservedObject var state: ETStreamingMarkdownRenderState
    let channel: ETStreamingMarkdownChannel
    let fallbackText: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let textColor: Color
    let customTextStyleColors: ChatAppearanceTextStyleColors?
    let fontScale: Double
    let lineSpacing: CGFloat
    let streamingDisplayMode: ChatStreamingDisplayMode
    let onCodeBlockHeaderTap: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var imagePreviewItem: ETWatchMarkdownImagePreviewItem?
    @State private var preparedBlocks: [ETStreamingMarkdownBlockID: ETWatchPreparedStreamingMarkdownBlock] = [:]

    private var snapshot: ETStreamingMarkdownSnapshot? {
        state.snapshot(for: channel)
    }

    private var preparationID: ETStreamingMarkdownBlockID? {
        snapshot?.committedBlocks.last?.id
    }

    private func interBlockSpacing(_ multiplier: Double) -> CGFloat {
        guard enableMarkdown else { return 0 }
        let rootFontSize = round(CGFloat(16 * FontLibrary.normalizedFontScale(fontScale)))
        return round(CGFloat(multiplier) * rootFontSize)
    }

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.committedBlocks) { block in
                        committedBlockView(block)
                            .padding(.top, interBlockSpacing(block.leadingSpacingEm))
                    }
                    if let activeBlock = snapshot.activeBlock {
                        activeBlockView(activeBlock, revision: snapshot.revision)
                            .padding(.top, interBlockSpacing(activeBlock.leadingSpacingEm))
                    }
                }
            } else {
                Text(fallbackText)
                    .etFont(.body, sampleText: fallbackText)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(textColor)
            }
        }
        .task(id: enableMarkdown ? preparationID : nil) {
            guard enableMarkdown,
                  let blocks = snapshot?.committedBlocks,
                  !blocks.isEmpty else {
                preparedBlocks = [:]
                return
            }
            let prepared = await ETWatchStreamingMarkdownBlockWorker.shared.prepare(blocks)
            guard !Task.isCancelled else { return }
            preparedBlocks = prepared
        }
        .sheet(item: $imagePreviewItem) { item in
            ETWatchMarkdownImagePreviewSheet(item: item)
        }
    }

    @ViewBuilder
    private func committedBlockView(_ block: ETStreamingMarkdownBlock) -> some View {
        if enableMarkdown, let prepared = preparedBlocks[block.id] {
            Markdown(prepared.markdownContent)
                .markdownImageProvider(
                    ETWatchMarkdownImageProvider { item in
                        imagePreviewItem = item
                    }
                )
                .etChatMarkdownBaseStyle(
                    textColor: textColor,
                    emphasisTextColor: resolvedStyleColor(customTextStyleColors?.emphasis),
                    strongTextColor: resolvedStyleColor(customTextStyleColors?.strong),
                    codeTextColor: resolvedStyleColor(customTextStyleColors?.code),
                    usesCustomCodeTextColor: customTextStyleColors?.usesAutomaticCodeSyntaxHighlighting == false,
                    isOutgoing: isOutgoing,
                    prefersDarkPalette: colorScheme == .dark,
                    sampleText: block.source,
                    fontScale: fontScale,
                    lineSpacing: lineSpacing,
                    codeHighlightLimit: 4_096,
                    onCodeBlockHeaderTap: onCodeBlockHeaderTap
                )
        } else {
            Text(block.source)
                .etFont(.body, sampleText: block.source)
                .lineSpacing(lineSpacing)
                .foregroundStyle(textColor)
        }
    }

    @ViewBuilder
    private func activeBlockView(
        _ block: ETStreamingMarkdownActiveBlock,
        revision: Int
    ) -> some View {
        let text = Text(block.displayText)
            .foregroundStyle(textColor)
        Group {
            switch block.presentation {
            case .markdownSource:
                text.etFont(.body, sampleText: block.displayText)
            case .code, .mermaidSource:
                text.etFont(.body.monospaced(), sampleText: block.displayText)
            }
        }
        .lineSpacing(lineSpacing)
        .contentTransition(reduceMotion ? .identity : .opacity)
        .animation(
            reduceMotion ? nil : .easeOut(duration: streamingDisplayMode.textRevealDuration),
            value: revision
        )
    }

    private func resolvedStyleColor(_ slot: ChatAppearanceColorSlot?) -> Color {
        guard let slot, slot.isEnabled else { return textColor }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: textColor)
    }
}
