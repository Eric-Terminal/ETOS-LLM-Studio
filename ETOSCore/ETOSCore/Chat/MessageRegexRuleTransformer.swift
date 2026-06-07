// ============================================================================
// MessageRegexRuleTransformer.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行聊天消息正则替换。
// ============================================================================

import Foundation

public enum MessageRegexRuleTransformer {
    public static func apply(
        _ input: String,
        rules: [MessageRegexRule],
        scope: MessageRegexRoleScope,
        mode: MessageRegexMode
    ) -> String {
        guard !input.isEmpty, !rules.isEmpty else { return input }

        var output = input
        for rule in rules {
            guard rule.isEnabled else { continue }
            guard rule.mode == mode else { continue }
            guard rule.scopes.contains(scope) else { continue }

            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }

            do {
                let regex = try NSRegularExpression(pattern: pattern)
                output = replaceMatches(
                    in: output,
                    regex: regex,
                    replacement: rule.replacement
                )
            } catch {
                continue
            }
        }
        return output
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression,
        replacement: String
    ) -> String {
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            result.replaceCharacters(
                in: match.range,
                with: expandedReplacement(replacement, match: match, source: nsText)
            )
        }
        return result as String
    }

    private static func expandedReplacement(
        _ replacement: String,
        match: NSTextCheckingResult,
        source: NSString
    ) -> String {
        let pattern = #"\$(\d{1,2})"#
        guard let refRegex = try? NSRegularExpression(pattern: pattern) else {
            return replacement
        }

        let nsReplacement = replacement as NSString
        let matches = refRegex.matches(
            in: replacement,
            range: NSRange(location: 0, length: nsReplacement.length)
        )
        guard !matches.isEmpty else { return replacement }

        let result = NSMutableString(string: replacement)
        for ref in matches.reversed() {
            guard ref.numberOfRanges > 1,
                  ref.range(at: 1).location != NSNotFound else {
                continue
            }

            let groupText = nsReplacement.substring(with: ref.range(at: 1))
            guard let groupIndex = Int(groupText),
                  groupIndex < match.numberOfRanges else {
                continue
            }

            let groupRange = match.range(at: groupIndex)
            guard groupRange.location != NSNotFound else {
                result.replaceCharacters(in: ref.range, with: "")
                continue
            }

            result.replaceCharacters(in: ref.range, with: source.substring(with: groupRange))
        }
        return result as String
    }
}
