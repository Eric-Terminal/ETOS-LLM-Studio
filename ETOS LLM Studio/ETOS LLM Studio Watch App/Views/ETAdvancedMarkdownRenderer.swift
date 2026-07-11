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
    let onCodeBlockHeaderTap: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var imagePreviewItem: ETWatchMarkdownImagePreviewItem?
    @State private var preparedRuleRequest: ChatAppearanceTextRuleRenderRequest?
    @State private var ruleAttributedText: AttributedString?

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
        self.onCodeBlockHeaderTap = onCodeBlockHeaderTap
    }

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
                    markdownTextView(
                        markdownContent: prepared.markdownContent,
                        sampleText: prepared.sourceText,
                        textColor: textColor,
                        fontScale: fontScale
                    )
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
              activeLine.utf16.count <= 48,
              (prefix.isEmpty || !containsUnclosedFence(in: prefix)) else {
            return nil
        }
        return (prefix, activeLine)
    }

    @ViewBuilder
    private func markdownTextView(
        markdownContent: MarkdownContent,
        sampleText: String,
        textColor: Color,
        fontScale: Double
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
                codeHighlightLimit: isStreaming ? 4_096 : 12_000,
                onCodeBlockHeaderTap: onCodeBlockHeaderTap
            )
            .sheet(item: $imagePreviewItem) { item in
                ETWatchMarkdownImagePreviewSheet(item: item)
            }
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
                lineSpacing: 2 * normalizedFontScale
            )
            .padding(.top, prefix.isEmpty ? 0 : 2 * normalizedFontScale)
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
    var fadeDuration: TimeInterval = 0.18

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

private extension View {
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
                            .relativeLineSpacing(.em(0.12))
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
    }
}
