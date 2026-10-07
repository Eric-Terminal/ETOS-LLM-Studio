import ETOSCore
import SwiftUI

struct MacRoleplayCharacterEditor: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: MacRoleplayCharacterDraft
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基本信息", comment: "")) {
                    TextField(NSLocalizedString("名称", comment: ""), text: $draft.character.name)
                    TextField(NSLocalizedString("作者", comment: ""), text: $draft.character.creator)
                    TextField(NSLocalizedString("版本", comment: ""), text: $draft.character.characterVersion)
                    TextField(NSLocalizedString("标签（逗号分隔）", comment: ""), text: $draft.tags, axis: .vertical)
                }
                textSection(NSLocalizedString("角色描述", comment: ""), text: $draft.character.description)
                textSection(NSLocalizedString("性格摘要", comment: ""), text: $draft.character.personality)
                textSection(NSLocalizedString("场景", comment: ""), text: $draft.character.scenario)
                textSection(NSLocalizedString("首条消息", comment: ""), text: $draft.character.firstMessage)
                Section(NSLocalizedString("候选开场白", comment: "")) {
                    ForEach($draft.greetings) { $greeting in
                        NavigationLink(String(format: NSLocalizedString("开场白 %d", comment: ""), greeting.number)) {
                            MacRoleplayGreetingEditor(characterID: draft.id, greeting: $greeting, isSaving: saving)
                        }
                    }
                    .onDelete { indices in
                        draft.greetings.remove(atOffsets: indices)
                        for index in draft.greetings.indices { draft.greetings[index].number = index + 1 }
                    }
                    .onMove { indices, destination in
                        draft.greetings.move(fromOffsets: indices, toOffset: destination)
                        for index in draft.greetings.indices { draft.greetings[index].number = index + 1 }
                    }
                    Button(NSLocalizedString("新增开场白", comment: "")) { draft.greetings.append(MacRoleplayGreetingDraft(number: draft.greetings.count + 1)) }
                }
                textSection(NSLocalizedString("示例对话", comment: ""), text: $draft.character.messageExamples)
                textSection(NSLocalizedString("系统提示词", comment: ""), text: $draft.character.systemPrompt)
                textSection(NSLocalizedString("历史后指令", comment: ""), text: $draft.character.postHistoryInstructions)
                textSection(NSLocalizedString("创作者备注", comment: ""), text: $draft.character.creatorNotes)
                Section {
                    NavigationLink(NSLocalizedString("初始变量", comment: "")) {
                        MacRoleplayInitialVariablesEditor(characterID: draft.id, text: $draft.variablesJSON, isSaving: saving)
                    }
                    MacSettingsIntroCard(id: "roleplay-character-editor", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色资料使用说明", comment: ""), documentID: "roleplay")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(saving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("角色卡资料", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(saving || draft.character.name.isEmpty || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-roleplay-character-editor-\(draft.id)"), title: NSLocalizedString("角色卡资料", comment: ""),
                documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: saving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : [
                    .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
                    .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { draft.character.name }, set: { draft.character.name = $0 }),
                    .string("creator", label: NSLocalizedString("作者", comment: ""), get: { draft.character.creator }, set: { draft.character.creator = $0 }),
                    .string("version", label: NSLocalizedString("版本", comment: ""), get: { draft.character.characterVersion }, set: { draft.character.characterVersion = $0 }),
                    .string("tags", label: NSLocalizedString("标签（逗号分隔）", comment: ""), get: { draft.tags }, set: { draft.tags = $0 }),
                    .string("description", label: NSLocalizedString("角色描述", comment: ""), get: { draft.character.description }, set: { draft.character.description = $0 }),
                    .string("personality", label: NSLocalizedString("性格摘要", comment: ""), get: { draft.character.personality }, set: { draft.character.personality = $0 }),
                    .string("scenario", label: NSLocalizedString("场景", comment: ""), get: { draft.character.scenario }, set: { draft.character.scenario = $0 }),
                    .string("first_message", label: NSLocalizedString("首条消息", comment: ""), get: { draft.character.firstMessage }, set: { draft.character.firstMessage = $0 }),
                    .string("examples", label: NSLocalizedString("示例对话", comment: ""), get: { draft.character.messageExamples }, set: { draft.character.messageExamples = $0 }),
                    .string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { draft.character.systemPrompt }, set: { draft.character.systemPrompt = $0 }),
                    .string("post_history", label: NSLocalizedString("历史后指令", comment: ""), get: { draft.character.postHistoryInstructions }, set: { draft.character.postHistoryInstructions = $0 }),
                    .string("creator_notes", label: NSLocalizedString("创作者备注", comment: ""), get: { draft.character.creatorNotes }, set: { draft.character.creatorNotes = $0 }),
                    .readOnly("greetings", label: NSLocalizedString("候选开场白", comment: ""), value: { .int(draft.greetings.count) }),
                    .readOnly("variables_require_navigation", label: NSLocalizedString("初始变量", comment: ""), value: { .bool(true) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(saving)
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
        .frame(minWidth: 580, minHeight: 620)
    }

    private func textSection(_ title: String, text: Binding<String>) -> some View {
        Section(title) { TextEditor(text: text).frame(minHeight: 100).accessibilityLabel(title) }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { try await model.save(draft); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacRoleplayGreetingEditor: View {
    let characterID: UUID
    @Binding var greeting: MacRoleplayGreetingDraft
    let isSaving: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        Form {
            Section { TextEditor(text: $greeting.text).frame(minHeight: 280).accessibilityLabel(NSLocalizedString("开场白", comment: "")) }
            footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .disabled(isSaving || workspace.isRestoringData)
        .navigationTitle(String(format: NSLocalizedString("开场白 %d", comment: ""), greeting.number))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-roleplay-greeting-\(characterID)-\(greeting.id)"), title: NSLocalizedString("开场白", comment: ""),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: [
                .readOnly("requires_parent_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) })
            ] + (isSaving || workspace.isRestoringData ? [] : [
                .string("content", label: NSLocalizedString("内容", comment: ""), get: { greeting.text }, set: { greeting.text = $0 })
            ])
        )
    }
}
