import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// 字形覆盖查询和回退链构造只在后台 actor 执行，界面读取准备完成的 Font。
public actor ETFontResolver {
    public static let shared = ETFontResolver()
    private var revision = ""
    private var cache: [Request: Font] = [:]

    struct Request: Hashable {
        let descriptor: ETFont
        let sample: String?
        let sizeCategory: ContentSizeCategory
        let scaledBasePointSize: CGFloat?
    }

    public func font(for descriptor: ETFont, sampleText: String? = nil, sizeCategory: ContentSizeCategory = .large) -> Font {
        cachedFont(for: descriptor, sampleText: sampleText, sizeCategory: sizeCategory, scaledBasePointSize: nil)
    }

    private func cachedFont(for descriptor: ETFont, sampleText: String?, sizeCategory: ContentSizeCategory, scaledBasePointSize: CGFloat?) -> Font {
        let currentRevision = FontLibrary.adapterCacheToken()
        if revision != currentRevision {
            revision = currentRevision
            cache.removeAll(keepingCapacity: true)
        }
        let request = Request(descriptor: descriptor, sample: sampleText.map(Self.sample), sizeCategory: sizeCategory, scaledBasePointSize: scaledBasePointSize)
        if let cached = cache[request] { return cached }
        let font = resolve(request)
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[request] = font
        return font
    }

    func font(for request: ETFontPreparationRequest) -> Font? {
        guard let descriptor = request.descriptor else { return nil }
        var sampleText = request.sampleText
        if sampleText == nil, let text = request.text, FontLibrary.isCustomFontEnabled {
            var environment = EnvironmentValues()
            environment.locale = request.locale
            environment.calendar = request.calendar
            environment.timeZone = request.timeZone
            environment.sizeCategory = request.sizeCategory
            // 使用 SDK 导出的 Text 解析入口，不遍历其私有存储；解析和样本截取均留在 actor。
            sampleText = text._resolveText(in: environment)
        }
        return cachedFont(for: descriptor, sampleText: sampleText, sizeCategory: request.sizeCategory, scaledBasePointSize: request.scaledBasePointSize)
    }

    private static func sample(_ text: String) -> String {
        // 不先过滤整篇正文；长空白文本也有固定的扫描上界。
        let scalars = text.unicodeScalars.prefix(384).filter {
            !$0.properties.isWhitespace && $0.properties.generalCategory != .control
        }.prefix(96)
        return String(String.UnicodeScalarView(scalars))
    }

    private func resolve(_ request: Request) -> Font {
        let descriptor = request.descriptor
        let scale = CGFloat(FontLibrary.customFontScale)
        let fallbackScope = FontLibrary.fallbackScope
        let candidates = FontLibrary.fallbackPostScriptNames(for: descriptor.role)
        let defaultSample: String
        // 非 Text 控件和空文字沿用旧适配器的语义样本，仍然遵守整段回退配置。
        switch descriptor.role {
        case .body: defaultSample = "The quick brown fox 你好こんにちは"
        case .emphasis: defaultSample = "Emphasis 斜体预览 こんにちは"
        case .strong: defaultSample = "Strong 粗体预览 こんにちは"
        case .code: defaultSample = "let value = 42 // 代码"
        }
        let sample = request.sample.flatMap { $0.isEmpty ? nil : $0 } ?? defaultSample
        let primary = FontLibrary.resolvePostScriptName(for: descriptor.role, sampleText: sample)
#if os(watchOS)
        // watchOS 没有指定字号 trait 的 UIFontMetrics 接口，语义字号使用视图环境度量。
        let baseSize = descriptor.textStyle != nil ? request.scaledBasePointSize ?? descriptor.basePointSize : descriptor.basePointSize
#else
        let baseSize = descriptor.basePointSize
#endif
        let pointSize = baseSize * scale

        guard FontLibrary.isCustomFontEnabled, let primary else {
            if abs(scale - 1) < 0.001 { return descriptor.systemFont }
#if canImport(UIKit)
            var uiDescriptor = UIFont.systemFont(ofSize: pointSize, weight: uiWeight(descriptor.fontWeight ?? (descriptor.textStyle == .headline ? .semibold : .regular))).fontDescriptor
            let design: UIFontDescriptor.SystemDesign
            switch descriptor.design {
            case .serif: design = .serif
            case .rounded: design = .rounded
            case .monospaced: design = .monospaced
            default: design = .default
            }
            uiDescriptor = uiDescriptor.withDesign(design) ?? uiDescriptor
            return descriptor.applyingTraits(to: scaledFont(UIFont(descriptor: uiDescriptor, size: pointSize), request: request))
#else
            return descriptor.applyingTraits(to: .system(size: pointSize, weight: descriptor.fontWeight, design: descriptor.design))
#endif
        }

        if fallbackScope == .character {
            let cascade = candidates.filter { $0.caseInsensitiveCompare(primary) != .orderedSame }
                .map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, pointSize) }
#if canImport(UIKit)
            let attributes: [UIFontDescriptor.AttributeName: Any] = [
                .name: primary,
                .size: pointSize,
                UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String): cascade
            ]
            let uiFont = UIFont(descriptor: UIFontDescriptor(fontAttributes: attributes), size: pointSize)
            return descriptor.applyingTraits(to: scaledFont(uiFont, request: request))
#else
            let attributes: [CFString: Any] = [kCTFontNameAttribute: primary, kCTFontCascadeListAttribute: cascade]
            let ctDescriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            let ctFont = CTFontCreateWithFontDescriptor(ctDescriptor, pointSize, nil)
            return descriptor.applyingTraits(to: Font(ctFont))
#endif
        }

        let font: Font
        // custom 字体让 SwiftUI 按当前环境缩放；先手动缩放再固定字号会改变原生取整结果。
        let customPointSize = descriptor.basePointSize * scale
        if let style = descriptor.textStyle {
            font = .custom(primary, size: customPointSize, relativeTo: style)
        } else {
            font = .custom(primary, size: customPointSize)
        }
        return descriptor.applyingTraits(to: font)
    }

#if canImport(UIKit)
    private func scaledFont(_ font: UIFont, request: Request) -> Font {
#if os(watchOS)
        if request.scaledBasePointSize != nil { return Font(font) }
#endif
        guard let style = request.descriptor.textStyle else { return Font(font) }
        let uiStyle: UIFont.TextStyle
        switch style {
        case .largeTitle: uiStyle = .largeTitle
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .callout: uiStyle = .callout
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        default: uiStyle = .body
        }
#if os(watchOS)
        // watchOS 支持字体缩放，但没有 iOS 的 UITraitCollection 字号覆盖接口。
        return Font(UIFontMetrics(forTextStyle: uiStyle).scaledFont(for: font))
#else
        let category: UIContentSizeCategory
        switch request.sizeCategory {
        case .extraSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .extraLarge: category = .extraLarge
        case .extraExtraLarge: category = .extraExtraLarge
        case .extraExtraExtraLarge: category = .extraExtraExtraLarge
        case .accessibilityMedium: category = .accessibilityMedium
        case .accessibilityLarge: category = .accessibilityLarge
        case .accessibilityExtraLarge: category = .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: category = .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: category = .accessibilityExtraExtraExtraLarge
        default: category = .large
        }
        return Font(UIFontMetrics(forTextStyle: uiStyle).scaledFont(for: font, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)))
#endif
    }

    private func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
#endif
}
