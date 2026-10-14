import ETOSCore
import SwiftUI

@MainActor
struct MacChatQuickActionSettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @StateObject private var model = MacChatQuickActionsModel()
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "chat-quick-actions", title: NSLocalizedString("聊天快捷功能", comment: ""),
                    details: NSLocalizedString("Mac 聊天快捷功能说明正文", comment: ""), documentID: "chat-quick-actions", isActive: available)
            }
            Section {
                if let state = model.presentation {
                    ForEach(state.rows) { row in
                        Toggle(isOn: Binding(get: { state.selected.contains(row.action) }, set: { model.setSelected(row.action, enabled: $0) })) {
                            Label(row.title, systemImage: row.systemImage)
                        }.disabled(state.selected.count == 1 && state.selected.contains(row.action))
                    }
                } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            } footer: {
                Text(NSLocalizedString("选择一个功能时直接打开；选择多个功能时展开菜单。至少保留一个功能，修改立即保存。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).disabled(!available || !model.canEdit)
        .navigationTitle(NSLocalizedString("聊天快捷功能", comment: ""))
        .onAppear { visible = true; model.setActive(available) }
        .onDisappear { visible = false; model.setActive(false) }
        .onChange(of: available) { _, value in model.setActive(visible && value) }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-chat-quick-actions-\(model.revision)"),
            title: NSLocalizedString("聊天快捷功能", comment: ""),
            documents: [GuideDocumentReference(id: "chat-quick-actions", title: "Chat Quick Actions")],
            isActive: available && visible && model.canEdit,
            settings: [
                .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("immediate") }),
                .json("actions", label: NSLocalizedString("已选择的快捷功能", comment: ""),
                    schema: model.presentation?.guideSchema ?? .dictionary([:]), get: { model.guideValue },
                    normalize: { .array(try MacChatQuickActionPresentation.guideActions($0).map { .string($0.rawValue) }) },
                    set: { try model.applyGuideSelection($0) })
            ])
    }
}
