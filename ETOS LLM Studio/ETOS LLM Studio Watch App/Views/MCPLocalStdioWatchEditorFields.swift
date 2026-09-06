// ============================================================================
// MCPLocalStdioWatchEditorFields.swift
// ============================================================================
// watchOS 本地 stdio MCP 字段保持扁平、逐行交互；环境值只引用加密配置记录。
// ============================================================================

import ETOSCore
import SwiftUI

struct MCPLocalStdioWatchEditorFields: View {
    @Binding var configurationJSON: String
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
            Section(NSLocalizedString("stdio JSON", comment: "Watch local stdio MCP JSON section")) {
                TextField(
                    NSLocalizedString("stdio JSON", comment: "Watch local stdio MCP JSON editor"),
                    text: $configurationJSON,
                    axis: .vertical
                )
                .font(.caption2.monospaced())
                .lineLimit(8...18)
            }

            Section(NSLocalizedString("运行设置", comment: "Watch local stdio MCP runtime settings")) {
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
                HStack {
                    Text(NSLocalizedString("启动超时（秒）", comment: "Watch local stdio MCP startup timeout label"))
                    Spacer()
                    TextField("", value: $startupTimeoutSeconds, formatter: startupTimeoutFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
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
