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
            candidates = [Self.commandText(executable: request.executable, arguments: request.arguments)]
        case .shell:
            scope = .shell
            candidates = [request.shellScript ?? "", Self.commandText(executable: request.executable, arguments: request.arguments)]
        case .terminal, .browser:
            return nil
        }

        for compiled in compiledRules(rules) where
            compiled.rule.isEnabled &&
            (compiled.rule.scope == .all || compiled.rule.scope == scope) {
            for candidate in candidates where !candidate.isEmpty {
                if let matchedText = Self.match(compiled, in: candidate) {
                    return LocalLinuxCommandRuleMatch(
                        ruleID: compiled.rule.id,
                        ruleName: compiled.rule.name,
                        action: compiled.rule.action,
                        matchedText: matchedText
                    )
                }
            }
        }
        return nil
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
}
