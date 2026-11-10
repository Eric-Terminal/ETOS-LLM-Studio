import Combine
import ETOSCore
import SwiftUI

/// 桌面提示词入口复用同一列表与选择状态，使头像始终跟随提示词 ID。
struct MacGlobalSystemPromptsView: View {
    let isActive: Bool
    @State private var snapshot = GlobalSystemPromptSnapshot(entries: [], selectedEntryID: nil, activeSystemPrompt: "")
    @State private var avatarEntry: GlobalSystemPromptEntry?
    @State private var editingEntry: GlobalSystemPromptEntry?
    @State private var editingNewPrompt = false
    @State private var isWorking = false
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        List {
            ForEach(snapshot.entries) { entry in
                Section {
                    Button {
                        isWorking = true
                        Task {
                            snapshot = await Task.detached {
                                let current = GlobalSystemPromptStore.load()
                                return GlobalSystemPromptStore.save(entries: current.entries, selectedEntryID: entry.id)
                            }.value
                            isWorking = false
                        }
                    } label: {
                        HStack {
                            Text(entry.title.isEmpty ? NSLocalizedString("未命名提示词", value: "Untitled Prompt", comment: "") : entry.title)
                            Spacer()
                            if entry.id == snapshot.selectedEntryID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(NSLocalizedString("编辑", comment: "")) { editingNewPrompt = false; editingEntry = entry }
                        Button(NSLocalizedString("avatar.set", value: "Set Avatar", comment: "")) { avatarEntry = entry }
                    }
                    NavigationLink(NSLocalizedString("avatar.set", value: "Set Avatar", comment: "")) {
                        ChatAvatarEditorView(target: .prompt(entry.id), isActive: isActive)
                    }
                }
            }
            Button(NSLocalizedString("新增提示词", value: "Add Prompt", comment: "")) {
                editingNewPrompt = true
                editingEntry = GlobalSystemPromptEntry(title: "", content: "")
            }
        }
        .navigationTitle(NSLocalizedString("全局提示词", value: "Global Prompts", comment: ""))
        .disabled(isWorking || workspace.isRestoringData)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .globalSystemPromptStoreDidChange).receive(on: DispatchQueue.main)) { _ in
            Task { await reload() }
        }
        .sheet(item: $avatarEntry) { entry in
            NavigationStack {
                ChatAvatarEditorView(target: .prompt(entry.id), isActive: isActive)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("完成", value: "Done", comment: "")) { avatarEntry = nil }
                        }
                    }
            }
            .modifier(MacGuideInspector())
            .frame(minWidth: 420, minHeight: 320)
        }
        .sheet(item: $editingEntry) { entry in
            MacGlobalSystemPromptEditor(entry: entry, isNew: editingNewPrompt)
        }
        .onChange(of: workspace.isRestoringData) { _, restoring in
            if restoring { avatarEntry = nil; editingEntry = nil }
        }
        .guideSettingsPageContext(id: "mac-global-system-prompts",
            title: NSLocalizedString("全局提示词", value: "Global Prompts", comment: ""),
            documents: [GuideDocumentReference(id: "chat-avatars", title: "Chat Avatars"), GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            isActive: isActive, settings: [
                .readOnly("count", label: NSLocalizedString("全局提示词", value: "Global Prompts", comment: ""), value: { .int(snapshot.entries.count) }),
                .readOnly("selected_id", label: NSLocalizedString("当前提示词", value: "Current Prompt", comment: ""), value: { .string(snapshot.selectedEntryID?.uuidString ?? "") })
            ])
    }

    private func reload() async {
        snapshot = await Task.detached { GlobalSystemPromptStore.load() }.value
    }
}

private struct MacGlobalSystemPromptEditor: View {
    let entry: GlobalSystemPromptEntry
    let isNew: Bool
    @State private var title: String
    @State private var content: String
    @State private var saving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(entry: GlobalSystemPromptEntry, isNew: Bool) {
        self.entry = entry
        self.isNew = isNew
        _title = State(initialValue: entry.title)
        _content = State(initialValue: entry.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("提示词名称", value: "Prompt Name", comment: ""), text: $title)
                TextEditor(text: $content)
                    .accessibilityLabel(NSLocalizedString("提示词内容", value: "Prompt Content", comment: ""))
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(NSLocalizedString("编辑提示词", value: "Edit Prompt", comment: ""))
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(saving)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-global-prompt-editor-\(entry.id)"),
                title: NSLocalizedString("编辑提示词", value: "Edit Prompt", comment: ""),
                documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")], settings: [
                    .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) })
                ] + (saving ? [] : [
                    .string("title", label: NSLocalizedString("提示词名称", value: "Prompt Name", comment: ""), get: { title }, set: { title = $0 }),
                    .string("content", label: NSLocalizedString("提示词内容", value: "Prompt Content", comment: ""), get: { content }, set: { content = $0 })
                ]))
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(saving)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func save() {
        var updated = entry
        updated.title = title
        updated.content = content
        updated.updatedAt = Date()
        let draft = updated
        let original = isNew ? nil : entry
        saving = true
        Task {
            defer { saving = false }
            do {
                try await Task.detached {
                    let current = GlobalSystemPromptStore.load()
                    guard current.entries.first(where: { $0.id == draft.id }) == original else {
                        throw RoleplayDraftWriteError.changedExternally
                    }
                    var entries = current.entries
                    if let index = entries.firstIndex(where: { $0.id == draft.id }) { entries[index] = draft }
                    else { entries.append(draft) }
                    GlobalSystemPromptStore.save(entries: entries, selectedEntryID: current.selectedEntryID ?? draft.id)
                }.value
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
