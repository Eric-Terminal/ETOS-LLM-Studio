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
    let preparedContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let customTextColor: Color?
    let onCodeBlockHeaderTap: ((String) -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @AppStorage(FontLibrary.customFontEnabledStorageKey) var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fontScaleStorageKey) var customFontScale: Double = FontLibrary.defaultFontScale
    @State var imagePreviewItem: ETWatchMarkdownImagePreviewItem?

    init(
        content: String,
        preparedContent: ETPreparedMarkdownRenderPayload? = nil,
        enableMarkdown: Bool,
        isOutgoing: Bool,
        enableAdvancedRenderer: Bool,
        enableMathRendering: Bool,
        customTextColor: Color? = nil,
        onCodeBlockHeaderTap: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.preparedContent = preparedContent
        self.enableMarkdown = enableMarkdown
        self.isOutgoing = isOutgoing
        self.enableAdvancedRenderer = enableAdvancedRenderer
        self.enableMathRendering = enableMathRendering
        self.customTextColor = customTextColor
        self.onCodeBlockHeaderTap = onCodeBlockHeaderTap
    }

    var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        guard let preparedContent, preparedContent.sourceText == content else {
            return nil
        }
        return preparedContent
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        let fontScale = FontLibrary.effectiveFontScale(customFontScale, isCustomFontEnabled: isCustomFontEnabled)
        if enableMarkdown {
            if let prepared = effectivePreparedContent {
                if shouldUseMathEngine(prepared) {
                    ETMathAwareMarkdownView(
                        preparedContent: prepared,
                        isOutgoing: isOutgoing,
                        customTextColor: customTextColor,
                        fontScale: fontScale
                    )
                } else {
                    markdownTextView(
                        markdownContent: prepared.markdownContent,
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

    func shouldUseMathEngine(_ prepared: ETPreparedMarkdownRenderPayload) -> Bool {
        enableAdvancedRenderer && enableMathRendering && prepared.containsMathContent
    }

    @ViewBuilder
    func markdownTextView(
        markdownContent: MarkdownContent,
        sampleText: String,
        textColor: Color,
        fontScale: Double
    ) -> some View {
        Markdown(markdownContent)
            .markdownImageProvider(
                ETWatchMarkdownImageProvider { item in
                    imagePreviewItem = item
                }
            )
            .etChatMarkdownBaseStyle(
                textColor: textColor,
                isOutgoing: isOutgoing,
                prefersDarkPalette: colorScheme == .dark,
                sampleText: sampleText,
                fontScale: fontScale,
                onCodeBlockHeaderTap: onCodeBlockHeaderTap
            )
            .sheet(item: $imagePreviewItem) { item in
                ETWatchMarkdownImagePreviewSheet(item: item)
            }
    }

    @ViewBuilder
    func plainTextView(_ text: String, textColor: Color) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .foregroundStyle(textColor)
    }
}


// TODO: 后续评估让 watchOS 直接消费 iPhone 侧预渲染的高质量公式/图表资源，避免手表端继续背实时渲染依赖。
struct ETMathAwareMarkdownView: View {
    let preparedContent: ETPreparedMarkdownRenderPayload
    let isOutgoing: Bool
    let customTextColor: Color?
    let fontScale: Double

    var textColor: Color {
        customTextColor ?? (isOutgoing ? .white : .primary)
    }

    var inlineMathFontSize: CGFloat {
        17 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
    }

    var blockMathFontSize: CGFloat {
        20 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
    }

    var blocks: [ETMathRenderBlock] {
        ETMathRenderBlock.build(from: preparedContent.mathSegments)
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
                            style: ETMathStyle(fontSize: blockMathFontSize, textColor: textColor)
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
    func renderLine(_ parts: [ETInlineRenderPart]) -> some View {
        if parts.contains(where: \.isMath) {
            let tokens = ETInlineRenderToken.tokens(from: parts)
            ETInlineMathFlowLayout(itemSpacing: 0, lineSpacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .text(let text):
                        Text(verbatim: text)
                            .etFont(.body, sampleText: text)
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: true, vertical: true)
                    case .math(let latex):
                        ETMathView(
                            latex: latex,
                            displayMode: .inline,
                            style: ETMathStyle(fontSize: inlineMathFontSize, textColor: textColor)
                        )
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let text = parts.compactMap(\.textValue).joined()
            Text(verbatim: text)
                .etFont(.body, sampleText: text)
                .foregroundStyle(textColor)
        }
    }
}


extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(
        textColor: Color,
        isOutgoing: Bool,
        prefersDarkPalette: Bool,
        sampleText: String,
        fontScale: Double,
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
                    baseColor: textColor,
                    isOutgoing: isOutgoing,
                    prefersDarkPalette: prefersDarkPalette
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
                ForegroundColor(textColor)
            }
            .markdownTextStyle(\.strong) {
                if !usesCharacterFallback,
                   let strongFontName,
                   !strongFontName.isEmpty {
                    FontFamily(.custom(strongFontName))
                }
                ForegroundColor(textColor)
            }
            .markdownTextStyle(\.code) {
                if !usesCharacterFallback,
                   let codeFontName,
                   !codeFontName.isEmpty {
                    FontFamily(.custom(codeFontName))
                } else {
                    FontFamily(.system(.monospaced))
                }
                ForegroundColor(textColor)
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
                                ForegroundColor(textColor)
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


struct ETWatchMarkdownImagePreviewItem: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}


struct ETWatchMarkdownImageProvider: ImageProvider {
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    func makeImage(url: URL?) -> some View {
        ETWatchMarkdownImageThumbnail(
            url: url,
            onActivate: onActivate
        )
    }
}


struct ETWatchMarkdownImageThumbnail: View {
    let url: URL?
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    let cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .empty:
                        loadingPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    case .failure:
                        failurePlaceholder
                    @unknown default:
                        failurePlaceholder
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture {
                    onActivate(.init(url: url))
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(NSLocalizedString("点按后可使用数码表冠缩放图片", comment: ""))
            } else {
                failurePlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }
    }

    var failurePlaceholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .etFont(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("图片载入失败", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
    }
}


struct ETWatchMarkdownImagePreviewSheet: View {
    let item: ETWatchMarkdownImagePreviewItem

    @State var zoomScale = 1.0
    @State var settledOffset: CGSize = .zero
    @GestureState var dragTranslation: CGSize = .zero

    let maxZoomScale = 6.0
    let contentInset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                AsyncImage(url: item.url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .empty:
                        loadingState
                    case .success(let image):
                        previewImage(
                            image,
                            containerSize: proxy.size
                        )
                    case .failure:
                        failureState
                    @unknown default:
                        failureState
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .focusable(true)
            .digitalCrownRotation(
                $zoomScale,
                from: 1.0,
                through: maxZoomScale,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: zoomScale) { _, newValue in
                if newValue <= 1.01 {
                    settledOffset = .zero
                } else {
                    settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                        proposed: settledOffset,
                        containerSize: proxy.size,
                        contentSize: CGSize(
                            width: max(proxy.size.width - contentInset * 2, 1),
                            height: max(proxy.size.height - contentInset * 2, 1)
                        ),
                        scale: CGFloat(newValue)
                    )
                }
            }
        }
    }

    var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(NSLocalizedString("正在载入图片", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }

    var failureState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .etFont(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
            Text(NSLocalizedString("图片载入失败", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(12)
    }

    func previewImage(_ image: Image, containerSize: CGSize) -> some View {
        let contentSize = CGSize(
            width: max(containerSize.width - contentInset * 2, 1),
            height: max(containerSize.height - contentInset * 2, 1)
        )
        let effectiveOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
            proposed: CGSize(
                width: settledOffset.width + dragTranslation.width,
                height: settledOffset.height + dragTranslation.height
            ),
            containerSize: containerSize,
            contentSize: contentSize,
            scale: CGFloat(zoomScale)
        )

        return image
            .resizable()
            .scaledToFit()
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(CGFloat(zoomScale))
            .offset(effectiveOffset)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, state, _ in
                        guard zoomScale > 1.01 else {
                            state = .zero
                            return
                        }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard zoomScale > 1.01 else {
                            settledOffset = .zero
                            return
                        }
                        settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                            proposed: CGSize(
                                width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height
                            ),
                            containerSize: containerSize,
                            contentSize: contentSize,
                            scale: CGFloat(zoomScale)
                        )
                    }
            )
    }
}


enum ETWatchMarkdownImageZoomMath {
    static func clampedOffset(
        proposed: CGSize,
        containerSize: CGSize,
        contentSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale > 1,
              containerSize.width > 0,
              containerSize.height > 0,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return .zero
        }

        let maxX = max((contentSize.width * scale - containerSize.width) / 2, 0)
        let maxY = max((contentSize.height * scale - containerSize.height) / 2, 0)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}


struct ETWatchCollapsibleCodeBlockView<HeaderActions: View, BodyContent: View>: View {
    let language: String?
    let headerTextColor: Color
    let headerBackground: Color
    let blockBackground: Color
    let borderColor: Color
    let onHeaderTap: (() -> Void)?
    @ViewBuilder let headerActions: (_ isCollapsed: Bool) -> HeaderActions
    @ViewBuilder let bodyContent: () -> BodyContent

    @State var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                codeBlockTitle

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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(blockBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    var codeBlockTitle: some View {
        if let onHeaderTap {
            Button(action: onHeaderTap) {
                codeBlockTitleLabel
            }
            .buttonStyle(.plain)
        } else {
            codeBlockTitleLabel
        }
    }

    var codeBlockTitleLabel: some View {
        Text(language?.isEmpty == false ? (language ?? NSLocalizedString("代码", comment: "")) : NSLocalizedString("代码", comment: ""))
            .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(headerTextColor)
            .contentShape(Rectangle())
    }
}


struct ETCodeCollapseButton: View {
    let isCollapsed: Bool
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .etFont(.system(size: 10, weight: .semibold))
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

    @State var didCopy = false

    var body: some View {
        Button {
            ETCodeClipboard.copy(content)
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif

            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .etFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(didCopy ? successColor : normalColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("复制代码", comment: ""))
    }
}
