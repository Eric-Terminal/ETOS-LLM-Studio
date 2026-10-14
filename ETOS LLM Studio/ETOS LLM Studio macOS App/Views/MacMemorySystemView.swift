import ETOSCore
import SwiftUI

@MainActor
struct MacMemorySystemView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "memory-system", title: NSLocalizedString("记忆系统", comment: ""),
                    details: NSLocalizedString("记忆系统说明正文", comment: ""), documentID: "settings-memory", isActive: available)
                Toggle(NSLocalizedString("启用记忆功能", comment: ""), isOn: $configuration.enableMemory)
            }
            Section {
                Toggle(NSLocalizedString("允许写入新的记忆", comment: ""), isOn: $configuration.enableMemoryWrite)
            } footer: {
                Text(NSLocalizedString("关闭后仅读取记忆，不会请求保存新内容。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(NSLocalizedString("启用异步跨对话记忆", comment: ""), isOn: $configuration.enableConversationMemoryAsync)
                NavigationLink(NSLocalizedString("跨对话记忆与画像", comment: "")) {
                    MacConversationMemoryView(model: workspace.conversationMemoryModel)
                }
                NavigationLink(NSLocalizedString("记忆库管理", comment: "")) { MacMemorySettingsView(model: workspace.memoryModel) }
            }
        }
        .formStyle(.grouped).disabled(!available)
        .navigationTitle(NSLocalizedString("记忆系统", comment: ""))
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: "mac-memory-system", title: NSLocalizedString("记忆系统", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            isActive: available && visible,
            settings: [
                .bool("memory_enabled", label: NSLocalizedString("启用记忆功能", comment: ""), get: { configuration.enableMemory }, set: { configuration.enableMemory = $0 }),
                .bool("memory_write_enabled", label: NSLocalizedString("允许写入新的记忆", comment: ""), get: { configuration.enableMemoryWrite }, set: { configuration.enableMemoryWrite = $0 }),
                .bool("cross_conversation_memory_enabled", label: NSLocalizedString("启用异步跨对话记忆", comment: ""), get: { configuration.enableConversationMemoryAsync }, set: { configuration.enableConversationMemoryAsync = $0 }),
                .readOnly("requires_navigation", label: NSLocalizedString("记忆库管理", comment: ""), value: { .bool(true) })
            ])
    }
}
