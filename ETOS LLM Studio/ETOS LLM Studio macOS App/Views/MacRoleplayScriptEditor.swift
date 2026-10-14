import ETOSCore
import SwiftUI

struct MacRoleplayScriptEditor: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: MacRoleplayScriptDraft
    @State private var saving = false
    @State private var error: String?
    @State private var contentRevision = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基本信息", comment: "")) {
                    TextField(NSLocalizedString("脚本名称", comment: ""), text: $draft.script.name)
                    TextField(NSLocalizedString("脚本说明", comment: ""), text: $draft.script.info, axis: .vertical).lineLimit(3...8)
                    Toggle(NSLocalizedString("启用脚本", comment: ""), isOn: $draft.script.enabled)
                }
                Section(NSLocalizedString("脚本内容", comment: "")) {
                    TextEditor(text: contentBinding).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280).accessibilityLabel(NSLocalizedString("脚本内容", comment: ""))
                }
                Section {
                    MacSettingsIntroCard(id: "roleplay-script-editor", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色正则与脚本使用说明", comment: ""), documentID: "roleplay")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(saving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑助手脚本", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(saving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-roleplay-script-editor-\(draft.originalCharacter.id)-\(draft.id)-\(contentRevision)"),
                title: NSLocalizedString("编辑助手脚本", comment: ""), documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
                settings: [
                    .readOnly("character_id", label: NSLocalizedString("角色卡", comment: ""), value: { .string(draft.originalCharacter.id.uuidString) }),
                    .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(saving || workspace.isRestoringData) })
                ] + (saving || workspace.isRestoringData ? [] : [
                    .string("name", label: NSLocalizedString("脚本名称", comment: ""), get: { draft.script.name }, set: { draft.script.name = $0 }),
                    .string("info", label: NSLocalizedString("脚本说明", comment: ""), get: { draft.script.info }, set: { draft.script.info = $0 }),
                    .bool("enabled", label: NSLocalizedString("启用脚本", comment: ""), get: { draft.script.enabled }, set: { draft.script.enabled = $0 }),
                    .writeOnlyString("content", label: NSLocalizedString("脚本内容", comment: ""), isConfigured: { !draft.script.content.isEmpty }, set: { contentBinding.wrappedValue = $0 })
                ])
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(saving)
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
        .frame(minWidth: 560, minHeight: 560)
    }

    private var contentBinding: Binding<String> {
        Binding(get: { draft.script.content }, set: {
            draft.script.content = $0
            // 只写字段的快照无法比较原文，正文一变就废弃旧提案的来源上下文。
            contentRevision = UUID()
        })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await model.save(draft); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}
