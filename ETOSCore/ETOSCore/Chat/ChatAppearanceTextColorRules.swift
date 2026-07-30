// ============================================================================
// ChatAppearanceTextColorRules.swift
// ============================================================================
// 聊天文字自定义着色规则与颜色、字体共用的纯文本匹配器
// ============================================================================

import Foundation

public enum ChatAppearanceTextRuleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exactText
    case delimitedText
    case regularExpression
}

public typealias ChatAppearanceTextColorRuleKind = ChatAppearanceTextRuleKind

public struct ChatAppearanceTextColorRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var isEnabled: Bool
    public var kind: ChatAppearanceTextColorRuleKind
    public var exactText: String
    public var startDelimiter: String
    public var endDelimiter: String
    public var includesDelimiters: Bool
    public var colorHex: String

    public init(
        id: String = UUID().uuidString,
        isEnabled: Bool = true,
        kind: ChatAppearanceTextColorRuleKind = .exactText,
        exactText: String = "",
        startDelimiter: String = "",
        endDelimiter: String = "",
        includesDelimiters: Bool = true,
        colorHex: String
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.kind = kind
        self.exactText = exactText
        self.startDelimiter = startDelimiter
        self.endDelimiter = endDelimiter
        self.includesDelimiters = includesDelimiters
        self.colorHex = colorHex
    }

    public var isConfigured: Bool {
        switch kind {
        case .exactText, .regularExpression:
            return !exactText.isEmpty
        case .delimitedText:
            return !startDelimiter.isEmpty && !endDelimiter.isEmpty
        }
    }
}

protocol ChatAppearanceTextMatchingRule {
    var id: String { get }
    var isEnabled: Bool { get }
    var kind: ChatAppearanceTextRuleKind { get }
    var exactText: String { get }
    var startDelimiter: String { get }
    var endDelimiter: String { get }
    var includesDelimiters: Bool { get }
    var hasConfiguredMatch: Bool { get }
}

extension ChatAppearanceTextColorRule: ChatAppearanceTextMatchingRule {
    var hasConfiguredMatch: Bool {
        isConfigured
    }
}

struct ChatAppearanceTextMatchSpan {
    let location: Int
    let length: Int
    let ruleID: String
}

public struct ChatAppearanceTextColorSpan: Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public let colorHex: String
    public let ruleID: String

    public init(location: Int, length: Int, colorHex: String, ruleID: String) {
        self.location = location
        self.length = length
        self.colorHex = colorHex
        self.ruleID = ruleID
    }

    public var range: Range<Int> {
        location..<(location + length)
    }
}

enum ChatAppearanceTextMatchingEngine {
    static func spans<Rule: ChatAppearanceTextMatchingRule>(
        in text: String,
        rules: [Rule],
        excludedRanges: [Range<Int>] = []
    ) -> [ChatAppearanceTextMatchSpan] {
        let textUnits = Array(text.utf16)
        guard !textUnits.isEmpty else { return [] }

        let protectedRanges = excludedRanges
            .map { max(0, $0.lowerBound)..<min(textUnits.count, $0.upperBound) }
            .filter { !$0.isEmpty }
        var occupiedRanges = protectedRanges
        var result: [ChatAppearanceTextMatchSpan] = []

        for rule in rules where rule.isEnabled && rule.hasConfiguredMatch {
            let candidates = candidateRanges(for: rule, in: text, textUnits: textUnits)
            for candidate in candidates {
                let availableRanges = subtract(occupiedRanges, from: candidate)
                for range in availableRanges where !range.isEmpty {
                    result.append(
                        ChatAppearanceTextMatchSpan(
                            location: range.lowerBound,
                            length: range.count,
                            ruleID: rule.id
                        )
                    )
                    occupiedRanges.append(range)
                }
            }
        }

        return result.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
    }

    private static func candidateRanges<Rule: ChatAppearanceTextMatchingRule>(
        for rule: Rule,
        in text: String,
        textUnits: [UTF16.CodeUnit]
    ) -> [Range<Int>] {
        switch rule.kind {
        case .exactText:
            return exactRanges(of: Array(rule.exactText.utf16), in: textUnits)
        case .delimitedText:
            return delimitedRanges(
                start: Array(rule.startDelimiter.utf16),
                end: Array(rule.endDelimiter.utf16),
                includesDelimiters: rule.includesDelimiters,
                in: textUnits
            )
        case .regularExpression:
            return regularExpressionRanges(pattern: rule.exactText, in: text)
        }
    }

    static func isValidRegularExpression(_ pattern: String) async -> Bool {
        guard !pattern.isEmpty else { return true }
        return await Task.detached(priority: .userInitiated) {
            (try? NSRegularExpression(pattern: pattern)) != nil
        }.value
    }

    private static func regularExpressionRanges(
        pattern: String,
        in text: String
    ) -> [Range<Int>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: searchRange).compactMap { match in
            guard match.range.location != NSNotFound, match.range.length > 0 else {
                return nil
            }
            return match.range.location..<(match.range.location + match.range.length)
        }
    }

    private static func exactRanges(
        of needle: [UTF16.CodeUnit],
        in text: [UTF16.CodeUnit]
    ) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= text.count else { return [] }
        var ranges: [Range<Int>] = []
        var cursor = 0
        while let start = firstIndex(of: needle, in: text, from: cursor) {
            let end = start + needle.count
            ranges.append(start..<end)
            cursor = end
        }
        return ranges
    }

    private static func delimitedRanges(
        start: [UTF16.CodeUnit],
        end: [UTF16.CodeUnit],
        includesDelimiters: Bool,
        in text: [UTF16.CodeUnit]
    ) -> [Range<Int>] {
        guard !start.isEmpty, !end.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var cursor = 0

        while let startIndex = firstIndex(of: start, in: text, from: cursor) {
            let contentStart = startIndex + start.count
            guard let endIndex = firstIndex(of: end, in: text, from: contentStart) else {
                break
            }
            let matchEnd = endIndex + end.count
            let range = includesDelimiters ? startIndex..<matchEnd : contentStart..<endIndex
            if !range.isEmpty {
                ranges.append(range)
            }
            cursor = matchEnd
        }
        return ranges
    }

    private static func firstIndex(
        of needle: [UTF16.CodeUnit],
        in text: [UTF16.CodeUnit],
        from startIndex: Int
    ) -> Int? {
        guard !needle.isEmpty, startIndex >= 0, startIndex + needle.count <= text.count else {
            return nil
        }
        let lastStart = text.count - needle.count
        guard startIndex <= lastStart else { return nil }

        for index in startIndex...lastStart where text[index] == needle[0] {
            if text[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
        }
        return nil
    }

    private static func subtract(
        _ occupiedRanges: [Range<Int>],
        from candidate: Range<Int>
    ) -> [Range<Int>] {
        var remaining = [candidate]
        for occupied in occupiedRanges where occupied.overlaps(candidate) {
            remaining = remaining.flatMap { range -> [Range<Int>] in
                guard range.overlaps(occupied) else { return [range] }
                var fragments: [Range<Int>] = []
                if range.lowerBound < occupied.lowerBound {
                    fragments.append(range.lowerBound..<min(range.upperBound, occupied.lowerBound))
                }
                if occupied.upperBound < range.upperBound {
                    fragments.append(max(range.lowerBound, occupied.upperBound)..<range.upperBound)
                }
                return fragments
            }
        }
        return remaining
    }
}

public enum ChatAppearanceTextColorMatcher {
    public static func spans(
        in text: String,
        rules: [ChatAppearanceTextColorRule],
        excludedRanges: [Range<Int>] = []
    ) -> [ChatAppearanceTextColorSpan] {
        let colorByRuleID = rules.reduce(into: [String: String]()) { result, rule in
            if result[rule.id] == nil {
                result[rule.id] = rule.colorHex
            }
        }
        return ChatAppearanceTextMatchingEngine.spans(
            in: text,
            rules: rules,
            excludedRanges: excludedRanges
        ).compactMap { span in
            guard let colorHex = colorByRuleID[span.ruleID] else { return nil }
            return ChatAppearanceTextColorSpan(
                location: span.location,
                length: span.length,
                colorHex: colorHex,
                ruleID: span.ruleID
            )
        }
    }

    public static func isValidRegularExpression(_ pattern: String) async -> Bool {
        await ChatAppearanceTextMatchingEngine.isValidRegularExpression(pattern)
    }
}
