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

struct RoleplayCharacterProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let isCreating: Bool
    @State private var character: RoleplayCharacter
    @State private var greetingDrafts: [RoleplayGreetingDraft]
    @State private var tagsText: String
    @State private var initialVariablesJSON: String
    @State private var isSaving = false
    @State private var errorText: String?

    init(character: RoleplayCharacter, isCreating: Bool = false) {
        self.isCreating = isCreating
        self._character = State(initialValue: character)
        self._greetingDrafts = State(initialValue: character.alternateGreetings.enumerated().map {
            RoleplayGreetingDraft(number: $0.offset + 1, text: $0.element)
        })
        self._tagsText = State(initialValue: character.tags.joined(separator: ", "))
        self._initialVariablesJSON = State(initialValue: Self.jsonString(character.initialVariables))
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基本信息", comment: "Character basic information")) {
                TextField(NSLocalizedString("名称", comment: "Character name"), text: $character.name)
                TextField(NSLocalizedString("作者", comment: "Character creator"), text: $character.creator)
                TextField(NSLocalizedString("版本", comment: "Character version"), text: $character.characterVersion)
                TextField(NSLocalizedString("标签（逗号分隔）", comment: "Character tags separated by commas"), text: $tagsText, axis: .vertical)
            }

            multilineSection(
                NSLocalizedString("角色描述", comment: "Character description"),
                text: $character.description,
                minimumHeight: 180
            )
            multilineSection(
                NSLocalizedString("性格摘要", comment: "Character personality summary"),
                text: $character.personality
            )
            multilineSection(
                NSLocalizedString("场景", comment: "Character scenario"),
                text: $character.scenario
            )
            multilineSection(
                NSLocalizedString("首条消息", comment: "Character first message"),
                text: $character.firstMessage,
                minimumHeight: 180
            )

            Section(NSLocalizedString("候选开场白", comment: "Alternate greetings")) {
                if greetingDrafts.isEmpty {
                    Text(NSLocalizedString("暂无候选开场白。", comment: "No alternate greetings"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($greetingDrafts) { $draft in
                        VStack(alignment: .leading) {
                            Text(String(
                                format: NSLocalizedString("开场白 %d", comment: "Greeting number"),
                                draft.number
                            ))
                            .etFont(.subheadline)
                            TextEditor(text: $draft.text)
                                .frame(minHeight: 140)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                greetingDrafts.removeAll { $0.id == draft.id }
                                renumberGreetingDrafts()
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    greetingDrafts.append(RoleplayGreetingDraft(number: greetingDrafts.count + 1))
                } label: {
                    Label(NSLocalizedString("新增开场白", comment: "Add alternate greeting"), systemImage: "plus")
                }
            }

            multilineSection(
                NSLocalizedString("示例对话", comment: "Character example messages"),
                text: $character.messageExamples,
                minimumHeight: 180
            )
            multilineSection(
                NSLocalizedString("系统提示词", comment: "Character system prompt"),
                text: $character.systemPrompt
            )
            multilineSection(
                NSLocalizedString("历史后指令", comment: "Character post-history instructions"),
                text: $character.postHistoryInstructions
            )
            multilineSection(
                NSLocalizedString("创作者备注", comment: "Character creator notes"),
                text: $character.creatorNotes
            )

            Section {
                TextEditor(text: $initialVariablesJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
            } header: {
                Text(NSLocalizedString("初始变量", comment: "Character initial variables"))
            } footer: {
                Text(NSLocalizedString("初始变量必须填写为 JSON 对象，并会在绑定角色卡时注入角色变量作用域。", comment: "Character initial variables explanation"))
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
        .navigationTitle(
            isCreating
                ? NSLocalizedString("新增角色卡", comment: "Add character card title")
                : NSLocalizedString("角色卡资料", comment: "Character card profile title")
        )
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            NSLocalizedString("无法保存角色卡", comment: "Unable to save character card"),
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button(NSLocalizedString("好的", comment: "OK")) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func multilineSection(
        _ title: String,
        text: Binding<String>,
        minimumHeight: CGFloat = 120
    ) -> some View {
        Section(title) {
            TextEditor(text: text)
                .frame(minHeight: minimumHeight)
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
                        throw RoleplayCharacterProfileEditorError.invalidInitialVariables
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

private struct RoleplayGreetingDraft: Identifiable {
    let id: UUID
    var number: Int
    var text: String

    init(id: UUID = UUID(), number: Int, text: String = "") {
        self.id = id
        self.number = number
        self.text = text
    }
}

private enum RoleplayCharacterProfileEditorError: LocalizedError {
    case invalidInitialVariables

    var errorDescription: String? {
        NSLocalizedString("初始变量必须是有效的 JSON 对象。", comment: "Invalid character initial variables")
    }
}
