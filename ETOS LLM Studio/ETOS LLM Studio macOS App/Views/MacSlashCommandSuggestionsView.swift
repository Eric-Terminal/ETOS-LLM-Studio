import ETOSCore
import SwiftUI

@MainActor
struct MacSlashCommandSuggestionsView: View {
    @ObservedObject var model: MacSlashCommandComposerModel
    let choose: (ChatSlashCommandSuggestion, String, UUID?) -> Void

    var body: some View {
        if let input = model.input, !input.rows.isEmpty {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { model.selectedSuggestion()?.id }, set: model.selectID)) {
                    ForEach(input.rows) { row in
                        Button { choose(row.suggestion, input.text, input.sessionID) } label: { MacSlashCommandLabel(row: row) }
                            .buttonStyle(.plain).tag(row.id).id(row.id)
                    }
                }
                .listStyle(.plain).frame(maxHeight: 180)
                .onChange(of: model.selectedIndex) { _, _ in
                    if let id = model.selectedSuggestion()?.id { proxy.scrollTo(id) }
                }
            }
            Text(NSLocalizedString("↑↓ 选择，Tab 补全，⌘Return 执行。", comment: ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct MacSlashCommandModelPicker: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker(NSLocalizedString("全局模型", comment: ""), selection: Binding(get: { workspace.selectedModelID }, set: { workspace.selectModel($0) })) {
                    Text(NSLocalizedString("选择模型", comment: "")).tag(String?.none)
                    ForEach(workspace.sessionModelCatalog.rows) { row in Text(row.title).tag(Optional(row.id)) }
                }
                Text(NSLocalizedString("会话首选模型优先于全局选择；可在会话设置中修改。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped).disabled(!workspace.canManageLocalModels)
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .toolbar { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
            .guideSettingsPageContext(id: "mac-slash-model-picker", title: NSLocalizedString("选择模型", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace"), GuideDocumentReference(id: "slash-commands", title: "Quick Commands")],
                isActive: workspace.canManageLocalModels,
                settings: [
                    .readOnly("model_count", label: NSLocalizedString("模型", comment: ""), value: { .int(workspace.models.count) }),
                    .string("global_model_id", label: NSLocalizedString("全局模型", comment: ""),
                        allowedValues: workspace.sessionModelCatalog.guideIDs, allowsEmpty: false, get: { workspace.selectedModelID ?? "" },
                        set: { workspace.selectModel($0) }),
                    .readOnly("effective_model", label: NSLocalizedString("当前模型", comment: ""), value: { .string(workspace.effectiveModelName ?? "") }),
                    .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("immediate") })
                ])
        }
        .modifier(MacGuideInspector()).frame(minWidth: 480, minHeight: 280)
    }
}
