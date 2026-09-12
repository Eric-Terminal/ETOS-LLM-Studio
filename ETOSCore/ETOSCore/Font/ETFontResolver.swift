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
    }

    public func font(for descriptor: ETFont, sampleText: String? = nil, sizeCategory: ContentSizeCategory = .large) -> Font {
        let currentRevision = FontLibrary.adapterCacheToken()
        if revision != currentRevision {
            revision = currentRevision
            cache.removeAll(keepingCapacity: true)
        }
        let request = Request(descriptor: descriptor, sample: sampleText.map(Self.sample), sizeCategory: sizeCategory)
        if let cached = cache[request] { return cached }
        let font = resolve(request)
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[request] = font
        return font
    }

    /// ImageRenderer 不运行视图 task，导出前必须准备可同步使用的字体模板。
    public func exportTemplates() -> ETFontExportTemplates {
        var descriptors: [FontSemanticRole: CTFontDescriptor] = [:]
        if FontLibrary.isCustomFontEnabled {
            for role in [FontSemanticRole.body, .emphasis, .strong, .code] {
                guard let primary = FontLibrary.resolvedPostScriptName(for: role) else { continue }
                let cascade = FontLibrary.fallbackPostScriptNames(for: role).filter { $0 != primary }
                    .map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) }
                let attributes: [CFString: Any] = [kCTFontNameAttribute: primary, kCTFontCascadeListAttribute: cascade]
                descriptors[role] = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            }
        }
        return ETFontExportTemplates(descriptors: descriptors, scale: CGFloat(FontLibrary.customFontScale))
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
        let pointSize = descriptor.basePointSize * scale
        let candidates = FontLibrary.fallbackPostScriptNames(for: descriptor.role)
        let primary: String?
        if let sample = request.sample, !sample.isEmpty {
            primary = FontLibrary.resolvePostScriptName(for: descriptor.role, sampleText: sample)
        } else {
            primary = FontLibrary.resolvedPostScriptName(for: descriptor.role)
        }

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

        // 普通控件无需反射 Text；无样本时使用首选字体和字形回退链。
        // 显式文本样本仍按用户配置的整段或逐字策略匹配。
        if FontLibrary.fallbackScope == .character || request.sample == nil {
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
        if let style = descriptor.textStyle {
            font = .custom(primary, size: pointSize, relativeTo: style)
        } else {
            font = .custom(primary, size: pointSize)
        }
        return descriptor.applyingTraits(to: font)
    }

#if canImport(UIKit)
    private func scaledFont(_ font: UIFont, request: Request) -> Font {
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

public struct ETFontModifier: ViewModifier {
    let descriptor: ETFont?
    let sampleText: String?
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.etFontExportTemplates) private var exportTemplates
    @State private var resolvedFont: Font?
    @State private var configurationRevision = FontLibrary.adapterCacheToken()

    public init(_ descriptor: ETFont?, sampleText: String? = nil) {
        self.descriptor = descriptor
        self.sampleText = sampleText
    }

    private struct Preparation: Equatable {
        let descriptor: ETFont?
        let sample: String?
        let revision: String
        let sizeCategory: ContentSizeCategory
    }

    public func body(content: Content) -> some View {
        let currentRevision = FontLibrary.adapterCacheToken()
        let preparation = Preparation(descriptor: descriptor, sample: sampleText, revision: configurationRevision == currentRevision ? configurationRevision : currentRevision, sizeCategory: sizeCategory)
        content
            .font(descriptor.map { exportTemplates?.font(for: $0) ?? resolvedFont ?? $0.systemFont })
            .task(id: preparation) {
                guard let descriptor else {
                    resolvedFont = nil
                    return
                }
                let font = await ETFontResolver.shared.font(for: descriptor, sampleText: sampleText, sizeCategory: sizeCategory)
                guard !Task.isCancelled else { return }
                resolvedFont = font
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
                configurationRevision = FontLibrary.adapterCacheToken()
            }
    }
}

/// 模板中的 CoreText 描述符不可变，可从后台准备任务传给导出视图。
public struct ETFontExportTemplates: @unchecked Sendable {
    let descriptors: [FontSemanticRole: CTFontDescriptor]
    let scale: CGFloat

    func font(for descriptor: ETFont) -> Font {
        guard let template = descriptors[descriptor.role] else {
            if abs(scale - 1) < 0.001 { return descriptor.systemFont }
            return descriptor.applyingTraits(to: .system(size: descriptor.basePointSize * scale, weight: descriptor.fontWeight ?? (descriptor.textStyle == .headline ? .semibold : .regular), design: descriptor.design))
        }
        let font = CTFontCreateWithFontDescriptor(template, descriptor.basePointSize * scale, nil)
        return descriptor.applyingTraits(to: Font(font))
    }
}

private struct ETFontExportTemplatesKey: EnvironmentKey {
    static let defaultValue: ETFontExportTemplates? = nil
}

public extension EnvironmentValues {
    var etFontExportTemplates: ETFontExportTemplates? {
        get { self[ETFontExportTemplatesKey.self] }
        set { self[ETFontExportTemplatesKey.self] = newValue }
    }
}
