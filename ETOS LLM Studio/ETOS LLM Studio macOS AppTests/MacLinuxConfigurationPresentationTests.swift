import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxConfigurationPresentationTests {
    @Test("根页向导只列变量名称和状态，不读取值、备注或规则匹配文本")
    func guideCatalogExcludesPrivateValues() throws {
        let variable = LocalLinuxEnvironmentVariable(name: "TOKEN", value: "私密值", note: "私密备注")
        let rule = LocalLinuxCommandRule(name: "规则", pattern: "私密匹配文本", matchKind: .prefix, scope: .run, action: .confirm)
        let snapshot = LocalLinuxConfigurationSnapshot(variables: [variable], rules: [rule], shortcuts: [], shortcutEncoding: "[]")
        let catalog = MacLinuxConfigurationCatalog.prepare(snapshot)
        guard case .array(let variables) = catalog.guideVariables, case .dictionary(let fields)? = variables.first,
              case .array(let rules) = catalog.guideRules, case .dictionary(let ruleFields)? = rules.first else {
            Issue.record("缺少配置目录快照"); return
        }
        #expect(Set(fields.keys) == ["id", "name", "enabled"])
        #expect(Set(ruleFields.keys) == ["id", "name", "enabled", "match_kind", "scope", "action", "priority"])
        #expect(catalog.snapshot.variables[0].value == "私密值")
    }

    @Test("后台目录保留顺序并为首尾项准备正确的移动状态")
    func orderingAndMovementAvailability() {
        let rules = ["第一项", "第二项"].map { LocalLinuxCommandRule(name: $0, pattern: $0, matchKind: .suffix, scope: .all, action: .deny) }
        let shortcuts = [LocalLinuxTerminalShortcut(keys: [.control, .c]), LocalLinuxTerminalShortcut(keys: [.tab])]
        let snapshot = LocalLinuxConfigurationSnapshot(variables: [], rules: rules, shortcuts: shortcuts, shortcutEncoding: LocalLinuxTerminalShortcutConfiguration.encode(shortcuts))
        let catalog = MacLinuxConfigurationCatalog.prepare(snapshot)
        #expect(catalog.rules.map(\.id) == rules.map(\.id)); #expect(catalog.shortcuts.map(\.id) == shortcuts.map(\.id))
        #expect(!catalog.rules[0].canMoveUp && catalog.rules[0].canMoveDown)
        #expect(catalog.rules[1].canMoveUp && !catalog.rules[1].canMoveDown)
        #expect(!catalog.shortcuts[0].canMoveUp && catalog.shortcuts[0].canMoveDown)
        #expect(catalog.shortcuts[1].canMoveUp && !catalog.shortcuts[1].canMoveDown)
        #expect(catalog.shortcuts[0].title == shortcuts[0].title)
    }
}
