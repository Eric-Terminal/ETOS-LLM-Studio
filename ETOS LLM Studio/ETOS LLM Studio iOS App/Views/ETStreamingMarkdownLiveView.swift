// ============================================================================
// ETStreamingMarkdownLiveView.swift
// ============================================================================
// ETOS LLM Studio
//
// 组合后台准备好的稳定 Markdown Block 与 TextKit 2 活动 Block。
// ============================================================================

import ETOSCore
@preconcurrency import MarkdownUI
import SwiftUI

private struct ETIOSPreparedStreamingMarkdownBlock: @unchecked Sendable {
    let id: ETStreamingMarkdownBlockID
    let payload: ETPreparedMarkdownRenderPayload
}

private actor ETIOSStreamingMarkdownBlockWorker {
    static let shared = ETIOSStreamingMarkdownBlockWorker()

    private struct CacheEntry {
        let source: String
        let prepared: ETIOSPreparedStreamingMarkdownBlock
    }

    private var cache: [ETStreamingMarkdownBlockID: CacheEntry] = [:]
    private var keyOrder: [ETStreamingMarkdownBlockID] = []
    private let cacheLimit = 160

    func prepare(
        _ blocks: [ETStreamingMarkdownBlock]
    ) async -> [ETStreamingMarkdownBlockID: ETIOSPreparedStreamingMarkdownBlock] {
        var result: [ETStreamingMarkdownBlockID: ETIOSPreparedStreamingMarkdownBlock] = [:]
        result.reserveCapacity(blocks.count)

        for block in blocks {
            if let cached = cache[block.id], cached.source == block.source {
                result[block.id] = cached.prepared
                continue
            }
            let payload = await ETPreparedMarkdownRenderPayload.build(from: block.source)
            let prepared = ETIOSPreparedStreamingMarkdownBlock(
                id: block.id,
                payload: payload
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

struct ETIOSStreamingMarkdownLiveView: View {
    @ObservedObject var state: ETStreamingMarkdownRenderState
    let channel: ETStreamingMarkdownChannel
    let fallbackText: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let textColor: Color
    let customTextStyleColors: ChatAppearanceTextStyleColors?
    let fontScale: Double
    let lineSpacingEm: Double
    let lineSpacing: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var preparedBlocks: [ETStreamingMarkdownBlockID: ETIOSPreparedStreamingMarkdownBlock] = [:]

    private var snapshot: ETStreamingMarkdownSnapshot? {
        state.snapshot(for: channel)
    }

    private var preparationID: ETStreamingMarkdownBlockID? {
        snapshot?.committedBlocks.last?.id
    }

    private func interBlockSpacing(_ multiplier: Double) -> CGFloat {
        guard enableMarkdown else { return 0 }
        let rootFontSize = round(CGFloat(17 * FontLibrary.normalizedFontScale(fontScale)))
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
                        ETStreamingMarkdownTextView(
                            activeBlock: activeBlock,
                            textColor: textColor,
                            fontScale: fontScale,
                            lineSpacing: lineSpacing
                        )
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
            let prepared = await ETIOSStreamingMarkdownBlockWorker.shared.prepare(blocks)
            guard !Task.isCancelled else { return }
            preparedBlocks = prepared
        }
        // 网络分块只改变文字与高度，不继承气泡入场等外层动画，避免高速重排横向漂移。
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func committedBlockView(_ block: ETStreamingMarkdownBlock) -> some View {
        if enableMarkdown, let prepared = preparedBlocks[block.id] {
            if enableAdvancedRenderer, prepared.payload.containsMermaidContent {
                ETMathWebMarkdownView(
                    content: prepared.payload.mathRenderText,
                    enableMarkdown: true,
                    isOutgoing: isOutgoing,
                    customTextHex: ChatAppearanceColorCodec.hexRGBA(from: textColor),
                    customEmphasisTextHex: enabledHex(customTextStyleColors?.emphasis),
                    customStrongTextHex: enabledHex(customTextStyleColors?.strong),
                    customCodeTextHex: enabledHex(customTextStyleColors?.code),
                    prefersDarkPalette: colorScheme == .dark,
                    fontScale: fontScale,
                    lineSpacingEm: lineSpacingEm
                )
            } else {
                let markdownContent = resolvedMarkdownContent(prepared.payload)
                let mathTextColor = ETIOSMathColorComponents(textColor)
                Markdown(markdownContent)
                    .markdownImageProvider(
                        ETIOSMarkdownImageProvider(textColor: mathTextColor, fontScale: fontScale)
                    )
                    .markdownInlineImageProvider(
                        ETIOSMarkdownInlineImageProvider(textColor: mathTextColor, fontScale: fontScale)
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
                        codeHighlightLimit: 4_096
                    )
            }
        } else {
            Text(block.source)
                .etFont(.body, sampleText: block.source)
                .lineSpacing(lineSpacing)
                .foregroundStyle(textColor)
        }
    }

    private func resolvedStyleColor(_ slot: ChatAppearanceColorSlot?) -> Color {
        guard let slot, slot.isEnabled else { return textColor }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: textColor)
    }

    private func enabledHex(_ slot: ChatAppearanceColorSlot?) -> String? {
        guard let slot, slot.isEnabled else { return nil }
        return slot.hex
    }

    private func resolvedMarkdownContent(
        _ payload: ETPreparedMarkdownRenderPayload
    ) -> MarkdownContent {
        guard enableAdvancedRenderer,
              enableMathRendering,
              payload.containsMathContent,
              !payload.containsMermaidContent,
              let native = payload.nativeMathMarkdownContent else {
            return payload.markdownContent
        }
        return native
    }
}
