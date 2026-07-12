// ============================================================================
// RoleplayRegexTransformer.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行 SillyTavern 角色级正则的 placement、深度、宏和捕获组语义。
// ============================================================================

import Foundation

public struct RoleplayRegexContext: Sendable {
    public var placement: RoleplayRegexPlacement
    public var isMarkdown: Bool
    public var isPrompt: Bool
    public var isEdit: Bool
    public var depth: Int?
    public var macroContext: RoleplayMacroContext

    public init(
        placement: RoleplayRegexPlacement,
        isMarkdown: Bool = false,
        isPrompt: Bool = false,
        isEdit: Bool = false,
        depth: Int? = nil,
        macroContext: RoleplayMacroContext = .init()
    ) {
        self.placement = placement
        self.isMarkdown = isMarkdown
        self.isPrompt = isPrompt
        self.isEdit = isEdit
        self.depth = depth
        self.macroContext = macroContext
    }
}

public enum RoleplayRegexTransformer {
    public static func apply(
        _ input: String,
        rules: [RoleplayRegexRule],
        context: RoleplayRegexContext
    ) -> String {
        var context = context
        return apply(input, rules: rules, context: &context)
    }

    public static func apply(
        _ input: String,
        rules: [RoleplayRegexRule],
        context: inout RoleplayRegexContext
    ) -> String {
        guard !input.isEmpty, !rules.isEmpty else { return input }
        var output = input
        for rule in rules where shouldRun(rule, context: context) {
            output = apply(rule, to: output, context: &context)
        }
        return output
    }

    private static func shouldRun(_ rule: RoleplayRegexRule, context: RoleplayRegexContext) -> Bool {
        guard !rule.disabled, !rule.findRegex.isEmpty, rule.placements.contains(context.placement) else { return false }
        let matchesMode = (rule.markdownOnly && context.isMarkdown)
            || (rule.promptOnly && context.isPrompt)
            || (!rule.markdownOnly && !rule.promptOnly && !context.isMarkdown && !context.isPrompt)
        guard matchesMode else { return false }
        if context.isEdit && !rule.runOnEdit { return false }
        if let depth = context.depth {
            if let minDepth = rule.minDepth, minDepth >= -1, depth < minDepth { return false }
            if let maxDepth = rule.maxDepth, maxDepth >= 0, depth > maxDepth { return false }
        }
        return true
    }

    private static func apply(
        _ rule: RoleplayRegexRule,
        to input: String,
        context: inout RoleplayRegexContext
    ) -> String {
        var pattern = rule.findRegex
        if rule.substituteRegex != 0 {
            let resolved = RoleplayMacroResolver.resolve(pattern, context: &context.macroContext)
            pattern = rule.substituteRegex == 2 ? NSRegularExpression.escapedPattern(for: resolved) : resolved
        }
        let parsed = parsedPattern(pattern)
        guard let regex = try? NSRegularExpression(pattern: parsed.pattern, options: parsed.options) else { return input }
        let source = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return input }

        let result = NSMutableString(string: input)
        for match in matches.reversed() {
            let expanded = expandedReplacement(
                rule.replaceString.replacingOccurrences(of: "{{match}}", with: "$0", options: .caseInsensitive),
                match: match,
                source: source,
                trimStrings: rule.trimStrings,
                macroContext: &context.macroContext
            )
            result.replaceCharacters(in: match.range, with: expanded)
        }
        return result as String
    }

    private static func parsedPattern(_ raw: String) -> (pattern: String, options: NSRegularExpression.Options) {
        guard raw.hasPrefix("/"), let closing = closingSlashIndex(in: raw) else {
            return (raw, [])
        }
        let pattern = String(raw[raw.index(after: raw.startIndex)..<closing])
        let flags = String(raw[raw.index(after: closing)...])
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        return (pattern, options)
    }

    private static func closingSlashIndex(in raw: String) -> String.Index? {
        var escaped = false
        for index in raw.indices.dropFirst().reversed() {
            if raw[index] != "/" { continue }
            var slashCount = 0
            var cursor = raw.index(before: index)
            while raw[cursor] == "\\" {
                slashCount += 1
                guard cursor > raw.startIndex else { break }
                cursor = raw.index(before: cursor)
            }
            escaped = slashCount % 2 == 1
            if !escaped { return index }
        }
        return nil
    }

    private static func expandedReplacement(
        _ replacement: String,
        match: NSTextCheckingResult,
        source: NSString,
        trimStrings: [String],
        macroContext: inout RoleplayMacroContext
    ) -> String {
        guard let tokenRegex = try? NSRegularExpression(
            pattern: #"\$(\$|&|`|'|\d{1,2}|<([A-Za-z_][A-Za-z0-9_]*)>)"#
        ) else { return replacement }
        let template = replacement as NSString
        let result = NSMutableString(string: replacement)
        for token in tokenRegex.matches(
            in: replacement,
            range: NSRange(location: 0, length: template.length)
        ).reversed() {
            let raw = template.substring(with: token.range(at: 1))
            let captured: String
            if raw == "$" {
                captured = "$"
            } else if raw == "&" {
                captured = source.substring(with: match.range)
            } else if raw == "`" {
                captured = source.substring(to: match.range.location)
            } else if raw == "'" {
                captured = source.substring(from: NSMaxRange(match.range))
            } else if raw.hasPrefix("<"), token.numberOfRanges > 2, token.range(at: 2).location != NSNotFound {
                let name = template.substring(with: token.range(at: 2))
                let range = match.range(withName: name)
                captured = range.location == NSNotFound ? "" : source.substring(with: range)
            } else if let index = Int(raw), index < match.numberOfRanges {
                let range = match.range(at: index)
                captured = range.location == NSNotFound ? "" : source.substring(with: range)
            } else {
                captured = ""
            }
            let filtered = trimStrings.reduce(captured) { partial, trimString in
                let resolved = RoleplayMacroResolver.resolve(trimString, context: macroContext)
                return partial.replacingOccurrences(of: resolved, with: "")
            }
            result.replaceCharacters(in: token.range, with: filtered)
        }
        return RoleplayMacroResolver.resolve(result as String, context: &macroContext)
    }
}
