// ============================================================================
// ChatAppearanceTextFontRules.swift
// ============================================================================
// 聊天文字局部字体规则与匹配结果。
// ============================================================================

import Foundation

public struct ChatAppearanceTextFontRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var isEnabled: Bool
    public var kind: ChatAppearanceTextRuleKind
    public var exactText: String
    public var startDelimiter: String
    public var endDelimiter: String
    public var includesDelimiters: Bool
    public var fontAssetIDs: [UUID]

    public init(
        id: String = UUID().uuidString,
        isEnabled: Bool = true,
        kind: ChatAppearanceTextRuleKind = .exactText,
        exactText: String = "",
        startDelimiter: String = "",
        endDelimiter: String = "",
        includesDelimiters: Bool = true,
        fontAssetIDs: [UUID] = []
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.kind = kind
        self.exactText = exactText
        self.startDelimiter = startDelimiter
        self.endDelimiter = endDelimiter
        self.includesDelimiters = includesDelimiters
        self.fontAssetIDs = fontAssetIDs
    }

    public var hasConfiguredMatch: Bool {
        switch kind {
        case .exactText, .regularExpression:
            return !exactText.isEmpty
        case .delimitedText:
            return !startDelimiter.isEmpty && !endDelimiter.isEmpty
        }
    }

    public var isConfigured: Bool {
        hasConfiguredMatch && !fontAssetIDs.isEmpty
    }
}

extension ChatAppearanceTextFontRule: ChatAppearanceTextMatchingRule {}

public struct ChatAppearanceResolvedTextFontRule: Equatable, Hashable, Sendable {
    public let rule: ChatAppearanceTextFontRule
    public let postScriptNames: [String]

    public init(rule: ChatAppearanceTextFontRule, postScriptNames: [String]) {
        self.rule = rule
        self.postScriptNames = postScriptNames
    }
}

public struct ChatAppearanceTextFontSpan: Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public let ruleID: String

    public init(location: Int, length: Int, ruleID: String) {
        self.location = location
        self.length = length
        self.ruleID = ruleID
    }

    public var range: Range<Int> {
        location..<(location + length)
    }
}

public enum ChatAppearanceTextFontMatcher {
    public static func spans(
        in text: String,
        rules: [ChatAppearanceTextFontRule],
        excludedRanges: [Range<Int>] = []
    ) -> [ChatAppearanceTextFontSpan] {
        ChatAppearanceTextMatchingEngine.spans(
            in: text,
            rules: rules.filter(\.isConfigured),
            excludedRanges: excludedRanges
        ).map { span in
            ChatAppearanceTextFontSpan(
                location: span.location,
                length: span.length,
                ruleID: span.ruleID
            )
        }
    }
}
