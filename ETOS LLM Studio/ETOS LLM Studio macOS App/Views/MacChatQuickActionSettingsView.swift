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
                    details: NSLocalizedString("chat.quickActions.macIntroduction", value: "Choose Prefer Toolbar, More Menu, or Hidden for each action, including Choose Model. Use the arrows to reorder enabled actions. Narrow windows collect actions in a menu. Changes save immediately and sync with iPhone. On iPhone Duo, the system adapts toolbar orientation and moves items into More when space is limited. The guide can propose configuration changes but cannot launch actions.", comment: "Mac 聊天快捷功能介绍"), documentID: "chat-quick-actions", isActive: available)
            }
            Section {
                if let state = model.presentation {
                    ForEach(state.rows) { row in
                        HStack {
                            Picker(selection: Binding(
                                get: { state.selected.contains(row.action) ? (state.toolbar.contains(row.action) ? .toolbar : .menu) : .hidden },
                                set: { (placement: ChatQuickActionPlacement) in model.setPlacement(row.action, placement: placement) }
                            )) {
                                ForEach(ChatQuickActionPlacement.allCases) { placement in
                                    Text(placement.title).tag(placement)
                                        .disabled(placement == .hidden && state.selected.count == 1 && state.selected.contains(row.action))
                                }
                            } label: { Label(row.title, systemImage: row.systemImage) }
                            if state.selected.contains(row.action) {
                                Button { model.move(row.action, by: -1) } label: {
                                    Label(NSLocalizedString("chat.quickActions.moveUp", value: "Move Up", comment: ""), systemImage: "arrow.up")
                                }.disabled(state.selectedRows.first?.action == row.action)
                                Button { model.move(row.action, by: 1) } label: {
                                    Label(NSLocalizedString("chat.quickActions.moveDown", value: "Move Down", comment: ""), systemImage: "arrow.down")
                                }.disabled(state.selectedRows.last?.action == row.action)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            } footer: {
                Text(NSLocalizedString("chat.quickActions.macOrderFooter", value: "Use the arrows to reorder. Keep at least one action enabled. Changes save immediately.", comment: ""))
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
                    set: { try model.applyGuideSelection($0) }),
                .json("toolbar_actions", label: NSLocalizedString("chat.quickActions.placement.toolbar", value: "Prefer Toolbar", comment: ""),
                    schema: GuideChatQuickActionSettingsSupport.toolbarSchema, get: { model.toolbarGuideValue },
                    normalize: { .array(try GuideChatQuickActionSettingsSupport.actions(from: $0, allowsEmpty: true).map { .string($0.rawValue) }) },
                    set: { try model.applyGuideToolbarSelection($0) })
            ])
    }
}
