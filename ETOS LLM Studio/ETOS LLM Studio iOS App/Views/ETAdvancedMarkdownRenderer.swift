// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETAdvancedMarkdownRenderer 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import Shared
import WebKit
import UIKit
#if canImport(SwiftMath)
import SwiftMath
#endif

enum ETNativeMathMarkdownCodec {
    enum RenderKind: String, Hashable, Sendable {
        case inline
        case block
    }

    struct Request: Hashable, Sendable {
        let latex: String
        let renderKind: RenderKind
    }

    nonisolated static let scheme = "etmath"

    nonisolated static var isAvailable: Bool {
#if canImport(SwiftMath)
        true
#else
        false
#endif
    }

    nonisolated static func transformedMarkdown(from segments: [ETMathContentSegment]) -> String {
        var result = ""
        result.reserveCapacity(segments.reduce(into: 0) { partialResult, segment in
            switch segment {
            case .text(let text):
                partialResult += text.count
            case .inlineMath(let latex), .blockMath(let latex):
                partialResult += latex.count + 48
            @unknown default:
                break
            }
        })

        for segment in segments {
            switch segment {
            case .text(let text):
                result.append(text)
            case .inlineMath(let latex):
                result.append(imageMarkdown(for: .init(latex: latex, renderKind: .inline)))
            case .blockMath(let latex):
                result.append(imageMarkdown(for: .init(latex: latex, renderKind: .block)))
            @unknown default:
                break
            }
        }

        return result
    }

    nonisolated static func request(from url: URL?) -> Request? {
        guard let url, url.scheme == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let renderKindValue = components.queryItems?.first(where: { $0.name == "mode" })?.value,
              let renderKind = RenderKind(rawValue: renderKindValue),
              let encodedLatex = components.queryItems?.first(where: { $0.name == "latex" })?.value,
              let latex = decodeBase64URL(encodedLatex) else {
            return nil
        }
        return Request(latex: latex, renderKind: renderKind)
    }

    nonisolated static func imageMarkdown(for request: Request) -> String {
        guard let url = url(for: request) else { return request.latex }
        return "![数学公式](\(url.absoluteString))"
    }

    nonisolated static func url(for request: Request) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "render"
        components.queryItems = [
            URLQueryItem(name: "mode", value: request.renderKind.rawValue),
            URLQueryItem(name: "latex", value: encodeBase64URL(request.latex))
        ]
        return components.url
    }

    nonisolated static func encodeBase64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}


struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let preparedContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let customTextColor: Color?
    @Environment(\.colorScheme) var colorScheme
    @AppStorage(FontLibrary.customFontEnabledStorageKey) var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fontScaleStorageKey) var customFontScale: Double = FontLibrary.defaultFontScale

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

    func shouldUseWebRenderer(_ prepared: ETPreparedMarkdownRenderPayload) -> Bool {
        guard enableAdvancedRenderer else { return false }
        let hasMermaid = enableMarkdown && prepared.containsMermaidContent
        return hasMermaid
    }

    func resolvedMarkdownContent(for prepared: ETPreparedMarkdownRenderPayload) -> MarkdownContent {
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
    func markdownTextView(
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
                fontScale: fontScale
            )
    }

    @ViewBuilder
    func plainTextView(_ text: String, textColor: Color) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .foregroundStyle(textColor)
    }
}


struct ETMathWebMarkdownView: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let customTextHex: String?
    let prefersDarkPalette: Bool
    let fontScale: Double

    @State var renderedHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            ETMathWebViewRepresentable(
                content: content,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing,
                customTextHex: customTextHex,
                prefersDarkPalette: prefersDarkPalette,
                fontScale: fontScale,
                availableWidth: max(1, geometry.size.width),
                renderedHeight: $renderedHeight
            )
        }
        .frame(height: max(28, renderedHeight))
    }
}


struct ETIOSMarkdownImageProvider: ImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let request = ETNativeMathMarkdownCodec.request(from: url) {
            ETIOSMathBlockImageView(
                request: request,
                textColor: textColor,
                fontScale: fontScale
            )
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}


struct ETIOSMarkdownInlineImageProvider: InlineImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    func image(with url: URL, label: String) async throws -> Image {
        guard let request = ETNativeMathMarkdownCodec.request(from: url) else {
            return try await DefaultInlineImageProvider.default.image(with: url, label: label)
        }

        guard let data = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale),
              let image = UIImage(data: data, scale: UIScreen.main.scale) else {
            return Image(systemName: "function")
        }

        return Image(uiImage: image)
    }
}


struct ETIOSMathBlockImageView: View {
    let request: ETNativeMathMarkdownCodec.Request
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @State var renderedImageData: Data?
    @State var didAttemptRender = false

    var body: some View {
        Group {
            if let renderedImage {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: renderedImage)
                        .interpolation(.high)
                        .antialiased(true)
                }
            } else if didAttemptRender {
                Text(verbatim: request.latex)
                    .font(.system(size: request.renderKind.fallbackFontSize(fontScale: fontScale), design: .serif))
                    .foregroundStyle(textColor.swiftUIColor.opacity(0.9))
                    .textSelection(.enabled)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(textColor.swiftUIColor.opacity(0.08))
                    .frame(height: request.renderKind.placeholderHeight(fontScale: fontScale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(request.latex)
        .task(id: taskKey) {
            didAttemptRender = false
            renderedImageData = nil
            renderedImageData = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale)
            didAttemptRender = true
        }
    }

    var renderedImage: UIImage? {
        guard let renderedImageData else { return nil }
        return UIImage(data: renderedImageData, scale: UIScreen.main.scale)
    }

    var taskKey: String {
        "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)"
    }
}


struct ETIOSMathColorComponents: Hashable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: Color) {
        let resolvedColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        } else {
            self.red = 0
            self.green = 0
            self.blue = 0
            self.alpha = 1
        }
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    var cacheKey: String {
        "\(red)|\(green)|\(blue)|\(alpha)"
    }
}


enum ETIOSMathImageRenderer {
#if canImport(SwiftMath)
    static let cache = NSCache<NSString, NSData>()

    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        let cacheKey = "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)" as NSString
        if let cachedData = cache.object(forKey: cacheKey) {
            return cachedData as Data
        }

        let renderedData: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = MTMathImage(
                    latex: request.latex,
                    fontSize: request.renderKind.fontSize(fontScale: fontScale),
                    textColor: textColor.uiColor,
                    labelMode: request.renderKind.labelMode,
                    textAlignment: .left
                )
                image.contentInsets = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
                let result = image.asImage()
                guard result.0 == nil, let renderedImage = result.1 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: renderedImage.pngData())
            }
        }

        if let renderedData {
            cache.setObject(renderedData as NSData, forKey: cacheKey)
        }

        return renderedData
    }
#else
    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        _ = fontScale
        nil
    }
#endif
}


extension ETNativeMathMarkdownCodec.RenderKind {
    func placeholderHeight(fontScale: Double) -> CGFloat {
        switch self {
        case .inline:
            return 18 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        case .block:
            return 28 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        }
    }

    func fallbackFontSize(fontScale: Double) -> CGFloat {
        switch self {
        case .inline:
            return 17 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        case .block:
            return 20 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
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
        fontScale: Double
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
        let bodyFontSize = CGFloat(17 * FontLibrary.normalizedFontScale(fontScale))

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
                            .relativeLineSpacing(.em(0.15))
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
                                ForegroundColor(textColor)
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

    @State var isCollapsed = false

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
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(didCopy ? successColor : normalColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("复制代码", comment: ""))
    }
}


struct ETCodePreviewButton: View {
    @Environment(\.colorScheme) var colorScheme

    let content: String
    let language: String?
    let tintColor: Color

    @State var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            Image(systemName: "safari")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("预览代码", comment: ""))
        .fullScreenCover(isPresented: $showingPreview) {
            ETCodePreviewSheet(
                content: content,
                language: language,
                prefersDarkPalette: colorScheme == .dark
            )
        }
    }
}
