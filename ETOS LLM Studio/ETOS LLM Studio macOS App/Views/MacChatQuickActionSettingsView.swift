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
                    details: NSLocalizedString("chat.quickActions.macIntroduction", value: "Customize which shortcuts appear in the chat window toolbar (including the model picker): set each item to Prefer Toolbar, More Menu, or Hidden, and use the arrows to arrange their order. Narrow windows automatically tuck overflow items into a menu.\n\nChanges save immediately and sync with iPhone.", comment: "Mac 聊天快捷功能介绍"), documentID: "chat-quick-actions", isActive: available)
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
                Text(NSLocalizedString("chat.quickActions.macOrderFooter", value: "Use the up and down arrows to reorder items, keeping at least one action visible. Changes save immediately.", comment: ""))
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
