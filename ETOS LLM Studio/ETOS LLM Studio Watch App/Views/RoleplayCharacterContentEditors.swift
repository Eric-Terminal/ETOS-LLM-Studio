// ============================================================================
// RoleplayCharacterContentEditors.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 端以二级列表编辑角色卡正则与助手脚本。
// ============================================================================

import ETOSCore
import SwiftUI

struct WatchRoleplayRegexRulesView: View {
    let characterID: UUID

    @State private var rules: [RoleplayRegexRule] = []
    @State private var editingRule: RoleplayRegexRule?

    var body: some View {
        List {
            Section {
                Button {
                    editingRule = RoleplayRegexRule()
                } label: {
                    Label(NSLocalizedString("新增正则", comment: "Add character regex"), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("角色正则", comment: "Character regex")) {
                if rules.isEmpty {
                    Text(NSLocalizedString("暂无角色正则。", comment: "No character regex rules"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            HStack {
                                Text(rule.scriptName.isEmpty ? NSLocalizedString("未命名正则", comment: "Unnamed regex") : rule.scriptName)
                                Spacer()
                                Image(systemName: rule.disabled ? "pause.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(rule.disabled ? Color.gray : Color.green)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        rules.remove(atOffsets: offsets)
                        persist()
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("角色正则", comment: "Character regex title"))
        .task { reload() }
        .sheet(item: $editingRule) { rule in
            WatchRoleplayRegexRuleEditorView(rule: rule) { updated in
                if let index = rules.firstIndex(where: { $0.id == updated.id }) {
                    rules[index] = updated
                } else {
                    rules.append(updated)
                }
                persist()
            }
        }
    }

    private func reload() {
        Task {
            rules = await Task.detached(priority: .utility) {
                ChatService.shared.loadRoleplayCharacters().first { $0.id == characterID }?.regexRules ?? []
            }.value
        }
    }

    private func persist() {
        let updatedRules = rules
        Task {
            await Task.detached(priority: .utility) {
                guard var character = ChatService.shared.loadRoleplayCharacters().first(where: { $0.id == characterID }) else { return }
                character.regexRules = updatedRules
                ChatService.shared.saveRoleplayCharacter(character)
            }.value
        }
    }
}

private struct WatchRoleplayRegexRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: RoleplayRegexRule
    let onSave: (RoleplayRegexRule) -> Void

    init(rule: RoleplayRegexRule, onSave: @escaping (RoleplayRegexRule) -> Void) {
        self._rule = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("正则名称", comment: "Regex name"), text: $rule.scriptName.watchKeyboardNewlineBinding())
                Toggle(NSLocalizedString("启用正则", comment: "Enable regex"), isOn: enabledBinding)
                TextField(
                    NSLocalizedString("查找表达式", comment: "Regex find expression"),
                    text: $rule.findRegex.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                TextField(
                    NSLocalizedString("替换内容", comment: "Regex replacement"),
                    text: $rule.replaceString.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(rule)
                    dismiss()
                }
            }
            .navigationTitle(NSLocalizedString("编辑角色正则", comment: "Edit character regex"))
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { !rule.disabled }, set: { rule.disabled = !$0 })
    }
}

struct WatchRoleplayHelperScriptsView: View {
    let characterID: UUID

    @State private var scripts: [RoleplayHelperScript] = []
    @State private var editingScript: RoleplayHelperScript?

    var body: some View {
        List {
            Section {
                Button {
                    editingScript = RoleplayHelperScript(name: "", content: "")
                } label: {
                    Label(NSLocalizedString("新增脚本", comment: "Add helper script"), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("助手脚本", comment: "Helper scripts")) {
                if scripts.isEmpty {
                    Text(NSLocalizedString("暂无助手脚本。", comment: "No helper scripts"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scripts) { script in
                        Button {
                            editingScript = script
                        } label: {
                            HStack {
                                Text(script.name.isEmpty ? NSLocalizedString("未命名脚本", comment: "Unnamed script") : script.name)
                                Spacer()
                                Image(systemName: script.enabled ? "checkmark.circle.fill" : "pause.circle")
                                    .foregroundStyle(script.enabled ? .green : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        scripts.remove(atOffsets: offsets)
                        persist()
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("助手脚本", comment: "Helper scripts title"))
        .task { reload() }
        .sheet(item: $editingScript) { script in
            WatchRoleplayHelperScriptEditorView(script: script) { updated in
                if let index = scripts.firstIndex(where: { $0.id == updated.id }) {
                    scripts[index] = updated
                } else {
                    scripts.append(updated)
                }
                persist()
            }
        }
    }

    private func reload() {
        Task {
            scripts = await Task.detached(priority: .utility) {
                ChatService.shared.loadRoleplayCharacters().first { $0.id == characterID }?.helperScripts ?? []
            }.value
        }
    }

    private func persist() {
        let updatedScripts = scripts
        Task {
            await Task.detached(priority: .utility) {
                guard var character = ChatService.shared.loadRoleplayCharacters().first(where: { $0.id == characterID }) else { return }
                character.helperScripts = updatedScripts
                ChatService.shared.saveRoleplayCharacter(character)
            }.value
        }
    }
}

private struct WatchRoleplayHelperScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var script: RoleplayHelperScript
    let onSave: (RoleplayHelperScript) -> Void

    init(script: RoleplayHelperScript, onSave: @escaping (RoleplayHelperScript) -> Void) {
        self._script = State(initialValue: script)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("脚本名称", comment: "Script name"), text: $script.name.watchKeyboardNewlineBinding())
                Toggle(NSLocalizedString("启用脚本", comment: "Enable helper script"), isOn: $script.enabled)
                TextField(
                    NSLocalizedString("脚本说明", comment: "Script description"),
                    text: $script.info.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                TextField(
                    NSLocalizedString("脚本内容", comment: "Script content"),
                    text: $script.content.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(script)
                    dismiss()
                }
            }
            .navigationTitle(NSLocalizedString("编辑助手脚本", comment: "Edit helper script"))
        }
    }
}
