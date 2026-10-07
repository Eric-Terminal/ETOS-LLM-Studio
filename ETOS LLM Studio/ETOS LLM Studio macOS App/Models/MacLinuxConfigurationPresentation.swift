import ETOSCore
import Foundation

struct MacLinuxRuleRow: Identifiable, Sendable {
    let rule: LocalLinuxCommandRule
    let action: String
    let scope: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    var id: UUID { rule.id }
}

struct MacLinuxShortcutRow: Identifiable, Sendable {
    let shortcut: LocalLinuxTerminalShortcut
    let title: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    var id: UUID { shortcut.id }
}

struct MacLinuxConfigurationCatalog: Sendable {
    let snapshot: LocalLinuxConfigurationSnapshot
    let rules: [MacLinuxRuleRow]
    let shortcuts: [MacLinuxShortcutRow]
    let guideVariables: JSONValue
    let guideRules: JSONValue
    let guideShortcuts: JSONValue

    static func prepare(_ snapshot: LocalLinuxConfigurationSnapshot) -> Self {
        Self(snapshot: snapshot,
            rules: snapshot.rules.enumerated().map { index, rule in
                MacLinuxRuleRow(rule: rule, action: rule.action.displayName, scope: rule.scope.displayName,
                    canMoveUp: index > 0, canMoveDown: index + 1 < snapshot.rules.count)
            },
            shortcuts: snapshot.shortcuts.enumerated().map { index, shortcut in
                MacLinuxShortcutRow(shortcut: shortcut, title: shortcut.title,
                    canMoveUp: index > 0, canMoveDown: index + 1 < snapshot.shortcuts.count)
            },
            guideVariables: .array(snapshot.variables.map { .dictionary([
                "id": .string($0.id.uuidString), "name": .string($0.name), "enabled": .bool($0.isEnabled)
            ]) }),
            guideRules: .array(snapshot.rules.map { .dictionary([
                "id": .string($0.id.uuidString), "name": .string($0.name), "enabled": .bool($0.isEnabled),
                "match_kind": .string($0.matchKind.rawValue), "scope": .string($0.scope.rawValue),
                "action": .string($0.action.rawValue), "priority": .int($0.sortIndex)
            ]) }),
            guideShortcuts: GuideLocalLinuxTerminalShortcutSettingsSupport.value(snapshot.shortcuts))
    }
}

struct MacLinuxVariableEditorTarget: Identifiable {
    let id = UUID()
    let original: LocalLinuxEnvironmentVariable?
}

struct MacLinuxRuleEditorTarget: Identifiable {
    let id = UUID()
    let original: LocalLinuxCommandRule?
}

struct MacLinuxShortcutEditorTarget: Identifiable, Sendable {
    let id = UUID()
    let original: LocalLinuxTerminalShortcut?
    let shortcuts: [LocalLinuxTerminalShortcut]
    let encoding: String
}
