// ============================================================================
// MCPIntegrationViewSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App MCP 工具箱辅助视图
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false

    private var server: MCPServerConfiguration? {
        manager.servers.first(where: { $0.id == serverID })
    }

    var body: some View {
        List {
            if let server {
                let status = manager.status(for: server)
                Section(NSLocalizedString("服务器信息", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: ""), value: server.displayName)
                    LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                    if let notes = server.notes {
                        LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                    }
                    Text(statusDescription(for: server))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("连接控制", comment: "")) {
                    Button(NSLocalizedString("连接", comment: "")) {
                        manager.connect(to: server)
                    }
                    .disabled(status.connectionState == .ready || status.connectionState == .connecting || isReconnecting(status.connectionState))

                    Button(NSLocalizedString("断开", comment: "")) {
                        manager.disconnect(server: server)
                    }
                    .disabled(status.connectionState == .idle)

                    Button(NSLocalizedString("终止远端会话", comment: "")) {
                        Task {
                            await manager.terminateRemoteSession(for: server.id)
                        }
                    }
                    .disabled(status.connectionState == .idle)

                    Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: Binding(
                        get: { manager.status(for: server).isSelectedForChat },
                        set: { newValue in
                            let current = manager.status(for: server).isSelectedForChat
                            if newValue != current {
                                manager.toggleSelection(for: server)
                            }
                        }
                    ))
                    .disabled(status.connectionState == .connecting || isReconnecting(status.connectionState))

                    Button(NSLocalizedString("刷新工具/资源", comment: "")) {
                        manager.refreshMetadata(for: server)
                    }
                    .disabled(status.connectionState != .ready || status.isBusy)

                    if status.isBusy {
                        ProgressView()
                    }
                }

                Section(NSLocalizedString("工具", comment: "")) {
                    if status.tools.isEmpty {
                        Text(NSLocalizedString("当前服务器尚未公布任何工具。", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.tools) { tool in
                            NavigationLink {
                                MCPToolSettingsDetailView(serverID: server.id, tool: tool)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(tool.toolId)
                                        Spacer()
                                        Text(manager.isToolEnabled(serverID: server.id, toolId: tool.toolId) ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("已停用", comment: ""))
                                            .etFont(.caption2)
                                            .foregroundStyle(
                                                manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                                    ? Color.green
                                                    : Color.secondary
                                            )
                                    }
                                    if let desc = tool.description, !desc.isEmpty {
                                        Text(desc)
                                            .etFont(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.inputSchema, fieldLimit: 4) {
                                        Text("Schema: \(schemaSummary)")
                                            .etFont(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(3)
                                    }
                                    Text(NSLocalizedString("点击进入二级菜单配置开关与审批策略", comment: ""))
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section(NSLocalizedString("管理", comment: "")) {
                    NavigationLink(NSLocalizedString("编辑配置", comment: "")) {
                        MCPServerEditor(existingServer: server) {
                            manager.save(server: $0)
                        }
                    }

                    Button(NSLocalizedString("删除服务器", comment: ""), role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            } else {
                Section {
                    Text(NSLocalizedString("该服务器已被删除。", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(server?.displayName ?? NSLocalizedString("服务器详情", comment: ""))
        .confirmationDialog(NSLocalizedString("确定要删除此服务器？", comment: ""), isPresented: $showingDeleteConfirmation) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let server {
                    manager.delete(server: server)
                }
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
    }

    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return NSLocalizedString("未连接", comment: "")
        case .connecting:
            return NSLocalizedString("连接中", comment: "")
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return String(format: NSLocalizedString("重连中 %d 次 (%ds)", comment: ""), attempt, remaining)
        case .ready:
            return status.isSelectedForChat ? NSLocalizedString("聊天使用", comment: "") : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
        }
    }

    private func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
    }
}

struct MCPToolSettingsDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "")) {
                Text(tool.toolId)
                    .etFont(.headline)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.inputSchema, fieldLimit: 4) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "")),
                footer: Text(NSLocalizedString("默认“每次询问”，可按工具单独设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: ""), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: ""))
    }

    private var toolBinding: Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: tool.toolId, isEnabled: newValue)
        }
    }

    private var toolApprovalPolicyBinding: Binding<MCPToolApprovalPolicy> {
        Binding {
            manager.approvalPolicy(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolApprovalPolicy(serverID: serverID, toolId: tool.toolId, policy: newValue)
        }
    }
}

struct MCPToolListView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            if !manager.chatToolsEnabled {
                Text(NSLocalizedString("当前总开关已关闭，以下工具仅用于查看与配置，不会参与聊天调用。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if manager.tools.isEmpty {
                Text(NSLocalizedString("当前服务器尚未公布任何工具。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.tools) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.tool.toolId)
                            .etFont(.headline)
                        Text(tool.server.displayName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = tool.tool.description, !description.isEmpty {
                            Text(description)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.tool.inputSchema, fieldLimit: 4) {
                            Text("Schema: \(schemaSummary)")
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                        Text(tool.internalName)
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具列表", comment: ""))
    }
}

struct MCPResourceListView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            if manager.resources.isEmpty {
                Text(NSLocalizedString("当前服务器尚未暴露资源。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.resources) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.resource.resourceId)
                            .etFont(.headline)
                        Text(resource.server.displayName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = resource.resource.description, !description.isEmpty {
                            Text(description)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("资源列表", comment: ""))
    }
}

struct MCPGovernanceLogListView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            if manager.governanceLogEntries.isEmpty {
                Text(NSLocalizedString("暂无治理日志。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.governanceLogEntries.suffix(80).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(entry.serverDisplayName ?? NSLocalizedString("全局", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .etFont(.footnote)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }

                Button(NSLocalizedString("清空治理日志", comment: ""), role: .destructive) {
                    manager.clearGovernanceLogEntries()
                }
            }
        }
        .navigationTitle(NSLocalizedString("治理日志", comment: ""))
    }
}

struct MCPResponseDetailView: View {
    let output: String?
    let error: String?

    var body: some View {
        List {
            if let output {
                Section("Result") {
                    Text(output)
                        .etFont(.system(.footnote, design: .monospaced))
                }
            }

            if let error {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            }
        }
        .navigationTitle(NSLocalizedString("最新响应", comment: ""))
    }
}

struct MCPToolDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var selectedToolID: String?
    @State private var inputJSON = "{}"

    private var selectedTool: MCPAvailableTool? {
        manager.tools.first { $0.id == selectedToolID } ?? manager.tools.first
    }

    var body: some View {
        List {
            Section(NSLocalizedString("工具", comment: "")) {
                Picker(NSLocalizedString("工具", comment: ""), selection: selectedToolBinding) {
                    ForEach(manager.tools) { tool in
                        Text("\(tool.server.displayName) / \(tool.tool.toolId)")
                            .tag(Optional(tool.id))
                    }
                }
            }

            Section(NSLocalizedString("参数 JSON", comment: "")) {
                TextField("{}", text: $inputJSON.watchKeyboardNewlineBinding(), axis: .vertical)
                    .etFont(.system(.footnote, design: .monospaced))
            }

            Section {
                Button {
                    executeSelectedTool()
                } label: {
                    Label(NSLocalizedString("调用工具", comment: ""), systemImage: "play.circle")
                }
                .disabled(selectedTool == nil)
            }
        }
        .navigationTitle(NSLocalizedString("调用工具", comment: ""))
        .onAppear {
            if selectedToolID == nil {
                selectedToolID = manager.tools.first?.id
            }
        }
    }

    private var selectedToolBinding: Binding<String?> {
        Binding {
            selectedToolID ?? manager.tools.first?.id
        } set: { newValue in
            selectedToolID = newValue
        }
    }

    private func executeSelectedTool() {
        guard let tool = selectedTool else { return }
        let inputs = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(inputJSON.utf8))) ?? [:]
        manager.executeTool(on: tool.server.id, toolId: tool.tool.toolId, inputs: inputs)
    }
}

struct MCPResourceDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var selectedResourceID: String?
    @State private var queryJSON = "{}"

    private var selectedResource: MCPAvailableResource? {
        manager.resources.first { $0.id == selectedResourceID } ?? manager.resources.first
    }

    var body: some View {
        List {
            Section(NSLocalizedString("资源", comment: "")) {
                Picker(NSLocalizedString("资源", comment: ""), selection: selectedResourceBinding) {
                    ForEach(manager.resources) { resource in
                        Text("\(resource.server.displayName) / \(resource.resource.resourceId)")
                            .tag(Optional(resource.id))
                    }
                }
            }

            Section(NSLocalizedString("查询 JSON", comment: "")) {
                TextField("{}", text: $queryJSON.watchKeyboardNewlineBinding(), axis: .vertical)
                    .etFont(.system(.footnote, design: .monospaced))
            }

            Section {
                Button {
                    readSelectedResource()
                } label: {
                    Label(NSLocalizedString("读取资源", comment: ""), systemImage: "tray.and.arrow.down")
                }
                .disabled(selectedResource == nil)
            }
        }
        .navigationTitle(NSLocalizedString("读取资源", comment: ""))
        .onAppear {
            if selectedResourceID == nil {
                selectedResourceID = manager.resources.first?.id
            }
        }
    }

    private var selectedResourceBinding: Binding<String?> {
        Binding {
            selectedResourceID ?? manager.resources.first?.id
        } set: { newValue in
            selectedResourceID = newValue
        }
    }

    private func readSelectedResource() {
        guard let resource = selectedResource else { return }
        let query = try? JSONDecoder().decode([String: JSONValue].self, from: Data(queryJSON.utf8))
        manager.readResource(on: resource.server.id, resourceId: resource.resource.resourceId, query: query)
    }
}
