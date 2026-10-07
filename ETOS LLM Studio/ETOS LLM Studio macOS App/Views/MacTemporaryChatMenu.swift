import ETOSCore
import SwiftUI

struct MacTemporaryChatMenu: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var showingIntroduction = false

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
            Label(NSLocalizedString("临时对话", comment: ""), systemImage: workspace.temporaryChatMemoryMode == nil ? "clock" : "clock.fill")
        }
        .popover(isPresented: $showingIntroduction) {
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
                    settings: [.readOnly("memory_mode", label: NSLocalizedString("状态", comment: ""), value: {
                        .string(workspace.temporaryChatMemoryMode.map { $0.isMemoryEnabled ? "enabled" : "isolated" } ?? "disabled")
                    })]
                )
            }
            .modifier(MacGuideInspector())
            .frame(width: 420, height: 340)
        }
    }

    private var canChangeMode: Bool {
        workspace.canModifyCurrentHistory && (workspace.temporaryChatMemoryMode != nil || workspace.messages.isEmpty)
    }
}
