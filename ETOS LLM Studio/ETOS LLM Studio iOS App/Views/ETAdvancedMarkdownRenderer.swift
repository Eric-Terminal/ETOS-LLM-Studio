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
    var isStreaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared

    private var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        guard let preparedContent, preparedContent.sourceText == content else {
            return nil
        }
        return preparedContent
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        let fontScale = FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts)
        if enableMarkdown {
            if let prepared = effectivePreparedContent {
                if shouldUseWebRenderer(prepared) {
                    ETMathWebMarkdownView(
                        content: prepared.normalizedText,
                        enableMarkdown: enableMarkdown,
                        isOutgoing: isOutgoing,
                        customTextHex: customTextColor.flatMap { ChatAppearanceColorCodec.hexRGBA(from: $0) },
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
        Markdown(markdownContent)
            .markdownImageProvider(
                ETIOSMarkdownImageProvider(textColor: mathTextColor, fontScale: fontScale)
            )
            .markdownInlineImageProvider(
                ETIOSMarkdownInlineImageProvider(textColor: mathTextColor, fontScale: fontScale)
            )
            .etChatMarkdownBaseStyle(
                textColor: textColor,
                isOutgoing: isOutgoing,
                prefersDarkPalette: colorScheme == .dark,
                sampleText: sampleText,
                fontScale: fontScale,
                codeHighlightLimit: isStreaming ? 4_096 : 12_000
            )
    }

    @ViewBuilder
    private func plainTextView(_ text: String, textColor: Color) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .foregroundStyle(textColor)
    }
}
