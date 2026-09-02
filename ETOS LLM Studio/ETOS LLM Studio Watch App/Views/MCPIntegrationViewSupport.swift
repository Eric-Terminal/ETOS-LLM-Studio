// ============================================================================
// MCPIntegrationViewSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App MCP 工具箱辅助视图
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

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
                    LabeledContent(NSLocalizedString("Endpoint", comment: "MCP endpoint label"), value: server.humanReadableEndpoint)
                    if let notes = server.notes {
                        LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                    }
                    Text(statusDescription(for: server))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("连接控制", comment: "")) {
                    Button(connectionActionTitle(for: status.connectionState)) {
                        performConnectionAction(for: status.connectionState, server: server)
                    }

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
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: guidePageID,
                title: server?.displayName ?? NSLocalizedString("服务器详情", comment: ""),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
                tools: [
                    GuidePageTool(definition: GuideToolCatalog.updateMCPServer, access: .proposeChange)
                ]
            ),
            snapshot: {
                guard let server else { return .empty }
                return GuideMCPServerSettingsSupport.snapshot(
                    server: server,
                    status: manager.status(for: server)
                )
            },
            buildProposal: { call, _ in
                guard let server else { throw GuideError.invalidToolArguments }
                return try GuideMCPServerSettingsSupport.buildProposal(
                    call: call,
                    pageID: guidePageID,
                    server: server
                )
            },
            execute: { proposal in
                guard let server else { throw GuideError.invalidToolArguments }
                let application = try GuideMCPServerSettingsSupport.apply(proposal, to: server)
                manager.save(server: application.server)
                manager.connectSelectedServersIfNeeded()
                return application.execution
            }
        )
        .watchGuideEntry()
    }

    private var guidePageID: GuidePageID {
        GuidePageID(rawValue: "mcp-server-\(serverID.uuidString.lowercased())")
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

    private func connectionActionTitle(for state: MCPManager.ConnectionState) -> String {
        isConnectedOrConnecting(state)
            ? NSLocalizedString("断开连接", comment: "")
            : NSLocalizedString("连接", comment: "")
    }

    private func performConnectionAction(for state: MCPManager.ConnectionState, server: MCPServerConfiguration) {
        if isConnectedOrConnecting(state) {
            manager.disconnect(server: server)
        } else {
            manager.connect(to: server)
        }
    }

    private func isConnectedOrConnecting(_ state: MCPManager.ConnectionState) -> Bool {
        switch state {
        case .connecting, .reconnecting, .ready:
            return true
        case .idle, .failed:
            return false
        @unknown default:
            return false
        }
    }
}

struct MCPBuiltInServerRestoreView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("内置工具", comment: "Built-in tools section title")) {
                if manager.restorableBuiltInServers.isEmpty {
                    Text(NSLocalizedString("所有内置 MCP 服务器都已添加。", comment: "All built-in MCP servers restored"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.restorableBuiltInServers) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayName)
                                .etFont(.headline)
                            if let notes = item.notes, !notes.isEmpty {
                                Text(notes)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button(NSLocalizedString("恢复", comment: "")) {
                                manager.restoreBuiltInServer(id: item.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
        .guideSettingsPageContext(
            id: "watch-mcp-built-in-server-restore",
            title: NSLocalizedString("内置工具", comment: "手表内置 MCP 恢复向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: [
                .readOnly(
                    "restorable_servers",
                    label: NSLocalizedString("可恢复的内置服务器", comment: "手表内置 MCP 恢复向导字段"),
                    value: {
                        .array(manager.restorableBuiltInServers.map { server in
                            .dictionary([
                                "id": .string(server.id.uuidString.lowercased()),
                                "name": .string(server.displayName),
                                "notes": .string(server.notes ?? "")
                            ])
                        })
                    }
                )
            ]
        )
        .watchGuideEntry()
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
                    Text(String(format: NSLocalizedString("输入 Schema：%@", comment: ""), schemaSummary))
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: guidePageID,
                title: String(
                    format: NSLocalizedString("MCP 工具：%@", comment: "MCP 工具向导上下文标题"),
                    tool.toolId
                ),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
                tools: [
                    GuidePageTool(definition: GuideToolCatalog.updateMCPTool, access: .proposeChange)
                ]
            ),
            snapshot: {
                guard let server = currentServer else { return .empty }
                return GuideMCPToolSettingsSupport.snapshot(server: server, tool: tool)
            },
            buildProposal: { call, _ in
                guard let server = currentServer else { throw GuideError.invalidToolArguments }
                return try GuideMCPToolSettingsSupport.buildProposal(
                    call: call,
                    pageID: guidePageID,
                    server: server,
                    tool: tool
                )
            },
            execute: { proposal in
                guard let server = currentServer else { throw GuideError.invalidToolArguments }
                let application = try GuideMCPToolSettingsSupport.apply(
                    proposal,
                    server: server,
                    tool: tool
                )
                manager.setToolEnabled(
                    serverID: serverID,
                    toolId: tool.toolId,
                    isEnabled: application.enabled
                )
                manager.setToolApprovalPolicy(
                    serverID: serverID,
                    toolId: tool.toolId,
                    policy: application.approvalPolicy
                )
                return application.execution
            }
        )
        .watchGuideEntry()
    }

    private var guidePageID: GuidePageID {
        GuidePageID(rawValue: "mcp-tool-\(serverID.uuidString.lowercased())-\(tool.toolId)")
    }

    private var currentServer: MCPServerConfiguration? {
        manager.servers.first(where: { $0.id == serverID })
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
                    NavigationLink {
                        MCPToolSettingsDetailView(serverID: tool.server.id, tool: tool.tool)
                    } label: {
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
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(
                header: Text(NSLocalizedString("工具调用标题", comment: "MCP tool call title section")),
                footer: Text(NSLocalizedString("开启后，模型会为每次 MCP 工具调用生成简短标题，并显示在聊天缩略图中。标题只供 ETOS 显示，不会发送给 MCP Server；关闭后继续使用原有的参数与结果预览。", comment: "MCP tool call title setting footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("让 AI 描述 MCP 任务", comment: "MCP tool call title setting"),
                    isOn: Binding(
                        get: { manager.toolCallTitleEnabled },
                        set: { manager.setToolCallTitleEnabled($0) }
                    )
                )
            }
        }
        .navigationTitle(NSLocalizedString("工具列表", comment: ""))
        .guideSettingsPageContext(
            id: "watch-mcp-tool-list",
            title: NSLocalizedString("工具列表", comment: "手表 MCP 工具列表向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: mcpToolListGuideSettings
        )
        .watchGuideEntry()
    }

    private var mcpToolListGuideSettings: [GuidePageSetting] {
        [
            .bool(
                "tool_call_title_enabled",
                label: NSLocalizedString("让 AI 描述 MCP 任务", comment: "手表 MCP 工具列表向导字段"),
                get: { manager.toolCallTitleEnabled },
                set: { manager.setToolCallTitleEnabled($0) }
            ),
            .readOnly(
                "chat_tools_enabled",
                label: NSLocalizedString("向模型暴露 MCP 工具", comment: "手表 MCP 工具列表向导字段"),
                value: { .bool(manager.chatToolsEnabled) }
            ),
            .readOnly(
                "tools",
                label: NSLocalizedString("已公布工具", comment: "手表 MCP 工具列表向导字段"),
                value: {
                    .array(manager.tools.map { available in
                        .dictionary([
                            "server_id": .string(available.server.id.uuidString.lowercased()),
                            "server_name": .string(available.server.displayName),
                            "tool_id": .string(available.tool.toolId),
                            "description": .string(available.tool.description ?? ""),
                            "enabled": .bool(manager.isToolEnabled(
                                serverID: available.server.id,
                                toolId: available.tool.toolId
                            )),
                            "approval_policy": .string(manager.approvalPolicy(
                                serverID: available.server.id,
                                toolId: available.tool.toolId
                            ).rawValue)
                        ])
                    })
                }
            )
        ]
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
        .guideSettingsPageContext(
            id: "watch-mcp-resource-list",
            title: NSLocalizedString("资源列表", comment: "手表 MCP 资源列表向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: [
                .readOnly(
                    "resources",
                    label: NSLocalizedString("可用资源", comment: "手表 MCP 资源列表向导字段"),
                    value: {
                        .array(manager.resources.map { available in
                            .dictionary([
                                "server_id": .string(available.server.id.uuidString.lowercased()),
                                "server_name": .string(available.server.displayName),
                                "resource_id": .string(available.resource.resourceId),
                                "description": .string(available.resource.description ?? "")
                            ])
                        })
                    }
                )
            ]
        )
        .watchGuideEntry()
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
        .guideSettingsPageContext(
            id: "watch-mcp-governance-log",
            title: NSLocalizedString("治理日志", comment: "手表 MCP 治理日志向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: [
                .readOnly(
                    "entries",
                    label: NSLocalizedString("治理日志记录", comment: "手表 MCP 治理日志向导字段"),
                    value: {
                        .array(manager.governanceLogEntries.suffix(80).map { entry in
                            .dictionary([
                                "timestamp": .double(entry.timestamp.timeIntervalSince1970),
                                "level": .string(entry.level.rawValue),
                                "category": .string(entry.category.rawValue),
                                "server_name": .string(entry.serverDisplayName ?? ""),
                                "message": .string(entry.message)
                            ])
                        })
                    }
                )
            ]
        )
        .watchGuideEntry()
    }
}
