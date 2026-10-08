import ETOSCore
import SwiftUI

@MainActor
struct MacChatAnimationSettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "chat-animation", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 聊天动画使用说明", comment: ""), documentID: "settings-display", isActive: available)
            }
            Section {
                Toggle(NSLocalizedString("弹性滚动", comment: ""), isOn: $configuration.chatScrollAnimationEnabled)
                Slider(value: normalized($configuration.chatScrollAnimationOffset, in: 4...60), in: 4...60, step: 2) {
                    Text(String(format: NSLocalizedString("位移幅度 %.0f pt", comment: ""), configuration.chatScrollAnimationOffset))
                }
                Slider(value: normalized($configuration.chatScrollAnimationSpringResponse, in: 0.15...1), in: 0.15...1, step: 0.05) {
                    Text(String(format: NSLocalizedString("弹簧响应 %.2f s", comment: ""), configuration.chatScrollAnimationSpringResponse))
                }
                Slider(value: normalized($configuration.chatScrollAnimationSpringDamping, in: 0.1...0.95), in: 0.1...0.95, step: 0.05) {
                    Text(String(format: NSLocalizedString("弹簧阻尼 %.2f", comment: ""), configuration.chatScrollAnimationSpringDamping))
                }
                Button(NSLocalizedString("恢复默认参数", comment: "")) {
                    configuration.chatScrollAnimationOffset = 32
                    configuration.chatScrollAnimationSpringResponse = 0.55
                    configuration.chatScrollAnimationSpringDamping = 0.52
                }
            } header: { Text(NSLocalizedString("弹性滚动", comment: "")) }
            Section {
                Toggle(NSLocalizedString("发送入场动画", comment: ""), isOn: $configuration.chatSendAnimationEnabled)
                Slider(value: normalized($configuration.chatSendAnimationSpringResponse, in: 0.2...0.8), in: 0.2...0.8, step: 0.05) {
                    Text(String(format: NSLocalizedString("飞入速度 %.2f s", comment: ""), configuration.chatSendAnimationSpringResponse))
                }
                Slider(value: normalized($configuration.chatSendAnimationSpringDamping, in: 0.4...1), in: 0.4...1, step: 0.05) {
                    Text(String(format: NSLocalizedString("落点回弹 %.2f", comment: ""), configuration.chatSendAnimationSpringDamping))
                }
                Button(NSLocalizedString("恢复发送动画默认", comment: "")) {
                    configuration.chatSendAnimationSpringResponse = 0.45
                    configuration.chatSendAnimationSpringDamping = 0.6
                }
            } header: { Text(NSLocalizedString("发送入场动画", comment: "")) } footer: {
                Text(NSLocalizedString("调整后可回到聊天中查看效果。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("聊天动画", comment: ""))
        .disabled(!available)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: "mac-chat-animation", title: NSLocalizedString("聊天动画", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings"),
                        GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available && visible,
            settings: [
                .bool("scroll_animation", label: NSLocalizedString("弹性滚动", comment: ""), get: { configuration.chatScrollAnimationEnabled }, set: { configuration.chatScrollAnimationEnabled = $0 }),
                .double("scroll_offset", label: NSLocalizedString("位移幅度", comment: ""), range: 4...60,
                        get: { configuration.chatScrollAnimationOffset }, set: { configuration.chatScrollAnimationOffset = $0 }),
                .double("scroll_spring_response", label: NSLocalizedString("弹簧响应", comment: ""), range: 0.15...1,
                        get: { configuration.chatScrollAnimationSpringResponse }, set: { configuration.chatScrollAnimationSpringResponse = $0 }),
                .double("scroll_spring_damping", label: NSLocalizedString("弹簧阻尼", comment: ""), range: 0.1...0.95,
                        get: { configuration.chatScrollAnimationSpringDamping }, set: { configuration.chatScrollAnimationSpringDamping = $0 }),
                .bool("send_animation", label: NSLocalizedString("发送入场动画", comment: ""), get: { configuration.chatSendAnimationEnabled }, set: { configuration.chatSendAnimationEnabled = $0 }),
                .double("send_spring_response", label: NSLocalizedString("飞入速度", comment: ""), range: 0.2...0.8,
                        get: { configuration.chatSendAnimationSpringResponse }, set: { configuration.chatSendAnimationSpringResponse = $0 }),
                .double("send_spring_damping", label: NSLocalizedString("落点回弹", comment: ""), range: 0.4...1,
                        get: { configuration.chatSendAnimationSpringDamping }, set: { configuration.chatSendAnimationSpringDamping = $0 })
            ])
    }

    private func normalized(_ binding: Binding<Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { min(range.upperBound, max(range.lowerBound, binding.wrappedValue)) },
                set: { binding.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) })
    }
}
