// ============================================================================
// ETAdvancedMarkdownRendererStyle.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ETAdvancedMarkdownRenderer 的 MarkdownUI 文本、表格和代码块样式。
// ============================================================================

import SwiftUI
import MarkdownUI
import ETOSCore

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
        codeHighlightLimit: Int = 12_000
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
        // 标题与操作按钮沿用正文色，避免自定义气泡颜色下固定白色失去对比度。
        let codeHeaderTextColor = textColor
        let bodyFontName = FontLibrary.resolvePostScriptName(for: .body, sampleText: sampleText)
        let emphasisFontName = FontLibrary.resolvePostScriptName(for: .emphasis, sampleText: sampleText)
        let strongFontName = FontLibrary.resolvePostScriptName(for: .strong, sampleText: sampleText)
        let codeFontName = FontLibrary.resolvePostScriptName(for: .code, sampleText: sampleText)
        let usesCharacterFallback = FontLibrary.fallbackScope == .character
        let bodyFontSize = CGFloat(17 * FontLibrary.normalizedFontScale(fontScale))

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
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(isOutgoing ? Color.white.opacity(0.56) : Color.secondary.opacity(0.48))
                            .frame(width: 3)
                            .padding(.vertical, 2)
                    }
                    .markdownMargin(top: .em(0.2), bottom: .em(0.75))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ETCollapsibleCodeBlockView(
                    language: configuration.language,
                    headerTextColor: codeHeaderTextColor,
                    headerBackground: codeHeaderBackground,
                    blockBackground: codeBlockBackground,
                    borderColor: codeBorderColor
                ) { isCollapsed in
                    if !isCollapsed {
                        if ETCodePreviewSupport.canPreview(configuration.language) {
                            ETCodePreviewButton(
                                content: configuration.content,
                                language: configuration.language,
                                tintColor: codeHeaderTextColor
                            )
                        }

                        if ETCodeClipboard.supportsCopy {
                            ETCodeCopyButton(
                                content: configuration.content,
                                normalColor: codeHeaderTextColor,
                                successColor: isOutgoing ? Color.white : Color.green
                            )
                        }
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
                                FontSize(.em(0.9))
                                ForegroundColor(codeTextColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .markdownMargin(top: .em(0.2), bottom: .em(0.75))
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

struct ETCollapsibleCodeBlockView<HeaderActions: View, BodyContent: View>: View {
    let language: String?
    let headerTextColor: Color
    let headerBackground: Color
    let blockBackground: Color
    let borderColor: Color
    @ViewBuilder let headerActions: (_ isCollapsed: Bool) -> HeaderActions
    @ViewBuilder let bodyContent: () -> BodyContent

    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? (language ?? NSLocalizedString("代码", comment: "")) : NSLocalizedString("代码", comment: ""))
                    .etFont(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(headerTextColor)

                Spacer(minLength: 8)

                headerActions(isCollapsed)

                ETCodeCollapseButton(
                    isCollapsed: isCollapsed,
                    tintColor: headerTextColor
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isCollapsed.toggle()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(headerBackground)
                }
            }

            if !isCollapsed {
                bodyContent()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isCollapsed)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(blockBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

struct ETCodeCollapseButton: View {
    let isCollapsed: Bool
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? NSLocalizedString("展开代码块", comment: "") : NSLocalizedString("折叠代码块", comment: ""))
    }
}

enum ETCodeClipboard {
    static var supportsCopy: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func copy(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #endif
    }
}

struct ETCodeCopyButton: View {
    let content: String
    let normalColor: Color
    let successColor: Color

    var body: some View {
        CopyConfirmationButton {
            ETCodeClipboard.copy(content)
        } label: { didCopy in
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(didCopy ? successColor : normalColor)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(
                    didCopy
                        ? NSLocalizedString("已复制", comment: "")
                        : NSLocalizedString("复制代码", comment: "")
                )
        }
        .buttonStyle(.plain)
    }
}
