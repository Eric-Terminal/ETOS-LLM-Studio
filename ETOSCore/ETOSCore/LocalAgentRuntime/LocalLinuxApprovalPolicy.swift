// ============================================================================
// LocalLinuxApprovalPolicy.swift
// ============================================================================
// ETOS LLM Studio
//
// 命令规则是用户可关闭的反馈护栏，不承担 guest sandbox 的安全边界。
// ============================================================================

import Foundation

public actor LocalLinuxApprovalPolicy {
    public static let shared = LocalLinuxApprovalPolicy()

    private struct CompiledRule {
        let rule: LocalLinuxCommandRule
        let expression: NSRegularExpression?
    }

    public func rules() -> [LocalLinuxCommandRule] {
        Persistence.loadLocalLinuxCommandRules()
    }

    public func save(_ rule: LocalLinuxCommandRule) throws {
        if rule.matchKind == .regularExpression {
            _ = try NSRegularExpression(pattern: rule.pattern)
        }
        guard Persistence.saveLocalLinuxCommandRule(rule) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存命令安全规则。", comment: "Save Linux command rule failure")
            )
        }
    }

    public func delete(id: UUID) throws {
        guard Persistence.deleteLocalLinuxCommandRule(id: id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除命令安全规则。", comment: "Delete Linux command rule failure")
            )
        }
    }

    public func evaluate(
        request: LocalLinuxJobRequest,
        kind: LocalLinuxJobKind,
        isEnabled: Bool
    ) -> LocalLinuxCommandRuleMatch? {
        Self.evaluate(
            rules: rules(),
            request: request,
            kind: kind,
            isEnabled: isEnabled
        )
    }

    static func evaluate(
        rules: [LocalLinuxCommandRule],
        request: LocalLinuxJobRequest,
        kind: LocalLinuxJobKind,
        isEnabled: Bool
    ) -> LocalLinuxCommandRuleMatch? {
        guard isEnabled else { return nil }
        let scope: LocalLinuxCommandRuleScope
        let candidates: [String]
        switch kind {
        case .run, .recipe, .localMCP:
            scope = .run
            let command = Self.commandText(executable: request.executable, arguments: request.arguments)
            if let script = request.shellScript, !script.isEmpty {
                candidates = [script] + Self.shellCommandFragments(script) + [command]
            } else {
                candidates = [command]
            }
        case .shell:
            scope = .shell
            let script = request.shellScript ?? ""
            candidates = [script]
                + Self.shellCommandFragments(script)
                + [Self.commandText(executable: request.executable, arguments: request.arguments)]
        case .terminal, .browser:
            return nil
        }

        var effectiveMatch: LocalLinuxCommandRuleMatch?
        for compiled in compiledRules(rules) where
            compiled.rule.isEnabled &&
            (compiled.rule.scope == .all || compiled.rule.scope == scope) {
            for candidate in candidates where !candidate.isEmpty {
                if let matchedText = Self.match(compiled, in: candidate) {
                    let match = LocalLinuxCommandRuleMatch(
                        ruleID: compiled.rule.id,
                        ruleName: compiled.rule.name,
                        action: compiled.rule.action,
                        matchedText: matchedText
                    )
                    // 整段脚本只弹出一次治理结果，但必须扫描全部命令片段；拒绝不能
                    // 被前一段命令命中的提醒规则遮住。同级动作仍保留用户排序。
                    if let current = effectiveMatch {
                        if Self.actionPriority(match.action) > Self.actionPriority(current.action) {
                            effectiveMatch = match
                        }
                    } else {
                        effectiveMatch = match
                    }
                }
            }
        }
        return effectiveMatch
    }

    private nonisolated static func compiledRules(_ rules: [LocalLinuxCommandRule]) -> [CompiledRule] {
        rules.map { rule in
            CompiledRule(
                rule: rule,
                expression: rule.matchKind == .regularExpression
                    ? try? NSRegularExpression(pattern: rule.pattern)
                    : nil
            )
        }
    }

    private nonisolated static func match(_ compiled: CompiledRule, in candidate: String) -> String? {
        switch compiled.rule.matchKind {
        case .prefix:
            guard candidate.hasPrefix(compiled.rule.pattern) else { return nil }
            return compiled.rule.pattern
        case .suffix:
            guard candidate.hasSuffix(compiled.rule.pattern) else { return nil }
            return compiled.rule.pattern
        case .regularExpression:
            guard let expression = compiled.expression else { return nil }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = expression.firstMatch(in: candidate, range: range),
                  let swiftRange = Range(match.range, in: candidate) else {
                return nil
            }
            return String(candidate[swiftRange])
        }
    }

    private nonisolated static func commandText(executable: String, arguments: [String]) -> String {
        ([executable] + Array(arguments.dropFirst())).joined(separator: " ")
    }

    private nonisolated static func actionPriority(_ action: LocalLinuxCommandRuleAction) -> Int {
        switch action {
        case .warn: return 0
        case .confirm: return 1
        case .deny: return 2
        }
    }

    /// Shell 规则逐条检查组合脚本，避免 `safe && dangerous` 绕过第二条命令的前后缀规则。
    /// 这里只识别 shell 控制运算符；引号内文字和反斜杠转义不会被误当成命令边界。
    nonisolated static func shellCommandFragments(_ script: String) -> [String] {
        enum Quote: Equatable {
            case single
            case double
        }

        var fragments: [String] = []
        var fragmentStart = script.startIndex
        var index = script.startIndex
        var quote: Quote?
        var isEscaped = false

        func appendFragment(endingAt end: String.Index) {
            let fragment = script[fragmentStart..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fragment.isEmpty {
                fragments.append(fragment)
            }
        }

        while index < script.endIndex {
            let character = script[index]
            let next = script.index(after: index)

            if isEscaped {
                isEscaped = false
                index = next
                continue
            }
            if character == "\\", quote != .single {
                isEscaped = true
                index = next
                continue
            }
            if character == "'", quote != .double {
                quote = quote == .single ? nil : .single
                index = next
                continue
            }
            if character == "\"", quote != .single {
                quote = quote == .double ? nil : .double
                index = next
                continue
            }

            guard quote == nil,
                  character == ";" || character == "&" || character == "|" || character == "\n" else {
                index = next
                continue
            }

            appendFragment(endingAt: index)
            var boundaryEnd = next
            if (character == "&" || character == "|"),
               boundaryEnd < script.endIndex,
               script[boundaryEnd] == character {
                boundaryEnd = script.index(after: boundaryEnd)
            }
            fragmentStart = boundaryEnd
            index = boundaryEnd
        }

        appendFragment(endingAt: script.endIndex)
        return fragments
    }
}
