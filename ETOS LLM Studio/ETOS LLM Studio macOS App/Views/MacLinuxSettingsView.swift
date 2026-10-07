import ETOSCore
import SwiftUI

struct MacLinuxSettingsView: View {
    let isActive: Bool
    @ObservedObject var model: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var timeout: Binding<Int> { Binding(get: { configuration.localLinuxDefaultTimeoutSeconds }, set: { configuration.localLinuxDefaultTimeoutSeconds = min(max(0, $0), 4_294_967) }) }
    private var outputLimit: Binding<Int> { Binding(get: { max(4, configuration.localLinuxOutputPreviewBytes / 1_024) }, set: { configuration.localLinuxOutputPreviewBytes = min(max(4, $0), 4_194_303) * 1_024 }) }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "linux-settings", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 本地 Linux 使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: isActive && workspace.canManageLocalModels && !model.isSuspended)
                Picker(NSLocalizedString("默认终端 Shell", comment: ""), selection: $configuration.localLinuxDefaultShellPath) {
                    ForEach(model.shellPaths, id: \.self) { shell in Text(shell).tag(shell) }
                }
            } footer: { Text(NSLocalizedString("仅影响新终端，Agent 脚本仍使用 /bin/sh。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
            Section {
                Picker(NSLocalizedString("新会话默认模式", comment: ""), selection: $configuration.localLinuxDefaultSessionMode) {
                    ForEach(LocalAgentMode.allCases) { mode in Text(mode.displayName).tag(mode.rawValue) }
                }
                TextField(NSLocalizedString("默认命令超时（秒）", comment: ""), value: timeout, format: .number)
                TextField(NSLocalizedString("发送给模型的输出上限（KB）", comment: ""), value: outputLimit, format: .number)
            } footer: {
                Text(NSLocalizedString("0 表示命令不限时。命令输出超过设置大小时，只会截断发送给模型的副本；用户终端仍保留完整输出。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(NSLocalizedString("发送给模型前隐藏环境变量值", comment: ""), isOn: $configuration.localLinuxEnvironmentPrivacyEnabled)
                Toggle(NSLocalizedString("启用命令安全策略", comment: ""), isOn: $configuration.localLinuxCommandSafetyEnabled)
                NavigationLink {
                    MacAgentPromptsView(isActive: isActive, model: workspace.agentPrompts)
                } label: { Label(NSLocalizedString("Agent 提示词", comment: ""), systemImage: "text.bubble") }
            } footer: {
                Text(NSLocalizedString("开启后，命令与本地 MCP 输出中出现已启用环境变量的值时，只会在发送给模型前替换；用户终端和原始日志保持不变。关闭后会原样发送。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("配置", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || model.isSuspended || model.isWorking)
        .onAppear { visible = true; if active { model.observe() } }.onDisappear { visible = false }
        .onChange(of: active) { _, value in if value { model.observe() } }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-settings-\(model.epoch)"), title: NSLocalizedString("配置", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && model.canOperate,
            settings: [
                .string("default_shell_path", label: NSLocalizedString("默认终端 Shell", comment: ""), allowedValues: model.shellPaths, allowsEmpty: false, get: { configuration.localLinuxDefaultShellPath }, set: { configuration.localLinuxDefaultShellPath = $0 }),
                .string("default_session_mode", label: NSLocalizedString("新会话默认模式", comment: ""), allowedValues: [LocalAgentMode.chat.rawValue, LocalAgentMode.agent.rawValue], get: { configuration.localLinuxDefaultSessionMode }, set: { configuration.localLinuxDefaultSessionMode = $0 }),
                .integer("default_timeout_seconds", label: NSLocalizedString("默认命令超时（秒）", comment: ""), range: 0...4_294_967, get: { timeout.wrappedValue }, set: { timeout.wrappedValue = $0 }),
                .integer("model_output_limit_kb", label: NSLocalizedString("发送给模型的输出上限（KB）", comment: ""), range: 4...4_194_303, get: { outputLimit.wrappedValue }, set: { outputLimit.wrappedValue = $0 }),
                .bool("redact_environment_values", label: NSLocalizedString("发送给模型前隐藏环境变量值", comment: ""), get: { configuration.localLinuxEnvironmentPrivacyEnabled }, set: { configuration.localLinuxEnvironmentPrivacyEnabled = $0 }),
                .bool("command_safety_enabled", label: NSLocalizedString("启用命令安全策略", comment: ""), get: { configuration.localLinuxCommandSafetyEnabled }, set: { configuration.localLinuxCommandSafetyEnabled = $0 })
            ]
        )
    }
}
