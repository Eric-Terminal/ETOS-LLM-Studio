import ETOSCore
import SwiftUI

@MainActor
struct MacContextCompressionSettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "compression-settings", title: NSLocalizedString("上下文压缩", comment: ""),
                    details: NSLocalizedString("Mac 续聊压缩说明正文", comment: ""), documentID: "context-compression", isActive: available)
            }
            Section {
                Toggle(NSLocalizedString("上下文压缩提醒", comment: ""), isOn: $configuration.enableContextCompressionReminder)
                TextField(NSLocalizedString("提醒 Token 阈值", comment: ""), value: Binding(
                    get: { configuration.contextCompressionReminderTokenThreshold },
                    set: { configuration.contextCompressionReminderTokenThreshold = ContextCompressionReminderPolicy.normalizedTokenThreshold($0) }
                ), format: .number)
            } footer: {
                Text(NSLocalizedString("达到阈值时提醒，不会自动压缩。通知只打开选项，仍需手动创建续聊会话。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).disabled(!available)
        .navigationTitle(NSLocalizedString("上下文压缩", comment: ""))
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-compression-settings-\(configuration.enableContextCompressionReminder)"),
            title: NSLocalizedString("上下文压缩", comment: ""),
            documents: [GuideDocumentReference(id: "context-compression", title: "Context Compression")], isActive: visible && available,
            settings: [
                .bool("reminder_enabled", label: NSLocalizedString("上下文压缩提醒", comment: ""),
                    get: { configuration.enableContextCompressionReminder }, set: { configuration.enableContextCompressionReminder = $0 }),
                .integer("token_threshold", label: NSLocalizedString("提醒 Token 阈值", comment: ""),
                    range: ContextCompressionReminderPolicy.minimumTokenThreshold...ContextCompressionReminderPolicy.maximumTokenThreshold,
                    get: { configuration.contextCompressionReminderTokenThreshold }, set: { configuration.contextCompressionReminderTokenThreshold = $0 })
            ])
    }
}
