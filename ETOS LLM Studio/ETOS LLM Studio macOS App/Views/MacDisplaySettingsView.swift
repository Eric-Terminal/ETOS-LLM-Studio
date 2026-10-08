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
                NavigationLink(NSLocalizedString("沉浸背景", comment: "")) { MacBackgroundSettingsView(model: workspace.backgrounds, isActive: available) }
                NavigationLink(NSLocalizedString("颜色配置", comment: "")) { MacAppearanceSettingsView(model: workspace.appearance, isActive: available) }
            }
            Section {
                Toggle(NSLocalizedString("Markdown 渲染", comment: ""), isOn: $configuration.enableMarkdown)
                Toggle(NSLocalizedString("增强工具结果显示（实验性）", comment: ""), isOn: $configuration.enableExperimentalToolResultDisplay)
                Toggle(NSLocalizedString("关闭助手气泡", comment: ""), isOn: $configuration.enableNoBubbleUI)
                Toggle(NSLocalizedString("液态玻璃效果", comment: ""), isOn: $configuration.enableLiquidGlass)
                if configuration.enableLiquidGlass {
                    Slider(value: $configuration.liquidGlassTintOpacity, in: 0...1, step: LiquidGlassTintSetting.opacityStep) {
                        Text(NSLocalizedString("玻璃底色不透明度", comment: ""))
                    }
                    Button(NSLocalizedString("恢复默认玻璃底色", comment: "")) { configuration.liquidGlassTintOpacity = LiquidGlassTintSetting.defaultOpacity }
                }
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
                .readOnly("background_requires_navigation", label: NSLocalizedString("沉浸背景", comment: ""), value: { .bool(true) }),
                .readOnly("colors_require_navigation", label: NSLocalizedString("颜色配置", comment: ""), value: { .bool(true) }),
                .bool("hide_assistant_bubble", label: NSLocalizedString("关闭助手气泡", comment: ""), get: { configuration.enableNoBubbleUI }, set: { configuration.enableNoBubbleUI = $0 }),
                .bool("liquid_glass", label: NSLocalizedString("液态玻璃效果", comment: ""), get: { configuration.enableLiquidGlass }, set: { configuration.enableLiquidGlass = $0 }),
                .double("liquid_glass_tint_opacity", label: NSLocalizedString("玻璃底色不透明度", comment: ""), range: 0...1,
                        get: { configuration.liquidGlassTintOpacity }, set: { configuration.liquidGlassTintOpacity = $0 }),
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
