import ETOSCore
import SwiftUI

struct MacBackgroundSettingsView: View {
    @ObservedObject var model: MacBackgroundModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "backgrounds", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 背景使用说明", comment: ""), documentID: "settings-display", isActive: available)
                Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $configuration.enableBackground)
                NavigationLink(NSLocalizedString("选择背景", comment: "")) { MacBackgroundLibraryView(model: model, isActive: available) }
                LabeledContent(NSLocalizedString("当前背景图", comment: ""), value: model.selectedFile?.id ?? NSLocalizedString("无", comment: ""))
                Picker(NSLocalizedString("填充模式", comment: ""), selection: $configuration.backgroundContentMode) {
                    Text(NSLocalizedString("填充 (居中裁剪)", comment: "")).tag("fill")
                    Text(NSLocalizedString("适应 (完整显示)", comment: "")).tag("fit")
                }
                Toggle(NSLocalizedString("自动轮换背景", comment: ""), isOn: $configuration.enableAutoRotateBackground)
            } header: { Text(NSLocalizedString("背景图层", comment: "")) }
            Section {
                LabeledContent(NSLocalizedString("背景模糊", comment: ""), value: String(format: NSLocalizedString("模糊 %.1f", comment: ""), configuration.backgroundBlur))
                Slider(value: $configuration.backgroundBlur, in: 0...25, step: 0.5) { Text(NSLocalizedString("背景模糊", comment: "")) }
                LabeledContent(NSLocalizedString("背景不透明度", comment: ""), value: String(format: NSLocalizedString("不透明度 %.2f", comment: ""), configuration.backgroundOpacity))
                Slider(value: $configuration.backgroundOpacity, in: 0.1...1, step: 0.05) { Text(NSLocalizedString("背景不透明度", comment: "")) }
            } header: { Text(NSLocalizedString("质感与特效", comment: "")) }
            Section {
                Toggle(NSLocalizedString("离开聊天时继续播放", comment: ""), isOn: $configuration.continueVideoBackgroundPlaybackWhenChatHidden)
            } footer: {
                Text(NSLocalizedString("视频背景静音循环播放，App 进入后台时暂停。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            MacBackgroundPlaybackError(model: model.playback)
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("沉浸背景", comment: ""))
        .disabled(!available)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(
            id: "mac-background-settings", title: NSLocalizedString("沉浸背景", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")], isActive: available && visible,
            settings: [
                .bool("background_enabled", label: NSLocalizedString("显示背景", comment: ""), get: { configuration.enableBackground }, set: { configuration.enableBackground = $0 }),
                .readOnly("current_background", label: NSLocalizedString("当前背景图", comment: ""), value: { .string(configuration.currentBackgroundImage) }),
                .string("background_content_mode", label: NSLocalizedString("填充模式", comment: ""), allowedValues: ["fill", "fit"], get: { configuration.backgroundContentMode }, set: { configuration.backgroundContentMode = $0 }),
                .bool("background_auto_rotation", label: NSLocalizedString("自动轮换背景", comment: ""), get: { configuration.enableAutoRotateBackground }, set: { configuration.enableAutoRotateBackground = $0 }),
                .double("background_blur", label: NSLocalizedString("背景模糊", comment: ""), range: 0...25, get: { configuration.backgroundBlur }, set: { configuration.backgroundBlur = $0 }),
                .double("background_opacity", label: NSLocalizedString("背景不透明度", comment: ""), range: 0.1...1, get: { configuration.backgroundOpacity }, set: { configuration.backgroundOpacity = $0 }),
                .bool("video_continue_when_hidden", label: NSLocalizedString("离开聊天时继续播放", comment: ""), get: { configuration.continueVideoBackgroundPlaybackWhenChatHidden }, set: { configuration.continueVideoBackgroundPlaybackWhenChatHidden = $0 }),
                .readOnly("selection_requires_navigation", label: NSLocalizedString("选择背景", comment: ""), value: { .bool(true) })
            ]
        )
    }
}

private struct MacBackgroundPlaybackError: View {
    @ObservedObject var model: MacBackgroundPlayback
    var body: some View {
        if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
    }
}
