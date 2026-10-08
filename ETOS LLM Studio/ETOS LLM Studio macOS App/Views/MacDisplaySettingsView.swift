import ETOSCore
import SwiftUI

struct MacDisplaySettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "display", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 消息显示使用说明", comment: ""), documentID: "settings-display", isActive: available)
            }
            Section {
                Toggle(NSLocalizedString("Markdown 渲染", comment: ""), isOn: $configuration.enableMarkdown)
                Toggle(NSLocalizedString("增强工具结果显示（实验性）", comment: ""), isOn: $configuration.enableExperimentalToolResultDisplay)
            } header: { Text(NSLocalizedString("气泡与排版", comment: "")) }
            Section {
                TextField(NSLocalizedString("预览字符数", comment: ""), value: $configuration.userMessagePreviewCharacterLimit,
                          format: .number.grouping(.never))
            } header: { Text(NSLocalizedString("长用户消息", comment: "")) } footer: {
                Text(NSLocalizedString("仅影响显示，复制、编辑和发送仍使用完整消息。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(NSLocalizedString("自动预览思考过程", comment: ""), isOn: $configuration.enableAutoReasoningPreview)
                Toggle(NSLocalizedString("响应式思考预览高度", comment: ""), isOn: $configuration.enableResponsiveReasoningPreviewHeight)
                if !configuration.enableResponsiveReasoningPreviewHeight {
                    LabeledContent(NSLocalizedString("预览高度百分比", comment: "")) {
                        Text(String(format: NSLocalizedString("%.0f%%", comment: ""), configuration.reasoningPreviewHeightPercent))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $configuration.reasoningPreviewHeightPercent, in: 1...100) {
                        Text(NSLocalizedString("预览高度百分比", comment: ""))
                    }
                }
            } header: { Text(NSLocalizedString("思考过程展现", comment: "")) } footer: {
                Text(NSLocalizedString("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("显示设置", comment: ""))
        .disabled(!available)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(
            id: "mac-display", title: NSLocalizedString("显示设置", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings"),
                        GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available && visible,
            settings: [
                .bool("markdown", label: NSLocalizedString("Markdown 渲染", comment: ""), get: { configuration.enableMarkdown }, set: { configuration.enableMarkdown = $0 }),
                .bool("enhanced_tool_results", label: NSLocalizedString("增强工具结果显示（实验性）", comment: ""), get: { configuration.enableExperimentalToolResultDisplay }, set: { configuration.enableExperimentalToolResultDisplay = $0 }),
                .integer("user_message_preview_character_limit", label: NSLocalizedString("预览字符数", comment: ""), range: ChatUserMessagePreview.characterLimitRange,
                         get: { configuration.userMessagePreviewCharacterLimit }, set: { configuration.userMessagePreviewCharacterLimit = $0 }),
                .bool("auto_reasoning_preview", label: NSLocalizedString("自动预览思考过程", comment: ""), get: { configuration.enableAutoReasoningPreview }, set: { configuration.enableAutoReasoningPreview = $0 }),
                .bool("responsive_reasoning_preview_height", label: NSLocalizedString("响应式思考预览高度", comment: ""), get: { configuration.enableResponsiveReasoningPreviewHeight }, set: { configuration.enableResponsiveReasoningPreviewHeight = $0 }),
                .double("reasoning_preview_height_percent", label: NSLocalizedString("预览高度百分比", comment: ""), range: 1...100,
                        get: { configuration.reasoningPreviewHeightPercent }, set: { configuration.reasoningPreviewHeightPercent = $0 })
            ]
        )
    }
}
