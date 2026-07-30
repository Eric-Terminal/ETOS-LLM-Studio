// ============================================================================
// ChatAppearanceTextRuleRenderer.swift
// ============================================================================
// 在后台生成可直接交给 SwiftUI Text 的规则化颜色与字体文本
// ============================================================================

import Foundation
import SwiftUI
#if canImport(CoreText)
import CoreText
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct ChatAppearanceTextRuleRenderRequest: Hashable, Sendable {
    public let source: String
    public let usesMarkdown: Bool
    public let styleColors: ChatAppearanceTextStyleColors
    public let fontRules: [ChatAppearanceResolvedTextFontRule]
    public let fontPointSize: Double
    public let fontScale: Double
    public let fontFallbackScope: FontFallbackScope

    public init(
        source: String,
        usesMarkdown: Bool,
        styleColors: ChatAppearanceTextStyleColors,
        fontRules: [ChatAppearanceResolvedTextFontRule] = [],
        fontPointSize: Double = 17,
        fontScale: Double = 1,
        fontFallbackScope: FontFallbackScope = .segment
    ) {
        self.source = source
        self.usesMarkdown = usesMarkdown
        self.styleColors = styleColors
        self.fontRules = fontRules
        self.fontPointSize = fontPointSize
        self.fontScale = fontScale
        self.fontFallbackScope = fontFallbackScope
    }
}

public actor ChatAppearanceTextRuleRenderer {
    public static let shared = ChatAppearanceTextRuleRenderer()

    private enum CachedResult: Sendable {
        case rendered(AttributedString)
        case unsupported
    }

    private var cache: [ChatAppearanceTextRuleRenderRequest: CachedResult] = [:]
    private var keyOrder: [ChatAppearanceTextRuleRenderRequest] = []
    private let cacheLimit = 160

    public func prepare(
        request: ChatAppearanceTextRuleRenderRequest
    ) async -> AttributedString? {
        if let cached = cache[request] {
            switch cached {
            case .rendered(let text):
                return text
            case .unsupported:
                return nil
            }
        }

        let result = await Task.detached(priority: .userInitiated) {
            Self.build(request: request)
        }.value
        cache[request] = result.map(CachedResult.rendered) ?? .unsupported
        keyOrder.append(request)
        trimIfNeeded()
        return result
    }

    private nonisolated static func build(
        request: ChatAppearanceTextRuleRenderRequest
    ) -> AttributedString? {
        let activeColorRules = request.styleColors.customRules.filter { $0.isEnabled && $0.isConfigured }
        let activeFontRules = request.fontRules.filter {
            $0.rule.isEnabled && $0.rule.hasConfiguredMatch && !$0.postScriptNames.isEmpty
        }
        guard !activeColorRules.isEmpty || !activeFontRules.isEmpty else { return nil }
        if request.usesMarkdown && containsSpecializedMarkdownBlock(in: request.source) {
            return nil
        }

        var attributed: AttributedString
        if request.usesMarkdown {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            guard let parsed = try? AttributedString(markdown: request.source, options: options) else {
                return nil
            }
            attributed = parsed
        } else {
            attributed = AttributedString(request.source)
        }

        applySemanticColors(request.styleColors, to: &attributed)
        applyCustomColorRules(activeColorRules, to: &attributed)
        applyCustomFontRules(
            activeFontRules,
            pointSize: request.fontPointSize * request.fontScale,
            fallbackScope: request.fontFallbackScope,
            to: &attributed
        )
        return attributed
    }

    private nonisolated static func applySemanticColors(
        _ styles: ChatAppearanceTextStyleColors,
        to attributed: inout AttributedString
    ) {
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let colorHex: String?
            if intent.contains(.code), styles.code.isEnabled {
                colorHex = styles.code.hex
            } else if intent.contains(.stronglyEmphasized), styles.strong.isEnabled {
                colorHex = styles.strong.hex
            } else if intent.contains(.emphasized), styles.emphasis.isEnabled {
                colorHex = styles.emphasis.hex
            } else {
                colorHex = nil
            }
            guard let colorHex else { continue }
            attributed[run.range].foregroundColor = ChatAppearanceColorCodec.color(
                from: colorHex,
                fallback: .primary
            )
        }
    }

    private nonisolated static func applyCustomColorRules(
        _ rules: [ChatAppearanceTextColorRule],
        to attributed: inout AttributedString
    ) {
        let visibleText = String(attributed.characters)
        let excludedRanges = inlineCodeRanges(in: attributed)
        let spans = ChatAppearanceTextColorMatcher.spans(
            in: visibleText,
            rules: rules,
            excludedRanges: excludedRanges
        )

        for span in spans {
            let nsRange = NSRange(location: span.location, length: span.length)
            guard let stringRange = Range(nsRange, in: visibleText),
                  let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed) else {
                continue
            }
            attributed[lowerBound..<upperBound].foregroundColor = ChatAppearanceColorCodec.color(
                from: span.colorHex,
                fallback: .primary
            )
        }
    }

    private nonisolated static func applyCustomFontRules(
        _ rules: [ChatAppearanceResolvedTextFontRule],
        pointSize: Double,
        fallbackScope: FontFallbackScope,
        to attributed: inout AttributedString
    ) {
        let visibleText = String(attributed.characters)
        let excludedRanges = inlineCodeRanges(in: attributed)
        let spans = ChatAppearanceTextFontMatcher.spans(
            in: visibleText,
            rules: rules.map(\.rule),
            excludedRanges: excludedRanges
        )
        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.rule.id, $0) })

        for span in spans {
            let nsRange = NSRange(location: span.location, length: span.length)
            guard let stringRange = Range(nsRange, in: visibleText),
                  let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed),
                  let rule = rulesByID[span.ruleID] else {
                continue
            }
            let sample = String(visibleText[stringRange])
            guard let font = resolvedFont(
                postScriptNames: rule.postScriptNames,
                sample: sample,
                pointSize: pointSize,
                fallbackScope: fallbackScope
            ) else {
                continue
            }
            attributed[lowerBound..<upperBound].font = font
        }
    }

    private nonisolated static func resolvedFont(
        postScriptNames: [String],
        sample: String,
        pointSize: Double,
        fallbackScope: FontFallbackScope
    ) -> Font? {
        let normalizedPointSize = max(1, pointSize)
        switch fallbackScope {
        case .segment:
            guard let selected = postScriptNames.first(where: {
                fontCanRenderSample(postScriptName: $0, sample: sample)
            }) else {
                return nil
            }
            return .custom(
                selected,
                size: CGFloat(normalizedPointSize),
                relativeTo: .body
            )
        case .character:
            return cascadedFont(
                postScriptNames: postScriptNames,
                pointSize: normalizedPointSize
            )
        }
    }

    private nonisolated static func fontCanRenderSample(
        postScriptName: String,
        sample: String
    ) -> Bool {
#if canImport(CoreText)
        let font = CTFontCreateWithName(postScriptName as CFString, 16, nil)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        guard resolvedName.caseInsensitiveCompare(postScriptName) == .orderedSame else {
            return false
        }
        let characters = sample.unicodeScalars
            .filter {
                !$0.properties.isWhitespace && $0.properties.generalCategory != .control
            }
            .prefix(96)
            .map { scalar -> UniChar in
                scalar.value <= 0xFFFF ? UniChar(scalar.value) : UniChar(0xFFFD)
            }
        guard !characters.isEmpty else { return true }
        var mutableCharacters = Array(characters)
        var glyphs = Array(repeating: CGGlyph(), count: mutableCharacters.count)
        let mapped = CTFontGetGlyphsForCharacters(
            font,
            &mutableCharacters,
            &glyphs,
            mutableCharacters.count
        )
        return mapped && !glyphs.contains(0)
#else
        _ = sample
        return !postScriptName.isEmpty
#endif
    }

    private nonisolated static func cascadedFont(
        postScriptNames: [String],
        pointSize: Double
    ) -> Font? {
#if canImport(UIKit) && canImport(CoreText)
        let size = CGFloat(pointSize)
        let availableNames = postScriptNames.filter {
            UIFont(name: $0, size: size) != nil
        }
        guard let primaryName = availableNames.first else {
            return nil
        }
        let cascadeDescriptors = availableNames.dropFirst().map { name in
            return CTFontDescriptorCreateWithNameAndSize(name as CFString, size)
        }
        guard !cascadeDescriptors.isEmpty else {
            return .custom(primaryName, size: size, relativeTo: .body)
        }

        let cascadeKey = UIFontDescriptor.AttributeName(
            rawValue: kCTFontCascadeListAttribute as String
        )
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: primaryName,
            .size: size,
            cascadeKey: cascadeDescriptors
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
#else
        guard let primaryName = postScriptNames.first else { return nil }
        return .custom(primaryName, size: CGFloat(pointSize), relativeTo: .body)
#endif
    }

    private nonisolated static func inlineCodeRanges(
        in attributed: AttributedString
    ) -> [Range<Int>] {
        var location = 0
        var result: [Range<Int>] = []
        for run in attributed.runs {
            let length = String(attributed[run.range].characters).utf16.count
            if run.inlinePresentationIntent?.contains(.code) == true {
                result.append(location..<(location + length))
            }
            location += length
        }
        return result
    }

    private nonisolated static func containsSpecializedMarkdownBlock(in source: String) -> Bool {
        if source.contains("![") || source.contains("$") || source.contains("\\[") || source.contains("\\(") {
            return true
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let headingMarkerCount = trimmed.prefix { $0 == "#" }.count
            let isHeading = (1...6).contains(headingMarkerCount)
                && trimmed.dropFirst(headingMarkerCount).first?.isWhitespace == true
            if trimmed.hasPrefix("```")
                || trimmed.hasPrefix("~~~")
                || isHeading
                || trimmed.hasPrefix("> ")
                || trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("+ ")
                || (trimmed.hasPrefix("|") && trimmed.contains("|")) {
                return true
            }
            if let first = trimmed.first, first.isNumber,
               trimmed.drop(while: { $0.isNumber }).hasPrefix(". ") {
                return true
            }
        }
        return false
    }

    private func trimIfNeeded() {
        while keyOrder.count > cacheLimit {
            let removed = keyOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
    }
}
