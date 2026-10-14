import ETOSCore
import SwiftUI

struct MacAgentPromptEditorTarget: Identifiable {
    let id = UUID()
    let original: LocalAgentPromptProfile?
}

struct MacAgentPromptEditor: View {
    let target: MacAgentPromptEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacAgentPromptModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalAgentPromptProfile
    @State private var epoch: UUID
    @State private var visible = false
    @State private var resetting = false
    @State private var error: String?
    private var active: Bool { visible && isActive && epoch == model.epoch && model.canWrite }

    init(target: MacAgentPromptEditorTarget, isActive: Bool, model: MacAgentPromptModel) {
        self.target = target; self.isActive = isActive; self.model = model
        _draft = State(initialValue: target.original ?? LocalAgentPromptProfile(title: "", content: ""))
        _epoch = State(initialValue: model.epoch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "agent-prompt-editor-\(target.id)", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac Agent 提示词使用说明", comment: ""), documentID: "local-linux",
                        isActive: isActive && epoch == model.epoch && !model.isSuspended && !resetting)
                    TextField(NSLocalizedString("提示词名称", comment: ""), text: $draft.title)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.isEnabled)
                }
                Section {
                    TextEditor(text: $draft.content).frame(minHeight: 300)
                } header: { Text(NSLocalizedString("提示词内容", comment: "")) }
                footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if draft.isBuiltIn {
                    Section {
                        Button(NSLocalizedString("恢复默认提示词", comment: "")) { resetting = true }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(!active)
            .navigationTitle(NSLocalizedString("编辑提示词", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!active || resetting)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-agent-prompt-editor-\(target.id)-\(epoch)"), title: NSLocalizedString("编辑提示词", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: active && !resetting,
                settings: [
                    .string("title", label: NSLocalizedString("提示词名称", comment: ""), get: { draft.title }, set: { draft.title = $0 }),
                    .string("content", label: NSLocalizedString("提示词内容", comment: ""), get: { draft.content }, set: { draft.content = $0 }),
                    .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.isEnabled }, set: { draft.isEnabled = $0 }),
                    .readOnly("built_in", label: NSLocalizedString("内置", comment: ""), value: { .bool(draft.isBuiltIn) }),
                    .readOnly("requires_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) })
                ]
            )
            .confirmationDialog(NSLocalizedString("恢复默认提示词", comment: ""), isPresented: $resetting, titleVisibility: .visible) {
                Button(NSLocalizedString("恢复默认", comment: ""), role: .destructive) {
                    guard active else { return }
                    draft.title = LocalAgentPromptStore.defaultTitle
                    draft.content = LocalAgentPromptStore.defaultContent
                    draft.isEnabled = true
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            } message: { Text(NSLocalizedString("替换当前草稿，保存后生效。", comment: "")) }
        }
        .frame(minWidth: 580, minHeight: 480)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: model.epoch) { _, _ in dismiss() }
        .onChange(of: isActive) { _, value in if !value { dismiss() } }
    }

    private func save() {
        guard active else { return }
        let draft = draft
        Task {
            guard active else { return }
            do {
                try await model.save(draft, original: target.original, expectedEpoch: epoch)
                if visible && isActive && epoch == model.epoch { dismiss() }
            } catch { if epoch == model.epoch { self.error = error.localizedDescription } }
        }
    }
}
