// ============================================================================
// MCPLocalStdioWatchEditorFields.swift
// ============================================================================
// watchOS 本地 stdio MCP 字段保持扁平、逐行交互；环境值只引用加密配置记录。
// ============================================================================

import ETOSCore
import SwiftUI

struct MCPLocalStdioWatchEditorFields: View {
    @Binding var command: String
    @Binding var argumentsText: String
    @Binding var workingDirectory: String
    @Binding var environmentVariableIDs: Set<UUID>
    @Binding var inheritEnvironment: Bool
    @Binding var workspaceID: UUID?
    @Binding var mountIDs: Set<UUID>
    @Binding var startupTimeoutSeconds: Double
    @Binding var launchPolicy: MCPLocalStdioLaunchPolicy
    @Binding var idlePolicy: MCPLocalStdioIdlePolicy

    @State private var environmentVariables: [LocalLinuxEnvironmentVariable] = []
    @State private var workspaces: [LocalAgentWorkspace] = []
    @State private var mounts: [LocalLinuxMountRecord] = []

    var body: some View {
        Group {
            Section {
                TextField(
                    NSLocalizedString("Command", comment: "Local stdio MCP command field"),
                    text: $command.watchKeyboardNewlineBinding()
                )
                TextField(
                    NSLocalizedString("工作目录", comment: "Local stdio MCP working directory field"),
                    text: $workingDirectory.watchKeyboardNewlineBinding()
                )
                Picker(NSLocalizedString("启动方式", comment: "Local stdio MCP launch policy"), selection: $launchPolicy) {
                    ForEach(MCPLocalStdioLaunchPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Picker(NSLocalizedString("空闲进程", comment: "Local stdio MCP idle policy"), selection: $idlePolicy) {
                    ForEach(MCPLocalStdioIdlePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                TextField(
                    NSLocalizedString("启动超时（秒，0 为不限制）", comment: "Local stdio MCP startup timeout"),
                    value: $startupTimeoutSeconds,
                    formatter: startupTimeoutFormatter
                )
            } header: {
                Text(NSLocalizedString("本地 stdio", comment: "Local stdio MCP section"))
            } footer: {
                Text(NSLocalizedString("stdout 只传 JSON-RPC，普通日志写入 stderr；ETOS 不会自动安装依赖。", comment: "Watch local stdio MCP footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("参数（每行一个）", comment: "Local stdio MCP arguments section")) {
                TextField(
                    NSLocalizedString("参数（每行一个）", comment: "Local stdio MCP arguments editor"),
                    text: $argumentsText.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...12)
            }

            Section {
                Toggle(
                    NSLocalizedString("继承全部已启用变量", comment: "Inherit all enabled local Linux variables for MCP"),
                    isOn: $inheritEnvironment
                )
                ForEach(environmentVariables) { variable in
                    Toggle(isOn: membershipBinding(variable.id, in: $environmentVariableIDs)) {
                        VStack(alignment: .leading) {
                            Text(variable.name).font(.caption.monospaced())
                            if !variable.isEnabled {
                                Text(NSLocalizedString("已停用", comment: "Disabled environment variable short state"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("环境变量引用", comment: "Local stdio MCP environment references"))
            } footer: {
                Text(NSLocalizedString("变量值仍在本地 Linux 设置中统一编辑。", comment: "Watch MCP environment references footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(NSLocalizedString("工作区", comment: "Local stdio MCP workspace"), selection: $workspaceID) {
                    Text(NSLocalizedString("自动", comment: "Automatic workspace"))
                        .tag(Optional<UUID>.none)
                    ForEach(workspaces) { workspace in
                        Text(workspace.guestPath).tag(Optional(workspace.id))
                    }
                }
                ForEach(mounts) { mount in
                    Toggle(isOn: membershipBinding(mount.id, in: $mountIDs)) {
                        VStack(alignment: .leading) {
                            Text(mount.displayName)
                            Text(mount.guestPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("工作区与挂载", comment: "Watch local stdio MCP workspace and mounts"))
            } footer: {
                Text(NSLocalizedString("目录授权失效时，需在支持系统目录选择器的设备上重新授权。", comment: "Watch MCP mount authorization footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await reloadReferences() }
    }

    private var startupTimeoutFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }

    private func membershipBinding(
        _ id: UUID,
        in selection: Binding<Set<UUID>>
    ) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { isSelected in
                if isSelected {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        )
    }

    @MainActor
    private func reloadReferences() async {
        async let loadedVariables = LocalLinuxProcessEnvironmentProvider.shared.variables()
        async let loadedWorkspaces = LocalLinuxStorageManager.shared.workspaces()
        async let loadedMounts = LocalLinuxMountManager.shared.records()
        environmentVariables = await loadedVariables
        workspaces = await loadedWorkspaces
        mounts = await loadedMounts
    }
}
