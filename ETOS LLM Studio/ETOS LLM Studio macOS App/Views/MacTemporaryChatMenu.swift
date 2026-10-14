import ETOSCore
import SwiftUI

@MainActor
struct MacTemporaryChatMenu: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Binding var showingIntroduction: Bool

    var body: some View {
        Menu {
            Button {
                workspace.setTemporaryChat(memoryMode: .enabled)
            } label: {
                Label(NSLocalizedString("允许使用记忆", comment: ""), systemImage: workspace.temporaryChatMemoryMode == .enabled ? "checkmark" : "brain")
            }
            .disabled(!canChangeMode)
            Button {
                workspace.setTemporaryChat(memoryMode: .isolated)
            } label: {
                Label(NSLocalizedString("隔离记忆上下文", comment: ""), systemImage: workspace.temporaryChatMemoryMode == .isolated ? "checkmark" : "brain")
            }
            .disabled(!canChangeMode)
            if workspace.temporaryChatMemoryMode != nil {
                Divider()
                Button(NSLocalizedString("保存为会话", comment: "")) { workspace.saveTemporaryChat() }
                    .disabled(!workspace.canModifyCurrentHistory)
            }
            Divider()
            Button(NSLocalizedString("使用说明", comment: "")) { showingIntroduction = true }
        } label: {
            Label(NSLocalizedString("临时对话", comment: ""), systemImage: ChatQuickAction.temporaryChat.systemImage(
                isTemporaryChatEnabled: workspace.temporaryChatMemoryMode != nil,
                memoryMode: workspace.temporaryChatMemoryMode ?? .enabled))
        }
        .disabled(!workspace.canManageLocalModels)
    }

    private var canChangeMode: Bool {
        workspace.canModifyCurrentHistory && (workspace.temporaryChatMemoryMode != nil || workspace.messages.isEmpty)
    }
}

/// 由工具栏提供锚点，不能把弹窗挂在原生菜单临时生成的条目上。
@MainActor
struct MacTemporaryChatIntroductionView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(NSLocalizedString("临时对话在保存前不写入聊天数据库，重新启动后不会恢复。允许使用记忆时，记忆读写仍遵循当前设置；隔离记忆会关闭该会话的记忆读取、写入和主动检索。系统只保留一个临时对话，新建时会复用它。需要保留消息时，请选择“保存为会话”。", comment: ""))
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("临时对话", comment: ""))
            .guideSettingsPageContext(
                id: "mac-temporary-chat-introduction", title: NSLocalizedString("临时对话", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: isActive && workspace.canManageLocalModels,
                settings: [.readOnly("memory_mode", label: NSLocalizedString("状态", comment: ""), value: {
                    .string(workspace.temporaryChatMemoryMode.map { $0.isMemoryEnabled ? "enabled" : "isolated" } ?? "disabled")
                })]
            )
        }
        .modifier(MacGuideInspector())
        .frame(width: 420, height: 340)
    }
}
