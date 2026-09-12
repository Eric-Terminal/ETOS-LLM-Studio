import SwiftUI

/// 显式保存字体语义，避免依赖 SwiftUI 私有 Font/Text 存储结构的反射。
public struct ETFont: Hashable, Sendable {
    public private(set) var textStyle: Font.TextStyle?
    public private(set) var explicitSize: CGFloat?
    public private(set) var fontWeight: Font.Weight?
    public private(set) var design: Font.Design = .default
    public private(set) var isItalic = false
    public private(set) var hasMonospacedDigits = false

    public static let largeTitle = system(.largeTitle)
    public static let title = system(.title)
    public static let title2 = system(.title2)
    public static let title3 = system(.title3)
    public static let headline = system(.headline)
    public static let subheadline = system(.subheadline)
    public static let body = system(.body)
    public static let callout = system(.callout)
    public static let footnote = system(.footnote)
    public static let caption = system(.caption)
    public static let caption2 = system(.caption2)

    public static func system(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil) -> Self {
        Self(textStyle: style, fontWeight: weight, design: design)
    }

    public static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> Self {
        Self(explicitSize: size, fontWeight: weight, design: design)
    }

    public func weight(_ weight: Font.Weight) -> Self {
        var result = self
        result.fontWeight = weight
        return result
    }

    public func bold() -> Self { weight(.bold) }

    public func italic() -> Self {
        var result = self
        result.isItalic = true
        return result
    }

    public func monospaced() -> Self {
        var result = self
        result.design = .monospaced
        return result
    }

    public func monospacedDigit() -> Self {
        var result = self
        result.hasMonospacedDigits = true
        return result
    }

    public var role: FontSemanticRole {
        if design == .monospaced { return .code }
        if isItalic { return .emphasis }
        switch fontWeight {
        case .semibold, .bold, .heavy, .black: return .strong
        default: return .body
        }
    }

    public var basePointSize: CGFloat {
        if let explicitSize { return explicitSize }
        switch textStyle {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .subheadline: return 15
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    public var systemFont: Font {
        let result: Font
        if let textStyle {
            result = .system(textStyle, design: design, weight: fontWeight)
        } else {
            result = .system(size: basePointSize, weight: fontWeight, design: design)
        }
        return applyingTraits(to: result)
    }

    func applyingTraits(to font: Font) -> Font {
        var result = font
        if isItalic { result = result.italic() }
        if hasMonospacedDigits { result = result.monospacedDigit() }
        if let fontWeight { result = result.weight(fontWeight) }
        return result
    }
}
