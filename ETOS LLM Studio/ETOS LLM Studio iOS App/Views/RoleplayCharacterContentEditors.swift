// ============================================================================
// RoleplayCharacterContentEditors.swift
// ============================================================================
// ETOS LLM Studio
//
// 编辑角色卡携带的酒馆正则与助手脚本，并保留未展示的扩展字段。
// ============================================================================

import ETOSCore
import SwiftUI

struct RoleplayRegexRulesView: View {
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

            Section(String(format: NSLocalizedString("角色正则 (%d)", comment: "Character regex count"), rules.count)) {
                if rules.isEmpty {
                    Text(NSLocalizedString("暂无角色正则。", comment: "No character regex rules"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.scriptName.isEmpty ? NSLocalizedString("未命名正则", comment: "Unnamed regex") : rule.scriptName)
                                        .foregroundStyle(.primary)
                                    if !rule.findRegex.isEmpty {
                                        Text(rule.findRegex)
                                            .etFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: rule.disabled ? "pause.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(rule.disabled ? Color.gray : Color.green)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                delete(rule.id)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("角色正则", comment: "Character regex title"))
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reload()
        }
        .sheet(item: $editingRule) { rule in
            RoleplayRegexRuleEditorView(rule: rule) { updated in
                upsert(updated)
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

    private func upsert(_ rule: RoleplayRegexRule) {
        var updatedRules = rules
        if let index = updatedRules.firstIndex(where: { $0.id == rule.id }) {
            updatedRules[index] = rule
        } else {
            updatedRules.append(rule)
        }
        rules = updatedRules
        persist(updatedRules)
    }

    private func delete(_ ruleID: UUID) {
        let updatedRules = rules.filter { $0.id != ruleID }
        rules = updatedRules
        persist(updatedRules)
    }

    private func persist(_ updatedRules: [RoleplayRegexRule]) {
        Task {
            await Task.detached(priority: .utility) {
                guard var character = ChatService.shared.loadRoleplayCharacters().first(where: { $0.id == characterID }) else { return }
                character.regexRules = updatedRules
                ChatService.shared.saveRoleplayCharacter(character)
            }.value
        }
    }
}

private struct RoleplayRegexRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: RoleplayRegexRule
    @State private var trimStringsText: String
    let onSave: (RoleplayRegexRule) -> Void

    init(rule: RoleplayRegexRule, onSave: @escaping (RoleplayRegexRule) -> Void) {
        self._rule = State(initialValue: rule)
        self._trimStringsText = State(initialValue: rule.trimStrings.joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基本信息", comment: "Regex basic info")) {
                    TextField(NSLocalizedString("正则名称", comment: "Regex name"), text: $rule.scriptName)
                    Toggle(NSLocalizedString("启用正则", comment: "Enable regex"), isOn: enabledBinding)
                    Picker(NSLocalizedString("作用域", comment: "Regex scope"), selection: $rule.scope) {
                        ForEach(RoleplayRegexScope.allCases, id: \.self) { scope in
                            Text(scopeLabel(scope)).tag(scope)
                        }
                    }
                }

                Section(NSLocalizedString("查找表达式", comment: "Regex find expression")) {
                    TextEditor(text: $rule.findRegex)
                        .frame(minHeight: 100)
                }

                Section(NSLocalizedString("替换内容", comment: "Regex replacement")) {
                    TextEditor(text: $rule.replaceString)
                        .frame(minHeight: 100)
                }

                Section {
                    TextEditor(text: $trimStringsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(NSLocalizedString("修剪字符串", comment: "Regex trim strings"))
                } footer: {
                    Text(NSLocalizedString("每行填写一个需要从匹配结果中移除的字符串。", comment: "Regex trim strings hint"))
                }

                Section(NSLocalizedString("运行位置", comment: "Regex placements")) {
                    ForEach(RoleplayRegexPlacement.allCases, id: \.self) { placement in
                        Toggle(placementLabel(placement), isOn: placementBinding(placement))
                    }
                }

                Section(NSLocalizedString("运行选项", comment: "Regex run options")) {
                    Toggle(NSLocalizedString("仅 Markdown", comment: "Regex markdown only"), isOn: $rule.markdownOnly)
                    Toggle(NSLocalizedString("仅提示词", comment: "Regex prompt only"), isOn: $rule.promptOnly)
                    Toggle(NSLocalizedString("编辑时运行", comment: "Regex run on edit"), isOn: $rule.runOnEdit)
                    Picker(NSLocalizedString("宏替换", comment: "Regex macro substitution"), selection: $rule.substituteRegex) {
                        Text(NSLocalizedString("不替换宏", comment: "Do not substitute macros")).tag(0)
                        Text(NSLocalizedString("替换宏", comment: "Substitute macros")).tag(1)
                        Text(NSLocalizedString("转义后替换宏", comment: "Substitute escaped macros")).tag(2)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("编辑角色正则", comment: "Edit character regex"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "Save")) {
                        rule.trimStrings = trimStringsText
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { !rule.disabled }, set: { rule.disabled = !$0 })
    }

    private func placementBinding(_ placement: RoleplayRegexPlacement) -> Binding<Bool> {
        Binding(
            get: { rule.placements.contains(placement) },
            set: { isEnabled in
                if isEnabled {
                    if !rule.placements.contains(placement) { rule.placements.append(placement) }
                } else {
                    rule.placements.removeAll { $0 == placement }
                }
            }
        )
    }

    private func placementLabel(_ placement: RoleplayRegexPlacement) -> String {
        switch placement {
        case .userInput: return NSLocalizedString("用户输入", comment: "Regex placement user input")
        case .aiOutput: return NSLocalizedString("模型输出", comment: "Regex placement AI output")
        case .slashCommand: return NSLocalizedString("斜杠命令", comment: "Regex placement slash command")
        case .worldInfo: return NSLocalizedString("世界书内容", comment: "Regex placement world info")
        case .reasoning: return NSLocalizedString("推理内容", comment: "Regex placement reasoning")
        }
    }

    private func scopeLabel(_ scope: RoleplayRegexScope) -> String {
        switch scope {
        case .global: return NSLocalizedString("全局", comment: "Regex global scope")
        case .preset: return NSLocalizedString("预设", comment: "Regex preset scope")
        case .character: return NSLocalizedString("角色卡", comment: "Regex character scope")
        case .session: return NSLocalizedString("当前会话", comment: "Regex session scope")
        }
    }
}

struct RoleplayHelperScriptsView: View {
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

            Section(String(format: NSLocalizedString("助手脚本 (%d)", comment: "Helper script count"), scripts.count)) {
                if scripts.isEmpty {
                    Text(NSLocalizedString("暂无助手脚本。", comment: "No helper scripts"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scripts) { script in
                        Button {
                            editingScript = script
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(script.name.isEmpty ? NSLocalizedString("未命名脚本", comment: "Unnamed script") : script.name)
                                        .foregroundStyle(.primary)
                                    if !script.info.isEmpty {
                                        Text(script.info)
                                            .etFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: script.enabled ? "checkmark.circle.fill" : "pause.circle")
                                    .foregroundStyle(script.enabled ? .green : .secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                delete(script.id)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("助手脚本", comment: "Helper scripts title"))
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reload()
        }
        .sheet(item: $editingScript) { script in
            RoleplayHelperScriptEditorView(script: script) { updated in
                upsert(updated)
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

    private func upsert(_ script: RoleplayHelperScript) {
        var updatedScripts = scripts
        if let index = updatedScripts.firstIndex(where: { $0.id == script.id }) {
            updatedScripts[index] = script
        } else {
            updatedScripts.append(script)
        }
        scripts = updatedScripts
        persist(updatedScripts)
    }

    private func delete(_ scriptID: UUID) {
        let updatedScripts = scripts.filter { $0.id != scriptID }
        scripts = updatedScripts
        persist(updatedScripts)
    }

    private func persist(_ updatedScripts: [RoleplayHelperScript]) {
        Task {
            await Task.detached(priority: .utility) {
                guard var character = ChatService.shared.loadRoleplayCharacters().first(where: { $0.id == characterID }) else { return }
                character.helperScripts = updatedScripts
                ChatService.shared.saveRoleplayCharacter(character)
            }.value
        }
    }
}

private struct RoleplayHelperScriptEditorView: View {
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
                Section(NSLocalizedString("基本信息", comment: "Script basic info")) {
                    TextField(NSLocalizedString("脚本名称", comment: "Script name"), text: $script.name)
                    TextField(NSLocalizedString("脚本说明", comment: "Script description"), text: $script.info, axis: .vertical)
                    Toggle(NSLocalizedString("启用脚本", comment: "Enable helper script"), isOn: $script.enabled)
                }

                Section(NSLocalizedString("脚本内容", comment: "Script content")) {
                    TextEditor(text: $script.content)
                        .frame(minHeight: 260)
                }
            }
            .navigationTitle(NSLocalizedString("编辑助手脚本", comment: "Edit helper script"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "Save")) {
                        onSave(script)
                        dismiss()
                    }
                }
            }
        }
    }
}
