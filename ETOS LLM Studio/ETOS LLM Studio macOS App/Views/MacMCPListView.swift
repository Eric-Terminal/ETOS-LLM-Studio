import ETOSCore
import SwiftUI

struct MacMCPListView: View {
    let isActive: Bool
    @ObservedObject private var manager = MCPManager.shared
    @State private var newServer: MCPServerConfiguration?
    @State private var error: String?

    private static let preferenceTool = InternalToolDefinition(
        name: "propose_mac_mcp_enabled",
        description: NSLocalizedString("MCP 聊天工具", comment: ""),
        parameters: .dictionary([
            "type": .string("object"),
            "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
            "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
        ])
    )

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("MCP 聊天工具", comment: ""), isOn: Binding(
                    get: { manager.chatToolsEnabled }, set: { enabled in
                        Task {
                            do { try await manager.setChatToolsEnabledInBackground(enabled) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                ))
                MacSettingsIntroCard(id: "mcp", title: NSLocalizedString("使用说明", comment: ""), details: NSLocalizedString("Mac 的 stdio 服务器直接运行本机程序，需先自行安装依赖。配置保存后不会立即运行；连接时读取工具目录，加入聊天后由工具审批控制调用。", comment: ""), documentID: "macos-workspace")
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            ForEach(manager.servers) { server in
                NavigationLink {
                    MacMCPServerDetail(server: server, isActive: isActive)
                } label: {
                    VStack(alignment: .leading) {
                        Text(server.displayName)
                        Text(server.humanReadableEndpoint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("MCP 工具", comment: ""))
        .toolbar {
            Button {
                newServer = MCPServerConfiguration(displayName: "", transport: .localStdio(configuration: .init(command: "")))
            } label: {
                Label(NSLocalizedString("添加服务器", comment: ""), systemImage: "plus")
            }
        }
        .sheet(item: $newServer) { server in MacMCPServerEditor(server: server, original: nil) }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "mac-mcp", title: NSLocalizedString("MCP 工具", comment: ""),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Tools"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                tools: [GuidePageTool(definition: Self.preferenceTool, access: .proposeChange)]
            ),
            isActive: isActive,
            snapshot: { GuidePageSnapshot(fields: [
                "enabled": GuideSnapshotField(label: NSLocalizedString("MCP 聊天工具", comment: ""), value: .bool(manager.chatToolsEnabled)),
                "server_count": GuideSnapshotField(label: NSLocalizedString("服务器数量", comment: ""), value: .int(manager.servers.count), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == Self.preferenceTool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                guard case .bool(let value)? = arguments["enabled"], value != manager.chatToolsEnabled else { throw GuideError.invalidToolArguments }
                return GuideActionProposal(
                    pageID: "mac-mcp", toolCallID: call.id, toolName: call.toolName,
                    summary: NSLocalizedString("MCP 聊天工具", comment: ""),
                    mutations: [GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用", comment: ""), oldValue: .bool(manager.chatToolsEnabled), newValue: .bool(value))],
                    arguments: arguments
                )
            },
            execute: { proposal in
                guard case .bool(let value)? = proposal.arguments["enabled"] else { throw GuideError.invalidToolArguments }
                let old = manager.chatToolsEnabled
                try await manager.setChatToolsEnabledInBackground(value)
                return GuideActionExecution(
                    message: NSLocalizedString("已保存配置。", comment: ""),
                    undoProposal: GuideActionProposal(pageID: "mac-mcp", toolCallID: "undo-\(proposal.toolCallID)", toolName: Self.preferenceTool.name, summary: NSLocalizedString("撤销修改", comment: ""), mutations: [], arguments: ["enabled": .bool(old)])
                )
            }
        )
    }
}

private struct MacMCPServerDetail: View {
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServerConfiguration
    let isActive: Bool
    @State private var editing = false
    @State private var deleting = false
    @State private var error: String?
    private var status: MCPServerStatus { manager.status(for: server) }

    var body: some View {
        Form {
            Section {
                Text(server.humanReadableEndpoint).textSelection(.enabled)
                Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: Binding(
                    get: { server.isSelectedForChat },
                    set: { value in var updated = server; updated.isSelectedForChat = value; save(updated) }
                ))
                Button(NSLocalizedString("连接", comment: "")) { manager.connect(to: server) }
                    .disabled(status.isBusy)
                Button(NSLocalizedString("断开", comment: "")) { manager.disconnect(server: server) }
                Button(NSLocalizedString("刷新工具列表", comment: "")) { manager.refreshMetadata(for: server) }
                    .disabled(status.isBusy)
                if status.isBusy { ProgressView() }
                if case .failed(let reason) = status.connectionState {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                ForEach(status.tools) { tool in
                    NavigationLink(tool.toolId) { MacMCPToolSettings(server: server, tool: tool, isActive: isActive) }
                }
            } header: { Text(NSLocalizedString("工具", comment: "")) }
            Section {
                ForEach(status.resources) { resource in
                    NavigationLink(resource.resourceId) { MacMCPReadView(server: server, target: .resource(resource)) }
                }
                if status.resources.isEmpty {
                    Text(NSLocalizedString("当前服务器尚未暴露资源。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text(NSLocalizedString("资源", comment: "")) }
            if !status.resourceTemplates.isEmpty {
                Section {
                    ForEach(status.resourceTemplates) { template in
                        NavigationLink(template.title ?? template.name ?? template.uriTemplate) { MacMCPReadView(server: server, target: .template(template)) }
                    }
                } header: { Text(NSLocalizedString("资源模板", comment: "")) }
            }
            if !status.prompts.isEmpty {
                Section {
                    ForEach(status.prompts) { prompt in
                        NavigationLink(prompt.name) { MacMCPReadView(server: server, target: .prompt(prompt)) }
                    }
                } header: { Text(NSLocalizedString("提示词", comment: "")) }
            }
            Section {
                Button(NSLocalizedString("编辑", comment: "")) { editing = true }
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deleting = true }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(server.displayName)
        .sheet(isPresented: $editing) { MacMCPServerEditor(server: server, original: server) }
        .confirmationDialog(NSLocalizedString("删除服务器", comment: ""), isPresented: $deleting, titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                Task {
                    do { try await manager.deleteServerInBackground(server); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onReceive(manager.$servers) { servers in
            if let current = servers.first(where: { $0.id == server.id }) { server = current }
            else { dismiss() }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: GuidePageID(rawValue: "mac-mcp-detail-\(server.id)"), title: server.displayName,
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Tools")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateMCPServer, access: .proposeChange)]
            ),
            isActive: isActive,
            snapshot: { GuideMCPServerSettingsSupport.snapshot(server: server, status: status) },
            buildProposal: { call, _ in
                try GuideMCPServerSettingsSupport.buildProposal(call: call, pageID: GuidePageID(rawValue: "mac-mcp-detail-\(server.id)"), server: server)
            },
            execute: { proposal in
                let original = server
                let application = try GuideMCPServerSettingsSupport.apply(proposal, to: original)
                try await manager.saveServerInBackground(application.server, replacing: original)
                return application.execution
            }
        )
    }

    private func save(_ updated: MCPServerConfiguration) {
        let original = server
        Task {
            do { try await manager.saveServerInBackground(updated, replacing: original) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacMCPToolSettings: View {
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServerConfiguration
    let tool: MCPToolDescription
    let isActive: Bool
    @State private var error: String?

    var body: some View {
        Form {
            Text(server.effectiveDescription(for: tool) ?? "").font(.footnote).foregroundStyle(.secondary)
            NavigationLink(NSLocalizedString("编辑工具描述", value: "Edit Tool Description", comment: "")) {
                ToolDescriptionEditorView(target: .mcp(serverID: server.id, tool: tool), isActive: isActive)
            }
            Toggle(NSLocalizedString("启用", comment: ""), isOn: Binding(
                get: { server.isToolEnabled(tool.toolId) },
                set: { value in var updated = server; updated.setToolEnabled(tool.toolId, isEnabled: value); save(updated) }
            ))
            Picker(NSLocalizedString("审批策略", comment: ""), selection: Binding(
                get: { manager.approvalPolicy(serverID: server.id, toolId: tool.toolId) },
                set: { policy in var updated = server; updated.toolApprovalPolicies[tool.toolId] = policy; save(updated) }
            )) {
                ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .disabled(MCPNativeCapabilityPolicy.requiresPerCallApproval(tool.toolId))
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(tool.toolId)
        .onReceive(manager.$servers) { servers in
            if let current = servers.first(where: { $0.id == server.id }) { server = current }
            else { dismiss() }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: GuidePageID(rawValue: "mac-mcp-tool-\(server.id)-\(tool.toolId)"), title: tool.toolId,
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Tools")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateMCPTool, access: .proposeChange)]
            ),
            isActive: isActive,
            snapshot: { GuideMCPToolSettingsSupport.snapshot(server: server, tool: tool) },
            buildProposal: { call, _ in
                try GuideMCPToolSettingsSupport.buildProposal(call: call, pageID: GuidePageID(rawValue: "mac-mcp-tool-\(server.id)-\(tool.toolId)"), server: server, tool: tool)
            },
            execute: { proposal in
                let original = server
                let application = try GuideMCPToolSettingsSupport.apply(proposal, server: original, tool: tool)
                var updated = original
                updated.setToolEnabled(tool.toolId, isEnabled: application.enabled)
                updated.toolApprovalPolicies[tool.toolId] = application.approvalPolicy
                try await manager.saveServerInBackground(updated, replacing: original)
                return application.execution
            }
        )
    }

    private func save(_ updated: MCPServerConfiguration) {
        let original = server
        Task {
            do { try await manager.saveServerInBackground(updated, replacing: original) }
            catch { self.error = error.localizedDescription }
        }
    }
}
