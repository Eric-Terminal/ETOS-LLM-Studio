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
    let streamingDisplayMode: ChatStreamingDisplayMode

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preparedBlocks: [ETStreamingMarkdownBlockID: ETIOSPreparedStreamingMarkdownBlock] = [:]
    @State private var animatedContentHeight: CGFloat = 0

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
        ZStack(alignment: .topLeading) {
            streamingContent
                .modifier(
                    ETStreamingTextRiseEffect(
                        animatedHeight: animatedContentHeight,
                        targetHeight: animatedContentHeight
                    )
                )
        }
        // 文字层只在自己的布局区域内上抬；新行从底部显现，绝不会越过气泡与输入栏边界。
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            updateAnimatedContentHeight(newHeight)
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
    }

    @ViewBuilder
    private var streamingContent: some View {
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
                            lineSpacing: lineSpacing,
                            streamingDisplayMode: streamingDisplayMode
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
        // 网络分块只改变文字与高度，不继承气泡入场等外层动画，避免高速重排横向漂移。
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func updateAnimatedContentHeight(_ newHeight: CGFloat) {
        guard newHeight.isFinite,
              newHeight > 0,
              abs(newHeight - animatedContentHeight) > 0.5 else {
            return
        }

        guard animatedContentHeight > 0,
              newHeight > animatedContentHeight,
              !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                animatedContentHeight = newHeight
            }
            return
        }

        // 高度是实际布局位置，动画值从当前呈现进度继续追赶；连续 token 不会重置运动轨迹。
        withAnimation(
            .spring(
                response: streamingDisplayMode.textRevealDuration,
                dampingFraction: 1
            )
        ) {
            animatedContentHeight = newHeight
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

/// 实际布局已经贴底时，用尚未完成的高度差补偿文字位置，只改变绘制层而不参与测量。
struct ETStreamingTextRiseEffect: GeometryEffect {
    var animatedHeight: CGFloat
    let targetHeight: CGFloat

    var animatableData: CGFloat {
        get { animatedHeight }
        set { animatedHeight = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: 0,
                y: Self.translationY(
                    targetHeight: targetHeight,
                    animatedHeight: animatedHeight
                )
            )
        )
    }

    nonisolated static func translationY(
        targetHeight: CGFloat,
        animatedHeight: CGFloat
    ) -> CGFloat {
        max(targetHeight - animatedHeight, 0)
    }
}
