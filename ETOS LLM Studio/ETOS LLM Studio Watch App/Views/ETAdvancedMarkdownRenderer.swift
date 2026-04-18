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
    @Environment(\.colorScheme) private var colorScheme
    @State private var imagePreviewItem: ETWatchMarkdownImagePreviewItem?

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

    private var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        guard let preparedContent, preparedContent.sourceText == content else {
            return nil
        }
        return preparedContent
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        if enableMarkdown {
            if let prepared = effectivePreparedContent {
                if shouldUseMathEngine(prepared) {
                    ETMathAwareMarkdownView(
                        preparedContent: prepared,
                        isOutgoing: isOutgoing,
                        customTextColor: customTextColor
                    )
                } else {
                    markdownTextView(
                        markdownContent: prepared.markdownContent,
                        sampleText: prepared.sourceText,
                        textColor: textColor
                    )
                }
            } else {
                markdownTextView(
                    markdownContent: MarkdownContent(content),
                    sampleText: content,
                    textColor: textColor
                )
            }
        } else {
            plainTextView(content, textColor: textColor)
        }
    }

    private func shouldUseMathEngine(_ prepared: ETPreparedMarkdownRenderPayload) -> Bool {
        enableAdvancedRenderer && enableMathRendering && prepared.containsMathContent
    }

    @ViewBuilder
    private func markdownTextView(
        markdownContent: MarkdownContent,
        sampleText: String,
        textColor: Color
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
                onCodeBlockHeaderTap: onCodeBlockHeaderTap
            )
            .sheet(item: $imagePreviewItem) { item in
                ETWatchMarkdownImagePreviewSheet(item: item)
            }
    }

    @ViewBuilder
    private func plainTextView(_ text: String, textColor: Color) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .foregroundStyle(textColor)
    }
}

private struct ETMathAwareMarkdownView: View {
    let preparedContent: ETPreparedMarkdownRenderPayload
    let isOutgoing: Bool
    let customTextColor: Color?

    private var textColor: Color {
        customTextColor ?? (isOutgoing ? .white : .primary)
    }

    private var blocks: [ETMathRenderBlock] {
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
                            style: ETMathStyle(fontSize: 20, textColor: textColor)
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
    private func renderLine(_ parts: [ETInlineRenderPart]) -> some View {
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
                            style: ETMathStyle(fontSize: 17, textColor: textColor)
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

private extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(
        textColor: Color,
        isOutgoing: Bool,
        prefersDarkPalette: Bool,
        sampleText: String,
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

private struct ETWatchMarkdownImagePreviewItem: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct ETWatchMarkdownImageProvider: ImageProvider {
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    func makeImage(url: URL?) -> some View {
        ETWatchMarkdownImageThumbnail(
            url: url,
            onActivate: onActivate
        )
    }
}

private struct ETWatchMarkdownImageThumbnail: View {
    let url: URL?
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    private let cornerRadius: CGFloat = 10

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
                .accessibilityHint("点按后可使用数码表冠缩放图片")
            } else {
                failurePlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingPlaceholder: some View {
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

    private var failurePlaceholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .etFont(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("图片载入失败")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
    }
}

private struct ETWatchMarkdownImagePreviewSheet: View {
    let item: ETWatchMarkdownImagePreviewItem

    @State private var zoomScale = 1.0
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    private let maxZoomScale = 6.0
    private let contentInset: CGFloat = 12

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

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("正在载入图片")
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }

    private var failureState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .etFont(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
            Text("图片载入失败")
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(12)
    }

    private func previewImage(_ image: Image, containerSize: CGSize) -> some View {
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

private struct ETWatchCollapsibleCodeBlockView<HeaderActions: View, BodyContent: View>: View {
    let language: String?
    let headerTextColor: Color
    let headerBackground: Color
    let blockBackground: Color
    let borderColor: Color
    let onHeaderTap: (() -> Void)?
    @ViewBuilder let headerActions: (_ isCollapsed: Bool) -> HeaderActions
    @ViewBuilder let bodyContent: () -> BodyContent

    @State private var isCollapsed = false

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
    private var codeBlockTitle: some View {
        if let onHeaderTap {
            Button(action: onHeaderTap) {
                codeBlockTitleLabel
            }
            .buttonStyle(.plain)
        } else {
            codeBlockTitleLabel
        }
    }

    private var codeBlockTitleLabel: some View {
        Text(language?.isEmpty == false ? (language ?? "代码") : "代码")
            .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(headerTextColor)
            .contentShape(Rectangle())
    }
}

private struct ETCodeCollapseButton: View {
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
        .accessibilityLabel(isCollapsed ? "展开代码块" : "折叠代码块")
    }
}

private enum ETCodeClipboard {
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

private struct ETCodeCopyButton: View {
    let content: String
    let normalColor: Color
    let successColor: Color

    @State private var didCopy = false

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
        .accessibilityLabel("复制代码")
    }
}

private enum ETCodeLanguage: Hashable {
    case swift
    case javascript
    case typescript
    case python
    case ruby
    case bash
    case cstyle
    case sql
    case data
    case markup
    case plain

    init(rawLanguage: String?) {
        let raw = (rawLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "swift":
            self = .swift
        case "js", "jsx", "javascript", "mjs", "cjs":
            self = .javascript
        case "ts", "tsx", "typescript":
            self = .typescript
        case "py", "python":
            self = .python
        case "rb", "ruby":
            self = .ruby
        case "sh", "bash", "zsh", "shell":
            self = .bash
        case "c", "h", "cpp", "cc", "cxx", "hpp", "objective-c", "objc", "objc++", "java", "kotlin", "kt", "go", "rust", "rs":
            self = .cstyle
        case "sql":
            self = .sql
        case "json", "yaml", "yml", "toml":
            self = .data
        case "html", "xml", "svg", "xhtml":
            self = .markup
        default:
            self = .plain
        }
    }

    var keywordMatchOptions: NSRegularExpression.Options {
        self == .sql ? [.caseInsensitive] : []
    }

    var keywords: Set<String> {
        Self.keywordTable[self] ?? []
    }

    var supportsSlashComment: Bool {
        Self.slashCommentLanguages.contains(self)
    }

    var supportsHashComment: Bool {
        Self.hashCommentLanguages.contains(self)
    }

    var supportsBacktickString: Bool {
        Self.backtickStringLanguages.contains(self)
    }

    var supportsTypeNameHighlight: Bool {
        Self.typeNameLanguages.contains(self)
    }

    var supportsFunctionHighlight: Bool {
        self != .data
    }

    var supportsPropertyHighlight: Bool {
        Self.propertyLanguages.contains(self)
    }

    private static let slashCommentLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .cstyle]
    private static let hashCommentLanguages: Set<ETCodeLanguage> = [.python, .ruby, .bash, .data]
    private static let backtickStringLanguages: Set<ETCodeLanguage> = [.javascript, .typescript]
    private static let typeNameLanguages: Set<ETCodeLanguage> = [.swift, .typescript, .cstyle]
    private static let propertyLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .python, .ruby, .cstyle]

    private static let keywordTable: [ETCodeLanguage: Set<String>] = [
        .swift: [
            "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
            "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
            "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static",
            "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"
        ],
        .javascript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true",
            "try", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        .typescript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "interface", "let", "new", "null", "return", "super", "switch", "this", "throw",
            "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "implements"
        ],
        .python: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "elif", "else",
            "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None",
            "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
        ],
        .ruby: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
            "until", "when", "while", "yield"
        ],
        .bash: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
            "then", "time", "until", "while"
        ],
        .cstyle: [
            "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "false", "final", "float", "for", "if", "import",
            "inline", "int", "interface", "let", "long", "namespace", "new", "null", "private", "protected",
            "public", "return", "short", "signed", "static", "struct", "switch", "template", "this", "throw",
            "true", "try", "typedef", "typename", "union", "unsigned", "using", "var", "virtual", "void",
            "volatile", "while"
        ],
        .sql: [
            "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner",
            "outer", "on", "as", "group", "by", "order", "limit", "having", "and", "or", "not", "null",
            "is", "in", "exists", "distinct", "create", "table", "alter", "drop", "values", "set"
        ],
        .data: ["true", "false", "null", "yes", "no", "on", "off"]
    ]
}

private enum ETCodeTheme {
    case outgoing
    case atomOneDark
    case atomOneLight

    static func resolve(isOutgoing: Bool, prefersDarkPalette: Bool) -> ETCodeTheme {
        if isOutgoing { return .outgoing }
        return prefersDarkPalette ? .atomOneDark : .atomOneLight
    }
}

private struct ETCodeHighlightPalette {
    let plain: Color
    let comment: Color
    let string: Color
    let number: Color
    let keyword: Color
    let typeName: Color
    let function: Color
    let property: Color
    let tag: Color
    let attribute: Color
    let punctuation: Color
    let operatorSymbol: Color

    init(baseColor: Color, theme: ETCodeTheme) {
        plain = baseColor
        switch theme {
        case .outgoing:
            comment = Color.white.opacity(0.7)
            string = Color(red: 0.84, green: 0.97, blue: 1.0)
            number = Color(red: 1.0, green: 0.9, blue: 0.78)
            keyword = Color.white.opacity(0.96)
            typeName = Color(red: 0.93, green: 0.97, blue: 1.0)
            function = Color(red: 0.78, green: 0.9, blue: 1.0)
            property = Color(red: 1.0, green: 0.82, blue: 0.86)
            tag = Color(red: 1.0, green: 0.83, blue: 0.88)
            attribute = Color(red: 1.0, green: 0.92, blue: 0.8)
            punctuation = Color.white.opacity(0.88)
            operatorSymbol = Color.white.opacity(0.9)
        case .atomOneDark:
            comment = Self.color(hex: 0x5C6370)
            string = Self.color(hex: 0x98C379)
            number = Self.color(hex: 0xD19A66)
            keyword = Self.color(hex: 0xC678DD)
            typeName = Self.color(hex: 0xE5C07B)
            function = Self.color(hex: 0x61AFEF)
            property = Self.color(hex: 0xE06C75)
            tag = Self.color(hex: 0xE06C75)
            attribute = Self.color(hex: 0xD19A66)
            punctuation = Self.color(hex: 0xABB2BF)
            operatorSymbol = Self.color(hex: 0x56B6C2)
        case .atomOneLight:
            comment = Self.color(hex: 0xA0A1A7)
            string = Self.color(hex: 0x50A14F)
            number = Self.color(hex: 0x986801)
            keyword = Self.color(hex: 0xA626A4)
            typeName = Self.color(hex: 0xC18401)
            function = Self.color(hex: 0x4078F2)
            property = Self.color(hex: 0xE45649)
            tag = Self.color(hex: 0xE45649)
            attribute = Self.color(hex: 0x986801)
            punctuation = Self.color(hex: 0x383A42)
            operatorSymbol = Self.color(hex: 0x0184BC)
        }
    }

    private static func color(hex: UInt32) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

private struct ETCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private enum TokenKind {
        case plain
        case comment
        case string
        case number
        case keyword
        case typeName
        case function
        case property
        case tag
        case attribute
        case punctuation
        case operatorSymbol
    }

    let baseColor: Color
    let isOutgoing: Bool
    let prefersDarkPalette: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard !code.isEmpty else { return Text("") }

        let length = code.utf16.count
        guard length > 0, length <= 12_000 else {
            return Text(code).foregroundColor(baseColor)
        }

        let language = ETCodeLanguage(rawLanguage: language)
        let theme = ETCodeTheme.resolve(isOutgoing: isOutgoing, prefersDarkPalette: prefersDarkPalette)
        let palette = ETCodeHighlightPalette(baseColor: baseColor, theme: theme)

        var priorities = Array(repeating: Int.min, count: length)
        var kinds = Array(repeating: TokenKind.plain, count: length)

        func apply(
            pattern: String,
            options: NSRegularExpression.Options = [],
            kind: TokenKind,
            priority: Int
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return
            }
            let full = NSRange(location: 0, length: length)
            expression.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound, range.length > 0 else { return }
                let lowerBound = max(0, range.location)
                let upperBound = min(length, range.location + range.length)
                guard lowerBound < upperBound else { return }
                for index in lowerBound..<upperBound where priority >= priorities[index] {
                    priorities[index] = priority
                    kinds[index] = kind
                }
            }
        }

        if language.supportsSlashComment {
            apply(pattern: #"//.*$"#, options: [.anchorsMatchLines], kind: .comment, priority: 120)
            apply(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment, priority: 120)
        }
        if language.supportsHashComment {
            apply(pattern: #"(?m)#.*$"#, kind: .comment, priority: 120)
        }
        if language == .sql {
            apply(pattern: #"(?m)--.*$"#, kind: .comment, priority: 120)
        }
        if language == .markup {
            apply(pattern: #"<!--[\s\S]*?-->"#, kind: .comment, priority: 120)
            apply(pattern: #"</?[A-Za-z][A-Za-z0-9:-]*"#, kind: .tag, priority: 98)
            apply(pattern: #"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#, kind: .attribute, priority: 96)
        }

        apply(pattern: #""([^"\\]|\\.)*""#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        apply(pattern: #"'([^'\\]|\\.)*'"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        if language.supportsBacktickString {
            apply(pattern: #"`([^`\\]|\\.|[\r\n])*`"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        }

        apply(pattern: #"\b0x[0-9A-Fa-f]+\b"#, kind: .number, priority: 90)
        apply(pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number, priority: 90)

        if !language.keywords.isEmpty {
            let joined = language.keywords
                .sorted()
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            apply(pattern: "\\b(?:\(joined))\\b", options: language.keywordMatchOptions, kind: .keyword, priority: 100)
        }

        if language.supportsTypeNameHighlight {
            apply(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .typeName, priority: 82)
        }
        if language.supportsFunctionHighlight {
            apply(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, kind: .function, priority: 80)
        }
        if language.supportsPropertyHighlight {
            apply(pattern: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*\b"#, kind: .property, priority: 79)
        }

        apply(
            pattern: #"(?:==|!=|<=|>=|=>|->|<-|\+\+|--|\+=|-=|\*=|/=|%=|&&|\|\||<<|>>|[+\-*/%=!<>|&~^?:])"#,
            kind: .operatorSymbol,
            priority: 60
        )
        apply(pattern: #"[{}\[\]();,.:]"#, kind: .punctuation, priority: 56)

        var attributed = AttributedString(code)
        var segmentStart = 0
        var currentKind = kinds[0]

        for index in 1...length {
            let reachedEnd = index == length
            let kindChanged = !reachedEnd && kinds[index] != currentKind
            if reachedEnd || kindChanged {
                let start = String.Index(utf16Offset: segmentStart, in: code)
                let end = String.Index(utf16Offset: index, in: code)
                if let attributedStart = AttributedString.Index(start, within: attributed),
                   let attributedEnd = AttributedString.Index(end, within: attributed),
                   attributedStart < attributedEnd {
                    attributed[attributedStart..<attributedEnd].foregroundColor = color(for: currentKind, palette: palette)
                }
                if !reachedEnd {
                    segmentStart = index
                    currentKind = kinds[index]
                }
            }
        }

        return Text(attributed)
    }

    private func color(for token: TokenKind, palette: ETCodeHighlightPalette) -> Color {
        switch token {
        case .plain:
            return palette.plain
        case .comment:
            return palette.comment
        case .string:
            return palette.string
        case .number:
            return palette.number
        case .keyword:
            return palette.keyword
        case .typeName:
            return palette.typeName
        case .function:
            return palette.function
        case .property:
            return palette.property
        case .tag:
            return palette.tag
        case .attribute:
            return palette.attribute
        case .punctuation:
            return palette.punctuation
        case .operatorSymbol:
            return palette.operatorSymbol
        }
    }
}

private enum ETMathRenderBlock {
    case line([ETInlineRenderPart])
    case blockMath(String)
    case emptyLine

    static func build(from segments: [ETMathContentSegment]) -> [ETMathRenderBlock] {
        var blocks: [ETMathRenderBlock] = []
        var line: [ETInlineRenderPart] = []

        func flushLine() {
            guard !line.isEmpty else { return }
            blocks.append(.line(line))
            line.removeAll(keepingCapacity: true)
        }

        func appendText(_ text: String) {
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                let value = String(part)
                if !value.isEmpty {
                    line.append(.text(value))
                }
                if index < parts.count - 1 {
                    flushLine()
                    if value.isEmpty {
                        blocks.append(.emptyLine)
                    }
                }
            }
        }

        for segment in segments {
            switch segment {
            case .text(let text):
                appendText(text)
            case .inlineMath(let latex):
                line.append(.math(latex))
            case .blockMath(let latex):
                flushLine()
                blocks.append(.blockMath(latex))
            @unknown default:
                break
            }
        }

        flushLine()
        return blocks
    }
}

private enum ETInlineRenderPart {
    case text(String)
    case math(String)

    var isMath: Bool {
        if case .math = self { return true }
        return false
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

private enum ETInlineRenderToken {
    case text(String)
    case math(String)

    static func tokens(from parts: [ETInlineRenderPart]) -> [ETInlineRenderToken] {
        var tokens: [ETInlineRenderToken] = []
        for part in parts {
            switch part {
            case .math(let latex):
                tokens.append(.math(latex))
            case .text(let text):
                for character in text {
                    tokens.append(.text(String(character)))
                }
            }
        }
        return tokens
    }
}

private struct ETInlineMathFlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        guard !subviews.isEmpty else { return .zero }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - itemSpacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, x - itemSpacing)
        y += lineHeight

        let measuredWidth = proposal.width ?? maxLineWidth
        return CGSize(width: measuredWidth, height: y)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude

        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
