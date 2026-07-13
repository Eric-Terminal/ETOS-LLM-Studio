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

struct WatchRoleplayCharacterProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var character: RoleplayCharacter
    @State private var greetingDrafts: [WatchRoleplayGreetingDraft]
    @State private var tagsText: String
    @State private var initialVariablesJSON: String
    @State private var isSaving = false
    @State private var errorText: String?

    init(character: RoleplayCharacter) {
        self._character = State(initialValue: character)
        self._greetingDrafts = State(initialValue: character.alternateGreetings.enumerated().map {
            WatchRoleplayGreetingDraft(number: $0.offset + 1, text: $0.element)
        })
        self._tagsText = State(initialValue: character.tags.joined(separator: ", "))
        self._initialVariablesJSON = State(initialValue: Self.jsonString(character.initialVariables))
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基本信息", comment: "Character basic information")) {
                TextField(NSLocalizedString("名称", comment: "Character name"), text: $character.name.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("作者", comment: "Character creator"), text: $character.creator.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("版本", comment: "Character version"), text: $character.characterVersion.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("标签（逗号分隔）", comment: "Character tags separated by commas"), text: $tagsText.watchKeyboardNewlineBinding())
            }

            watchMultilineSection(NSLocalizedString("角色描述", comment: "Character description"), text: $character.description)
            watchMultilineSection(NSLocalizedString("性格摘要", comment: "Character personality summary"), text: $character.personality)
            watchMultilineSection(NSLocalizedString("场景", comment: "Character scenario"), text: $character.scenario)
            watchMultilineSection(NSLocalizedString("首条消息", comment: "Character first message"), text: $character.firstMessage)

            Section(NSLocalizedString("候选开场白", comment: "Alternate greetings")) {
                if greetingDrafts.isEmpty {
                    Text(NSLocalizedString("暂无候选开场白。", comment: "No alternate greetings"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($greetingDrafts) { $draft in
                        TextField(
                            String(format: NSLocalizedString("开场白 %d", comment: "Greeting number"), draft.number),
                            text: $draft.text.watchKeyboardNewlineBinding(),
                            axis: .vertical
                        )
                        Button(role: .destructive) {
                            greetingDrafts.removeAll { $0.id == draft.id }
                            renumberGreetingDrafts()
                        } label: {
                            Label(NSLocalizedString("删除此开场白", comment: "Delete this greeting"), systemImage: "trash")
                        }
                    }
                }
                Button {
                    greetingDrafts.append(WatchRoleplayGreetingDraft(number: greetingDrafts.count + 1))
                } label: {
                    Label(NSLocalizedString("新增开场白", comment: "Add alternate greeting"), systemImage: "plus")
                }
            }

            watchMultilineSection(NSLocalizedString("示例对话", comment: "Character example messages"), text: $character.messageExamples)
            watchMultilineSection(NSLocalizedString("系统提示词", comment: "Character system prompt"), text: $character.systemPrompt)
            watchMultilineSection(NSLocalizedString("历史后指令", comment: "Character post-history instructions"), text: $character.postHistoryInstructions)
            watchMultilineSection(NSLocalizedString("创作者备注", comment: "Character creator notes"), text: $character.creatorNotes)

            Section(NSLocalizedString("初始变量", comment: "Character initial variables")) {
                TextField(
                    NSLocalizedString("JSON 对象", comment: "JSON object field"),
                    text: $initialVariablesJSON.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .font(.system(.body, design: .monospaced))
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label(NSLocalizedString("保存角色卡资料", comment: "Save character profile"), systemImage: "checkmark")
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle(NSLocalizedString("角色卡资料", comment: "Character card profile title"))
    }

    private func watchMultilineSection(_ title: String, text: Binding<String>) -> some View {
        Section(title) {
            TextField(title, text: text.watchKeyboardNewlineBinding(), axis: .vertical)
        }
    }

    private func renumberGreetingDrafts() {
        for index in greetingDrafts.indices {
            greetingDrafts[index].number = index + 1
        }
    }

    private func save() {
        guard !isSaving else { return }
        let trimmedName = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorText = NSLocalizedString("角色名称不能为空。", comment: "Character name cannot be empty")
            return
        }
        let variablesJSON = initialVariablesJSON
        let greetings = greetingDrafts.map(\.text)
        let tags = tagsText
        let sourceCharacter = character
        isSaving = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    guard let data = variablesJSON.data(using: .utf8),
                          let initialVariables = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                        throw WatchRoleplayCharacterProfileEditorError.invalidInitialVariables
                    }
                    var updated = sourceCharacter
                    updated.name = trimmedName
                    updated.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    updated.alternateGreetings = greetings
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    updated.initialVariables = initialVariables
                    ChatService.shared.saveRoleplayCharacter(updated)
                }.value
                dismiss()
            } catch {
                errorText = error.localizedDescription
                isSaving = false
            }
        }
    }

    private static func jsonString(_ values: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(values),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

private struct WatchRoleplayGreetingDraft: Identifiable {
    let id: UUID
    var number: Int
    var text: String

    init(id: UUID = UUID(), number: Int, text: String = "") {
        self.id = id
        self.number = number
        self.text = text
    }
}

private enum WatchRoleplayCharacterProfileEditorError: LocalizedError {
    case invalidInitialVariables

    var errorDescription: String? {
        NSLocalizedString("初始变量必须是有效的 JSON 对象。", comment: "Invalid character initial variables")
    }
}
