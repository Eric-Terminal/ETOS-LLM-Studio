// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 聊天气泡内 Markdown、数学公式与 Mermaid 内容的渲染入口。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import ETOSCore

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let preparedContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let customTextColor: Color?
    var customTextStyleColors: ChatAppearanceTextStyleColors? = nil
    var isStreaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var preparedRuleRequest: ChatAppearanceTextRuleRenderRequest?
    @State private var ruleAttributedText: AttributedString?

    private var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        guard let preparedContent, preparedContent.sourceText == content else {
            return nil
        }
        return preparedContent
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        let fontScale = FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts)
        Group {
            if preparedRuleRequest == ruleRenderRequest,
               let ruleAttributedText {
                Text(ruleAttributedText)
                    .etFont(.body, sampleText: content)
                    .foregroundStyle(textColor)
            } else if enableMarkdown {
                if let streamingLineParts {
                    streamingLineMarkdownView(
                        prefix: streamingLineParts.prefix,
                        activeLine: streamingLineParts.activeLine,
                        textColor: textColor,
                        fontScale: fontScale
                    )
                } else if let prepared = effectivePreparedContent {
                    if shouldUseWebRenderer(prepared) {
                        ETMathWebMarkdownView(
                            content: prepared.normalizedText,
                            enableMarkdown: enableMarkdown,
                            isOutgoing: isOutgoing,
                            customTextHex: customTextColor.flatMap { ChatAppearanceColorCodec.hexRGBA(from: $0) },
                            customEmphasisTextHex: enabledHex(customTextStyleColors?.emphasis),
                            customStrongTextHex: enabledHex(customTextStyleColors?.strong),
                            customCodeTextHex: enabledHex(customTextStyleColors?.code),
                            prefersDarkPalette: colorScheme == .dark,
                            fontScale: fontScale
                        )
                    } else {
                        let markdownContent = resolvedMarkdownContent(for: prepared)
                        markdownTextView(
                            markdownContent: markdownContent,
                            sampleText: prepared.sourceText,
                            textColor: textColor,
                            fontScale: fontScale
                        )
                    }
                } else {
                    markdownTextView(
                        markdownContent: MarkdownContent(content),
                        sampleText: content,
                        textColor: textColor,
                        fontScale: fontScale
                    )
                }
            } else {
                plainTextView(content, textColor: textColor)
            }
        }
        .task(id: ruleRenderRequest) {
            guard let request = ruleRenderRequest else {
                preparedRuleRequest = nil
                ruleAttributedText = nil
                return
            }
            let prepared = await ChatAppearanceTextRuleRenderer.shared.prepare(request: request)
            guard !Task.isCancelled else { return }
            preparedRuleRequest = request
            ruleAttributedText = prepared
        }
    }

    private var ruleRenderRequest: ChatAppearanceTextRuleRenderRequest? {
        guard !isStreaming,
              let customTextStyleColors,
              !customTextStyleColors.customRules.isEmpty else {
            return nil
        }
        return ChatAppearanceTextRuleRenderRequest(
            source: content,
            usesMarkdown: enableMarkdown,
            styleColors: customTextStyleColors
        )
    }

    // 流式期间只把短的最后一行作为活动文本，避免整泡切纯文本或扫过气泡背景。
    private var streamingLineParts: (prefix: String, activeLine: String)? {
        guard isStreaming, !content.isEmpty else {
            return nil
        }
        let prefix: String
        let activeLine: String
        if let lineBreak = content.lastIndex(of: "\n") {
            let activeLineStart = content.index(after: lineBreak)
            prefix = String(content[..<activeLineStart])
            activeLine = String(content[activeLineStart...])
        } else {
            prefix = ""
            activeLine = content
        }
        guard !activeLine.isEmpty,
              activeLine.utf16.count <= 96,
              (prefix.isEmpty || !containsUnclosedFence(in: prefix)) else {
            return nil
        }
        return (prefix, activeLine)
    }

    private func shouldUseWebRenderer(_ prepared: ETPreparedMarkdownRenderPayload) -> Bool {
        guard enableAdvancedRenderer else { return false }
        let hasMermaid = enableMarkdown && prepared.containsMermaidContent
        return hasMermaid
    }

    private func resolvedMarkdownContent(for prepared: ETPreparedMarkdownRenderPayload) -> MarkdownContent {
        guard enableAdvancedRenderer,
              enableMathRendering,
              prepared.containsMathContent,
              !prepared.containsMermaidContent,
              let nativeMathMarkdownContent = prepared.nativeMathMarkdownContent else {
            return prepared.markdownContent
        }
        return nativeMathMarkdownContent
    }

    @ViewBuilder
    private func markdownTextView(
        markdownContent: MarkdownContent,
        sampleText: String,
        textColor: Color,
        fontScale: Double
    ) -> some View {
        let mathTextColor = ETIOSMathColorComponents(textColor)
        let emphasisTextColor = resolvedStyleColor(customTextStyleColors?.emphasis, fallback: textColor)
        let strongTextColor = resolvedStyleColor(customTextStyleColors?.strong, fallback: textColor)
        let codeTextColor = resolvedStyleColor(customTextStyleColors?.code, fallback: textColor)
        Markdown(markdownContent)
            .markdownImageProvider(
                ETIOSMarkdownImageProvider(textColor: mathTextColor, fontScale: fontScale)
            )
            .markdownInlineImageProvider(
                ETIOSMarkdownInlineImageProvider(textColor: mathTextColor, fontScale: fontScale)
            )
            .etChatMarkdownBaseStyle(
                textColor: textColor,
                emphasisTextColor: emphasisTextColor,
                strongTextColor: strongTextColor,
                codeTextColor: codeTextColor,
                usesCustomCodeTextColor: customTextStyleColors?.usesAutomaticCodeSyntaxHighlighting == false,
                isOutgoing: isOutgoing,
                prefersDarkPalette: colorScheme == .dark,
                sampleText: sampleText,
                fontScale: fontScale,
                codeHighlightLimit: isStreaming ? 4_096 : 12_000
            )
    }

    @ViewBuilder
    private func streamingLineMarkdownView(
        prefix: String,
        activeLine: String,
        textColor: Color,
        fontScale: Double
    ) -> some View {
        let normalizedFontScale = CGFloat(FontLibrary.normalizedFontScale(fontScale))
        VStack(alignment: .leading, spacing: 0) {
            if !prefix.isEmpty {
                markdownTextView(
                    markdownContent: MarkdownContent(prefix),
                    sampleText: prefix,
                    textColor: textColor,
                    fontScale: fontScale
                )
            }
            ETStreamingActiveLineText(
                text: activeLine,
                textColor: textColor,
                lineSpacing: 3 * normalizedFontScale
            )
            .padding(.top, prefix.isEmpty ? 0 : 3 * normalizedFontScale)
        }
    }

    @ViewBuilder
    private func plainTextView(_ text: String, textColor: Color) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .foregroundStyle(textColor)
    }

    private func resolvedStyleColor(_ slot: ChatAppearanceColorSlot?, fallback: Color) -> Color {
        guard let slot, slot.isEnabled else { return fallback }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: fallback)
    }

    private func enabledHex(_ slot: ChatAppearanceColorSlot?) -> String? {
        guard let slot, slot.isEnabled else { return nil }
        return slot.hex
    }

    private func containsUnclosedFence(in text: String) -> Bool {
        var openedFence: (marker: Character, count: Int)?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = trimmed.first, marker == "`" || marker == "~" else {
                continue
            }
            let count = trimmed.prefix { $0 == marker }.count
            guard count >= 3 else { continue }
            if let current = openedFence {
                if current.marker == marker && count >= current.count {
                    openedFence = nil
                }
            } else {
                openedFence = (marker, count)
            }
        }
        return openedFence != nil
    }
}

private struct ETStreamingActiveLineText: View {
    let text: String
    let textColor: Color
    let lineSpacing: CGFloat
    var fadeDuration: TimeInterval = 0.22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settledText = ""
    @State private var fadingTail = ""
    @State private var tailOpacity = 1.0
    @State private var targetText = ""
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        displayText
            .etFont(.body, sampleText: text)
            .lineSpacing(lineSpacing)
            .onAppear {
                reset(to: text)
            }
            .onChange(of: text) { _, newText in
                update(to: newText)
            }
            .onDisappear {
                settleTask?.cancel()
            }
    }

    private var displayText: Text {
        let base = Text(verbatim: settledText).foregroundColor(textColor)
        guard !fadingTail.isEmpty else { return base }
        return base + Text(verbatim: fadingTail).foregroundColor(textColor.opacity(tailOpacity))
    }

    private func update(to newText: String) {
        let displayedText = settledText + fadingTail
        settleTask?.cancel()

        guard !reduceMotion,
              newText.hasPrefix(displayedText),
              newText.count > displayedText.count else {
            reset(to: newText)
            return
        }

        let tail = String(newText.dropFirst(displayedText.count))
        guard !tail.isEmpty else {
            reset(to: newText)
            return
        }

        targetText = newText
        settledText = displayedText
        fadingTail = tail
        tailOpacity = 0
        withAnimation(.easeOut(duration: fadeDuration)) {
            tailOpacity = 1
        }

        settleTask = Task { @MainActor in
            let delay = UInt64((fadeDuration + 0.04) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, targetText == newText else { return }
            settledText = newText
            fadingTail = ""
            tailOpacity = 1
        }
    }

    private func reset(to newText: String) {
        settleTask?.cancel()
        targetText = newText
        settledText = newText
        fadingTail = ""
        tailOpacity = 1
    }
}
