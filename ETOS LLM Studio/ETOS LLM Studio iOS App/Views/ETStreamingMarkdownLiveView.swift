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
    @State private var preparedBlocks: [ETStreamingMarkdownBlockID: ETIOSPreparedStreamingMarkdownBlock] = [:]
    @State private var displayedSnapshot: ETStreamingMarkdownSnapshot?

    private var snapshot: ETStreamingMarkdownSnapshot? {
        state.snapshot(for: channel)
    }

    private var preparationID: ETStreamingMarkdownBlockID? {
        snapshot?.committedBlocks.last?.id
    }

    private var renderSnapshot: ETStreamingMarkdownSnapshot? {
        guard let snapshot else { return displayedSnapshot }
        if Self.canDisplayImmediately(
            enableMarkdown: enableMarkdown,
            displayedSnapshot: displayedSnapshot,
            incomingSnapshot: snapshot
        ) {
            return snapshot
        }
        return displayedSnapshot
    }

    /// 活动 Block 可立即逐字更新；新增 committed Block 必须等 Markdown 准备完成后再交给布局。
    nonisolated static func canDisplayImmediately(
        enableMarkdown: Bool,
        displayedSnapshot: ETStreamingMarkdownSnapshot?,
        incomingSnapshot: ETStreamingMarkdownSnapshot
    ) -> Bool {
        guard enableMarkdown, !incomingSnapshot.committedBlocks.isEmpty else {
            return true
        }
        guard let displayedSnapshot else { return false }
        return hasSameCommittedStructure(displayedSnapshot, incomingSnapshot)
    }

    nonisolated private static func hasSameCommittedStructure(
        _ lhs: ETStreamingMarkdownSnapshot,
        _ rhs: ETStreamingMarkdownSnapshot
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.channel == rhs.channel
            && lhs.committedBlocks.count == rhs.committedBlocks.count
            && lhs.committedBlocks.last?.id == rhs.committedBlocks.last?.id
    }

    private func interBlockSpacing(_ multiplier: Double) -> CGFloat {
        guard enableMarkdown else { return 0 }
        let rootFontSize = round(CGFloat(17 * FontLibrary.normalizedFontScale(fontScale)))
        return round(CGFloat(multiplier) * rootFontSize)
    }

    var body: some View {
        Group {
            if let snapshot = renderSnapshot {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.committedBlocks) { block in
                        committedBlockView(block)
                            .padding(.top, interBlockSpacing(block.leadingSpacingEm))
                    }
                    if let activeBlock = snapshot.activeBlock {
                        activeBlockView(activeBlock)
                    }
                }
            } else if let activeBlock = snapshot?.activeBlock {
                activeBlockView(activeBlock)
            } else {
                Text(fallbackText)
                    .etFont(.body, sampleText: fallbackText)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(textColor)
            }
        }
        .onChange(of: snapshot?.revision, initial: true) { _, _ in
            guard let snapshot else { return }
            let canDisplayImmediately = Self.canDisplayImmediately(
                enableMarkdown: enableMarkdown,
                displayedSnapshot: displayedSnapshot,
                incomingSnapshot: snapshot
            )
            #if DEBUG
            if !canDisplayImmediately {
                print(
                    "[StreamMarkdownHandoff] freeze channel=\(channel.rawValue) "
                        + "revision=\(snapshot.revision) displayedRevision=\(displayedSnapshot?.revision ?? -1) "
                        + "displayedBlocks=\(displayedSnapshot?.committedBlocks.count ?? 0) "
                        + "incomingBlocks=\(snapshot.committedBlocks.count)"
                )
            }
            #endif
            guard canDisplayImmediately else { return }
            displayedSnapshot = snapshot
        }
        .task(id: enableMarkdown ? preparationID : nil) {
            guard enableMarkdown,
                  let targetSnapshot = snapshot,
                  !targetSnapshot.committedBlocks.isEmpty else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    preparedBlocks = [:]
                    displayedSnapshot = snapshot
                }
                return
            }
            let blocks = targetSnapshot.committedBlocks
            #if DEBUG
            print(
                "[StreamMarkdownHandoff] prepare channel=\(channel.rawValue) "
                    + "revision=\(targetSnapshot.revision) blocks=\(blocks.count)"
            )
            #endif
            let prepared = await ETIOSStreamingMarkdownBlockWorker.shared.prepare(blocks)
            guard !Task.isCancelled,
                  let latestSnapshot = state.snapshot(for: channel),
                  Self.hasSameCommittedStructure(targetSnapshot, latestSnapshot) else {
                return
            }

            // 同一事务中同时发布准备结果与快照，布局不会看见纯文本占位的中间帧。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                preparedBlocks = prepared
                displayedSnapshot = latestSnapshot
            }
            #if DEBUG
            print(
                "[StreamMarkdownHandoff] publish channel=\(channel.rawValue) "
                    + "revision=\(latestSnapshot.revision) blocks=\(latestSnapshot.committedBlocks.count)"
            )
            #endif
        }
        // 网络分块只改变文字与高度，不继承气泡入场等外层动画，避免高速重排横向漂移。
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func activeBlockView(_ activeBlock: ETStreamingMarkdownActiveBlock) -> some View {
        ETStreamingMarkdownTextView(
            activeBlock: activeBlock,
            textColor: textColor,
            fontScale: fontScale,
            lineSpacing: lineSpacing,
            streamingDisplayMode: streamingDisplayMode
        )
        .padding(.top, interBlockSpacing(activeBlock.leadingSpacingEm))
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
        } else if !enableMarkdown {
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
