import ETOSCore
import SwiftUI

/// 与移动端一致地分开会话、提示词和输出参数，向导只暴露当前页可见的字段。
struct MacCoreSettingsView: View {
    enum Page: String { case conversation, prompts, output }
    let page: Page
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared

    private var title: String {
        switch page {
        case .conversation: NSLocalizedString("会话", comment: "")
        case .prompts: NSLocalizedString("提示词", comment: "")
        case .output: NSLocalizedString("输出", comment: "")
        }
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "core-\(page.rawValue)", title: NSLocalizedString("使用说明", comment: ""),
                    details: introduction, documentID: "macos-workspace", isActive: isActive)
            }
            switch page {
            case .conversation:
                Section {
                    Toggle(NSLocalizedString("自动命名会话", comment: ""), isOn: $configuration.enableAutoSessionNaming)
                    Stepper(value: $configuration.maxChatHistory, in: 0...1000) {
                        Text(String(format: NSLocalizedString("历史消息数：%d", comment: ""), configuration.maxChatHistory))
                    }
                    NavigationLink(NSLocalizedString("上下文压缩", comment: "")) {
                        MacContextCompressionSettingsView(isActive: isActive)
                    }
                }
                Section(NSLocalizedString("记忆", comment: "")) {
                    Toggle(NSLocalizedString("启用记忆", comment: ""), isOn: $configuration.enableMemory)
                    Toggle(NSLocalizedString("允许写入记忆", comment: ""), isOn: $configuration.enableMemoryWrite)
                    Toggle(NSLocalizedString("主动检索记忆", comment: ""), isOn: $configuration.enableMemoryActiveRetrieval)
                }
            case .prompts:
                Section(NSLocalizedString("系统提示词", comment: "")) {
                    TextField(NSLocalizedString("系统提示词", comment: ""), text: $configuration.systemPrompt, axis: .vertical)
                        .lineLimit(5...16)
                    Toggle(NSLocalizedString("在提示词中包含系统时间", comment: ""), isOn: $configuration.includeSystemTimeInPrompt)
                }
                Section {
                    NavigationLink(NSLocalizedString("工具描述", comment: "")) {
                        BuiltInToolDescriptionListView(isActive: isActive) { target in
                            ToolDescriptionEditorView(target: target, isActive: isActive)
                        }
                    }
                    NavigationLink(NSLocalizedString("Agent 提示词", comment: "")) {
                        MacAgentPromptsView(isActive: isActive, model: workspace.agentPrompts)
                    }
                }
            case .output:
                Section { Toggle(NSLocalizedString("流式输出", comment: ""), isOn: $configuration.enableStreaming) }
                Section(NSLocalizedString("生成参数", comment: "")) {
                    Toggle(NSLocalizedString("启用温度参数", comment: ""), isOn: $configuration.aiTemperatureEnabled)
                    Slider(value: $configuration.aiTemperature, in: 0...2) { Text(NSLocalizedString("温度", comment: "")) }
                        .disabled(!configuration.aiTemperatureEnabled)
                    Toggle(NSLocalizedString("启用 Top P", comment: ""), isOn: $configuration.aiTopPEnabled)
                    Slider(value: $configuration.aiTopP, in: 0...1) { Text(NSLocalizedString("Top P", comment: "")) }
                        .disabled(!configuration.aiTopPEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-settings-\(page.rawValue)"), title: title,
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: isActive, settings: settings)
    }

    private var introduction: String {
        switch page {
        case .conversation: NSLocalizedString("mac.settings.conversation.help", value: "Automatic naming, history limits and memory switches apply to conversation requests. These settings save immediately. Open Context Compression to configure reminders; starting a continuation still requires your confirmation.", comment: "Mac 会话设置说明")
        case .prompts: NSLocalizedString("mac.settings.prompts.help", value: "The system prompt provides instructions for future requests. Conversation-specific prompts can override it. The time switch adds the current time to the prompt. Agent prompts have their own editor. Changes here save immediately and do not send a message.", comment: "Mac 提示词设置说明")
        case .output: NSLocalizedString("mac.settings.output.help", value: "Streaming displays a reply as it arrives. Temperature and Top P are sent only when their switches are enabled; supported ranges depend on the model. Changes save immediately and apply to future requests.", comment: "Mac 输出设置说明")
        }
    }

    private var settings: [GuidePageSetting] {
        switch page {
        case .conversation: [
            .bool("auto_title", label: NSLocalizedString("自动命名会话", comment: ""), get: { configuration.enableAutoSessionNaming }, set: { configuration.enableAutoSessionNaming = $0 }),
            .integer("history_limit", label: NSLocalizedString("历史消息数", comment: ""), range: 0...1000, get: { configuration.maxChatHistory }, set: { configuration.maxChatHistory = $0 }),
            .bool("memory", label: NSLocalizedString("启用记忆", comment: ""), get: { configuration.enableMemory }, set: { configuration.enableMemory = $0 }),
            .bool("memory_write", label: NSLocalizedString("允许写入记忆", comment: ""), get: { configuration.enableMemoryWrite }, set: { configuration.enableMemoryWrite = $0 }),
            .bool("memory_retrieval", label: NSLocalizedString("主动检索记忆", comment: ""), get: { configuration.enableMemoryActiveRetrieval }, set: { configuration.enableMemoryActiveRetrieval = $0 }),
            .readOnly("compression_requires_navigation", label: NSLocalizedString("上下文压缩", comment: ""), value: { .bool(true) })
        ]
        case .prompts: [
            .string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { configuration.systemPrompt }, set: { configuration.systemPrompt = $0 }),
            .bool("system_time", label: NSLocalizedString("在提示词中包含系统时间", comment: ""), get: { configuration.includeSystemTimeInPrompt }, set: { configuration.includeSystemTimeInPrompt = $0 }),
            .readOnly("tool_descriptions_require_navigation", label: NSLocalizedString("工具描述", comment: ""), value: { .bool(true) }),
            .readOnly("agent_prompts_require_navigation", label: NSLocalizedString("Agent 提示词", comment: ""), value: { .bool(true) })
        ]
        case .output: [
            .bool("streaming", label: NSLocalizedString("流式输出", comment: ""), get: { configuration.enableStreaming }, set: { configuration.enableStreaming = $0 }),
            .bool("temperature_enabled", label: NSLocalizedString("启用温度参数", comment: ""), get: { configuration.aiTemperatureEnabled }, set: { configuration.aiTemperatureEnabled = $0 }),
            .double("temperature", label: NSLocalizedString("温度", comment: ""), range: 0...2, get: { configuration.aiTemperature }, set: { configuration.aiTemperature = $0 }),
            .bool("top_p_enabled", label: NSLocalizedString("启用 Top P", comment: ""), get: { configuration.aiTopPEnabled }, set: { configuration.aiTopPEnabled = $0 }),
            .double("top_p", label: NSLocalizedString("Top P", comment: ""), range: 0...1, get: { configuration.aiTopP }, set: { configuration.aiTopP = $0 })
        ]
        }
    }
}
