import ETOSCore
import SwiftUI

struct MacSessionTagEditor: View {
    @ObservedObject var model: MacSessionLibraryModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let original: SessionTag?
    @State private var name: String
    @State private var color: SessionTagColor?
    @State private var error: String?
    @State private var isSaving = false
    private static let colorValues = [""] + SessionTagColor.allCases.map(\.rawValue)

    init(model: MacSessionLibraryModel, original: SessionTag?) {
        self.model = model
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _color = State(initialValue: original?.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("标签名称", comment: ""), text: $name)
                    Picker(NSLocalizedString("颜色", comment: ""), selection: $color) {
                        Text(NSLocalizedString("无颜色", comment: "")).tag(SessionTagColor?.none)
                        ForEach(SessionTagColor.allCases) { color in
                            Label(color.localizedName, systemImage: "circle.fill").foregroundStyle(color.macColor).tag(Optional(color))
                        }
                    }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑标签", comment: ""))
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
                id: GuidePageID(rawValue: "mac-session-tag-\(original?.id.uuidString ?? "new")"),
                title: NSLocalizedString("编辑标签", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: isSaving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : [
                    .string("name", label: NSLocalizedString("标签名称", comment: ""), allowsEmpty: false, get: { name }, set: { name = $0 }),
                    .string("color", label: NSLocalizedString("颜色", comment: ""), allowedValues: Self.colorValues,
                            get: { color?.rawValue ?? "" }, set: { color = SessionTagColor(rawValue: $0) }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 420, minHeight: 260)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.saveTag(original: original, name: name, color: color); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
