import ETOSCore
import SwiftUI

struct MacSessionFolderEditor: View {
    @ObservedObject var model: MacSessionLibraryModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let original: SessionFolder?
    @State private var name: String
    @State private var parentID: UUID?
    @State private var error: String?
    @State private var isSaving = false

    init(model: MacSessionLibraryModel, original: SessionFolder?, parentID: UUID?) {
        self.model = model
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _parentID = State(initialValue: parentID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("文件夹名称", comment: ""), text: $name)
                    Picker(NSLocalizedString("位置", comment: ""), selection: $parentID) {
                        Text(NSLocalizedString("根目录", comment: "")).tag(UUID?.none)
                        ForEach(model.snapshot.folders) { row in
                            Text(row.path).tag(Optional(row.id))
                                .disabled(original.map { row.ancestorIDs.contains($0.id) } ?? false)
                        }
                    }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    MacSettingsIntroCard(
                        id: "session-folders", title: NSLocalizedString("会话管理", comment: ""),
                        details: NSLocalizedString("侧栏按文件夹、标签或颜色筛选会话；文件夹显示完整路径，只列出直接归属的会话。右键会话可移动位置或切换多个标签。删除文件夹会同时删除子文件夹，其中的会话移回未分类；删除标签保留会话内容。名称和位置先保存为草稿，点击保存后生效。", comment: ""),
                        documentID: "macos-workspace"
                    )
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("文件夹", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(name.isEmpty || isSaving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-session-folder-\(original?.id.uuidString ?? "new")"),
                title: NSLocalizedString("文件夹", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: isSaving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : [
                    .string("name", label: NSLocalizedString("文件夹名称", comment: ""), allowsEmpty: false, get: { name }, set: { name = $0 }),
                    .string("parent_id", label: NSLocalizedString("位置", comment: ""), allowedValues: model.snapshot.folderGuideIDs,
                            get: { parentID?.uuidString ?? "" }, set: { parentID = UUID(uuidString: $0) }),
                    .readOnly("available_folders", label: NSLocalizedString("文件夹", comment: ""), value: { model.snapshot.folderGuideValues }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 460, minHeight: 340)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.saveFolder(original: original, name: name, parentID: parentID); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
