// ============================================================================
// MCPLocalStdioEditorFields.swift
// ============================================================================
// 本地 stdio MCP 的 Linux 专属字段。环境值仍由本地 Linux 设置中的加密
// GRDB 记录持有，这里只选择稳定 ID，避免产生第二份明文配置。
// ============================================================================

import ETOSCore
import SwiftUI

struct MCPLocalStdioEditorFields: View {
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
                TextField(NSLocalizedString("Command", comment: "Local stdio MCP command field"), text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(NSLocalizedString("工作目录", comment: "Local stdio MCP working directory field"), text: $workingDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    format: .number
                )
                .keyboardType(.decimalPad)
            } header: {
                Text(NSLocalizedString("本地 stdio", comment: "Local stdio MCP section"))
            } footer: {
                Text(NSLocalizedString("进程在内置 Linux 中运行；stdout 仅用于逐行 JSON-RPC，日志必须写入 stderr。ETOS 不会自动安装命令或依赖。", comment: "Local stdio MCP footer"))
            }

            Section(NSLocalizedString("参数（每行一个）", comment: "Local stdio MCP arguments section")) {
                TextEditor(text: $argumentsText)
                    .frame(minHeight: 100)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Toggle(
                    NSLocalizedString("继承全部已启用变量", comment: "Inherit all enabled local Linux variables for MCP"),
                    isOn: $inheritEnvironment
                )
                ForEach(environmentVariables) { variable in
                    Toggle(isOn: membershipBinding(variable.id, in: $environmentVariableIDs)) {
                        VStack(alignment: .leading) {
                            Text(variable.name).font(.body.monospaced())
                            if !variable.note.isEmpty {
                                Text(variable.note).font(.caption).foregroundStyle(.secondary)
                            }
                            if !variable.isEnabled {
                                Text(NSLocalizedString("变量当前已停用", comment: "Disabled Linux environment variable"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("环境变量引用", comment: "Local stdio MCP environment references"))
            } footer: {
                Text(NSLocalizedString("这里只保存本地 Linux 环境变量的记录 ID；变量值仍在加密配置数据库中统一编辑和同步。", comment: "Local stdio MCP environment references footer"))
            }

            Section {
                Picker(NSLocalizedString("工作区", comment: "Local stdio MCP workspace"), selection: $workspaceID) {
                    Text(NSLocalizedString("跟随 Agent；手动连接时使用专属工作区", comment: "Local stdio MCP automatic workspace"))
                        .tag(Optional<UUID>.none)
                    ForEach(workspaces) { workspace in
                        Text(workspace.guestPath).tag(Optional(workspace.id))
                    }
                }
                ForEach(mounts) { mount in
                    Toggle(isOn: membershipBinding(mount.id, in: $mountIDs)) {
                        VStack(alignment: .leading) {
                            Text(mount.displayName)
                            Text("\(mount.guestPath) · \(mount.access.displayName) · \(mount.authorizationState.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("工作区与外部挂载", comment: "Local stdio MCP workspace and mounts"))
            } footer: {
                Text(NSLocalizedString("MCP 只取得这里选择的外部挂载租约；不可用或失效的授权会在启动时明确报错。", comment: "Local stdio MCP mounts footer"))
            }
        }
        .task { await reloadReferences() }
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
