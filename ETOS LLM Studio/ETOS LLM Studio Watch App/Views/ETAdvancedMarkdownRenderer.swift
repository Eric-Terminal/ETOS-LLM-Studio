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
import ETOSCore

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let preparedContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let customTextColor: Color?
    let customTextStyleColors: ChatAppearanceTextStyleColors?
    let isStreaming: Bool
    let streamingState: ETStreamingMarkdownRenderState?
    let streamingChannel: ETStreamingMarkdownChannel
    let onCodeBlockHeaderTap: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var imagePreviewItem: ETWatchMarkdownImagePreviewItem?
    @State private var preparedRuleRequest: ChatAppearanceTextRuleRenderRequest?
    @State private var ruleAttributedText: AttributedString?
    @State private var asynchronouslyPreparedContent: ETPreparedMarkdownRenderPayload?

    init(
        content: String,
        preparedContent: ETPreparedMarkdownRenderPayload? = nil,
        enableMarkdown: Bool,
        isOutgoing: Bool,
        enableAdvancedRenderer: Bool,
        enableMathRendering: Bool,
        customTextColor: Color? = nil,
        customTextStyleColors: ChatAppearanceTextStyleColors? = nil,
        isStreaming: Bool = false,
        streamingState: ETStreamingMarkdownRenderState? = nil,
        streamingChannel: ETStreamingMarkdownChannel = .content,
        onCodeBlockHeaderTap: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.preparedContent = preparedContent
        self.enableMarkdown = enableMarkdown
        self.isOutgoing = isOutgoing
        self.enableAdvancedRenderer = enableAdvancedRenderer
        self.enableMathRendering = enableMathRendering
        self.customTextColor = customTextColor
        self.customTextStyleColors = customTextStyleColors
        self.isStreaming = isStreaming
        self.streamingState = streamingState
        self.streamingChannel = streamingChannel
        self.onCodeBlockHeaderTap = onCodeBlockHeaderTap
    }

    private var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        if let preparedContent, preparedContent.sourceText == content {
            return preparedContent
        }
        guard asynchronouslyPreparedContent?.sourceText == content else { return nil }
        return asynchronouslyPreparedContent
    }

    private var shouldUseStreamingRenderer: Bool {
        if isStreaming { return true }
        guard enableMarkdown,
              effectivePreparedContent == nil,
              let streamingState,
              streamingState.snapshot(for: streamingChannel) != nil else {
            return false
        }
        return streamingState.isAwaitingStaticHandoff(channel: streamingChannel)
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        let fontScale = FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts)
        let lineSpacingEm = FontLibrary.normalizedLineSpacingEm(
            appConfig.fontLineSpacingEmWatchOS,
            fallback: FontLibrary.defaultWatchLineSpacingEm
        )
        let lineSpacing = CGFloat(
            FontLibrary.lineSpacingPoints(
                basePointSize: 16,
                lineSpacingEm: lineSpacingEm,
                fontScale: appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts,
                fallbackLineSpacingEm: FontLibrary.defaultWatchLineSpacingEm
            )
        )
        Group {
            if preparedRuleRequest == ruleRenderRequest,
               let ruleAttributedText {
                Text(ruleAttributedText)
                    .etFont(.body, sampleText: content)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(textColor)
            } else if shouldUseStreamingRenderer, let streamingState {
                ETWatchStreamingMarkdownLiveView(
                    state: streamingState,
                    channel: streamingChannel,
                    fallbackText: content,
                    enableMarkdown: enableMarkdown,
                    isOutgoing: isOutgoing,
                    textColor: textColor,
                    customTextStyleColors: customTextStyleColors,
                    fontScale: fontScale,
                    lineSpacing: lineSpacing,
                    onCodeBlockHeaderTap: onCodeBlockHeaderTap
                )
            } else if enableMarkdown {
                if let prepared = effectivePreparedContent {
                    markdownTextView(
                        markdownContent: prepared.markdownContent,
                        sampleText: prepared.sourceText,
                        textColor: textColor,
                        fontScale: fontScale,
                        lineSpacing: lineSpacing
                    )
                } else {
                    plainTextView(content, textColor: textColor, lineSpacing: lineSpacing)
                }
            } else {
                plainTextView(content, textColor: textColor, lineSpacing: lineSpacing)
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
        .task(id: fallbackMarkdownRequest) {
            guard fallbackMarkdownRequest != nil else {
                asynchronouslyPreparedContent = nil
                return
            }
            let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: content)
            guard !Task.isCancelled else { return }
            asynchronouslyPreparedContent = prepared
        }
    }

    private var fallbackMarkdownRequest: String? {
        guard enableMarkdown,
              !isStreaming,
              preparedContent?.sourceText != content else { return nil }
        return content
    }

    private var ruleRenderRequest: ChatAppearanceTextRuleRenderRequest? {
        guard !isStreaming else { return nil }
        let fontRules = FontLibrary.resolvedTextFontRules()
        let resolvedStyleColors = customTextStyleColors
            ?? ChatAppearanceTextStyleColors(defaultHex: "000000FF")
        guard !resolvedStyleColors.customRules.isEmpty || !fontRules.isEmpty else { return nil }
        return ChatAppearanceTextRuleRenderRequest(
            source: content,
            usesMarkdown: enableMarkdown,
            styleColors: resolvedStyleColors,
            fontRules: fontRules,
            fontPointSize: 15,
            fontScale: FontLibrary.customFontScale,
            fontFallbackScope: FontLibrary.fallbackScope
        )
    }

    @ViewBuilder
    private func markdownTextView(
        markdownContent: MarkdownContent,
        sampleText: String,
        textColor: Color,
        fontScale: Double,
        lineSpacing: CGFloat
    ) -> some View {
        let emphasisTextColor = resolvedStyleColor(customTextStyleColors?.emphasis, fallback: textColor)
        let strongTextColor = resolvedStyleColor(customTextStyleColors?.strong, fallback: textColor)
        let codeTextColor = resolvedStyleColor(customTextStyleColors?.code, fallback: textColor)
        Markdown(markdownContent)
            .markdownImageProvider(
                ETWatchMarkdownImageProvider { item in
                    imagePreviewItem = item
                }
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
                lineSpacing: lineSpacing,
                codeHighlightLimit: isStreaming ? 4_096 : 12_000,
                onCodeBlockHeaderTap: onCodeBlockHeaderTap
            )
            .sheet(item: $imagePreviewItem) { item in
                ETWatchMarkdownImagePreviewSheet(item: item)
            }
    }

    @ViewBuilder
    private func plainTextView(_ text: String, textColor: Color, lineSpacing: CGFloat) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .lineSpacing(lineSpacing)
            .foregroundStyle(textColor)
    }

    private func resolvedStyleColor(_ slot: ChatAppearanceColorSlot?, fallback: Color) -> Color {
        guard let slot, slot.isEnabled else { return fallback }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: fallback)
    }

}

extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(
        textColor: Color,
        emphasisTextColor: Color,
        strongTextColor: Color,
        codeTextColor: Color,
        usesCustomCodeTextColor: Bool,
        isOutgoing: Bool,
        prefersDarkPalette: Bool,
        sampleText: String,
        fontScale: Double,
        lineSpacing: CGFloat,
        codeHighlightLimit: Int = 12_000,
        onCodeBlockHeaderTap: ((String) -> Void)? = nil
    ) -> some View {
        let codeBlockBackground = isOutgoing
            ? Color.white.opacity(0.16)
            : Color.primary.opacity(0.09)
        let codeHeaderBackground = isOutgoing
            ? Color.white.opacity(0.2)
            : Color.primary.opacity(0.11)
        let codeBorderColor = isOutgoing
            ? Color.white.opacity(0.24)
            : Color.primary.opacity(0.16)
        let codeHeaderTextColor = isOutgoing
            ? Color.white.opacity(0.9)
            : Color.secondary
        let bodyFontName = FontLibrary.resolvePostScriptName(for: .body, sampleText: sampleText)
        let emphasisFontName = FontLibrary.resolvePostScriptName(for: .emphasis, sampleText: sampleText)
        let strongFontName = FontLibrary.resolvePostScriptName(for: .strong, sampleText: sampleText)
        let codeFontName = FontLibrary.resolvePostScriptName(for: .code, sampleText: sampleText)
        let usesCharacterFallback = FontLibrary.fallbackScope == .character
        let bodyFontSize = CGFloat(16 * FontLibrary.normalizedFontScale(fontScale))

        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownCodeSyntaxHighlighter(
                ETCodeSyntaxHighlighter(
                    baseColor: codeTextColor,
                    isOutgoing: isOutgoing,
                    prefersDarkPalette: prefersDarkPalette,
                    syntaxHighlightingEnabled: !usesCustomCodeTextColor,
                    maxHighlightedLength: codeHighlightLimit
                )
            )
            .etFont(.body, sampleText: sampleText)
            .markdownTextStyle {
                if !usesCharacterFallback,
                   let bodyFontName,
                   !bodyFontName.isEmpty {
                    FontFamily(.custom(bodyFontName))
                }
                FontSize(bodyFontSize)
                ForegroundColor(textColor)
            }
            .markdownTextStyle(\.emphasis) {
                if !usesCharacterFallback,
                   let emphasisFontName,
                   !emphasisFontName.isEmpty {
                    FontFamily(.custom(emphasisFontName))
                }
                FontStyle(.italic)
                ForegroundColor(emphasisTextColor)
            }
            .markdownTextStyle(\.strong) {
                if !usesCharacterFallback,
                   let strongFontName,
                   !strongFontName.isEmpty {
                    FontFamily(.custom(strongFontName))
                }
                FontWeight(.bold)
                ForegroundColor(strongTextColor)
            }
            .markdownTextStyle(\.code) {
                if !usesCharacterFallback,
                   let codeFontName,
                   !codeFontName.isEmpty {
                    FontFamily(.custom(codeFontName))
                } else {
                    FontFamily(.system(.monospaced))
                }
                ForegroundColor(codeTextColor)
            }
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: .zero, bottom: .em(1))
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                configuration.label
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(isOutgoing ? Color.white.opacity(0.56) : Color.secondary.opacity(0.48))
                            .frame(width: 3)
                            .padding(.vertical, 2)
                    }
                    .markdownMargin(top: .em(0.2), bottom: .em(0.7))
            }
            .markdownBlockStyle(\.image) { configuration in
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .markdownMargin(top: .em(0.3), bottom: .em(0.75))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                let codeBlockContent = configuration.content.trimmingCharacters(in: .newlines)
                let canAppendCodeBlock = !codeBlockContent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    && onCodeBlockHeaderTap != nil
                ETWatchCollapsibleCodeBlockView(
                    language: configuration.language,
                    headerTextColor: codeHeaderTextColor,
                    headerBackground: codeHeaderBackground,
                    blockBackground: codeBlockBackground,
                    borderColor: codeBorderColor,
                    onHeaderTap: canAppendCodeBlock ? { onCodeBlockHeaderTap?(codeBlockContent) } : nil
                ) { isCollapsed in
                    if !isCollapsed, ETCodeClipboard.supportsCopy {
                        ETCodeCopyButton(
                            content: configuration.content,
                            normalColor: codeHeaderTextColor,
                            successColor: isOutgoing ? Color.white : Color.green
                        )
                    }
                } bodyContent: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .fixedSize(horizontal: true, vertical: true)
                            .markdownTextStyle {
                                if !usesCharacterFallback,
                                   let codeFontName,
                                   !codeFontName.isEmpty {
                                    FontFamily(.custom(codeFontName))
                                } else {
                                    FontFamily(.system(.monospaced))
                                }
                                FontSize(.em(0.88))
                                ForegroundColor(codeTextColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .markdownMargin(top: .em(0.2), bottom: .em(0.7))
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
            .markdownBlockStyle(\.tableCell) { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativePadding(.horizontal, length: .em(0.72))
                    .relativePadding(.vertical, length: .em(0.35))
            }
            .lineSpacing(lineSpacing)
    }
}
