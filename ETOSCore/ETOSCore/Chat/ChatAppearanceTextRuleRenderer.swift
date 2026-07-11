// ============================================================================
// ChatAppearanceTextRuleRenderer.swift
// ============================================================================
// 在后台生成可直接交给 SwiftUI Text 的规则着色文本
// ============================================================================

import Foundation
import SwiftUI

public struct ChatAppearanceTextRuleRenderRequest: Hashable, Sendable {
    public let source: String
    public let usesMarkdown: Bool
    public let styleColors: ChatAppearanceTextStyleColors

    public init(
        source: String,
        usesMarkdown: Bool,
        styleColors: ChatAppearanceTextStyleColors
    ) {
        self.source = source
        self.usesMarkdown = usesMarkdown
        self.styleColors = styleColors
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
        let activeRules = request.styleColors.customRules.filter { $0.isEnabled && $0.isConfigured }
        guard !activeRules.isEmpty else { return nil }
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
        applyCustomRules(activeRules, to: &attributed)
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

    private nonisolated static func applyCustomRules(
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
