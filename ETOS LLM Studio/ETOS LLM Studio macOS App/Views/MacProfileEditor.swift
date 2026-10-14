import ETOSCore
import SwiftUI

struct MacProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacConversationMemoryModel
    let original: ConversationUserProfile?
    @State private var content: String
    @State private var isSaving = false
    @State private var error: String?

    init(model: MacConversationMemoryModel, original: ConversationUserProfile?) {
        self.model = model
        self.original = original
        _content = State(initialValue: original?.content ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $content).frame(minHeight: 260)
                } header: { Text(NSLocalizedString("用户画像内容", comment: "")) }
                footer: { Text(NSLocalizedString("修改后需要保存", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑用户画像", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(content.isEmpty || isSaving || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: "mac-profile-editor", title: NSLocalizedString("编辑用户画像", comment: ""),
                documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
                settings: isSaving || workspace.isRestoringData ? [.readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })] : [
                    .string("content", label: NSLocalizedString("用户画像内容", comment: ""), allowsEmpty: false, get: { content }, set: { content = $0 }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 540, minHeight: 420)
    }

    private func save() {
        guard !isSaving, !workspace.isRestoringData else { return }
        isSaving = true
        error = nil
        let content = content
        Task {
            defer { isSaving = false }
            do {
                guard !workspace.isRestoringData else { throw MacMemoryWriteError.busy }
                try await model.saveProfile(content: content, original: original)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
