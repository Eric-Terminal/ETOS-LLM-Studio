// ============================================================================
// MCPIntegrationView.swift
// ============================================================================
// MCPIntegrationView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

//
//  MCPIntegrationView.swift
//  ETOS LLM Studio Watch App
//

import SwiftUI
import Foundation
import ETOSCore

struct MCPIntegrationView: View {
    @StateObject private var manager = MCPManager.shared
    @StateObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var isShowingIntroDetails = false

    private var countdownNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var serversBinding: Binding<[MCPServerConfiguration]> {
        Binding {
            manager.servers
        } set: { orderedServers in
            manager.setServerOrder(orderedServers.map(\.id))
        }
    }

    @ViewBuilder
    private var autoApproveFooter: some View {
        if toolPermissionCenter.autoApproveEnabled {
            Text(NSLocalizedString("倒计时范围 1-30 秒，超出会自动修正。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("MCP 工具箱", comment: "MCP toolbox intro title"),
                    summary: NSLocalizedString("在手表端查看服务器状态、工具能力和治理日志。", comment: "Watch MCP toolbox intro summary"),
                    details: NSLocalizedString("MCP 工具箱说明正文", comment: "MCP toolbox intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("聊天工具总开关", comment: "")),
                footer: Text(NSLocalizedString("关闭后不会向模型暴露任何 MCP 工具，但你仍可继续管理服务器和查看日志。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("向模型暴露 MCP 工具", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section(NSLocalizedString("服务器管理", comment: "")) {
                if manager.servers.isEmpty {
                    Text(NSLocalizedString("尚未添加服务器，点击下方入口新建。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(serversBinding, id: \.id, editActions: .move) { $server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            serverSelectionRow(for: server)
                        }
                    }
                }

                NavigationLink {
                    MCPServerEditor(existingServer: nil) {
                        manager.save(server: $0)
                    }
                } label: {
                    Label(NSLocalizedString("新增 MCP Server", comment: ""), systemImage: "plus.circle")
                }
            }

            Section(NSLocalizedString("连接状态", comment: "")) {
                let connected = manager.connectedServers().count
                let selected = manager.selectedServers().count
                Text(
                    String(
                        format: NSLocalizedString("已连接 %d 台，聊天使用 %d 台。", comment: ""),
                        connected,
                        selected
                    )
                )
                    .etFont(.caption2)
                Button(NSLocalizedString("刷新", comment: "")) {
                    manager.refreshMetadata()
                }
                .disabled(manager.isBusy || connected == 0)

                if manager.isBusy {
                    ProgressView(NSLocalizedString("同步中…", comment: ""))
                }
            }

            Section(
                header: Text(NSLocalizedString("审批自动化", comment: "")),
                footer: autoApproveFooter
            ) {
                Toggle(NSLocalizedString("自动批准", comment: ""),
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )

                if toolPermissionCenter.autoApproveEnabled {
                    HStack {
                        Text(NSLocalizedString("倒计时秒数", comment: ""))
                        Spacer()
                        TextField(NSLocalizedString("数量", comment: ""),
                            value: Binding(
                                get: { toolPermissionCenter.autoApproveCountdownSeconds },
                                set: { toolPermissionCenter.setAutoApproveCountdownSeconds($0) }
                            ),
                            formatter: countdownNumberFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    }
                }
            }

            Section(NSLocalizedString("治理日志", comment: "")) {
                NavigationLink {
                    MCPGovernanceLogListView()
                } label: {
                    HStack {
                        Label(NSLocalizedString("查看治理日志", comment: ""), systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text("\(manager.governanceLogEntries.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(manager.governanceLogEntries.isEmpty)
            }

            Section(NSLocalizedString("能力概览", comment: "")) {
                HStack {
                    Label(
                        String(format: NSLocalizedString("工具 %d", comment: ""), manager.tools.count),
                        systemImage: "hammer"
                    )
                    Spacer()
                    NavigationLink(NSLocalizedString("查看列表", comment: "")) {
                        MCPToolListView()
                    }
                    .disabled(manager.tools.isEmpty)
                }
                HStack {
                    Label(
                        String(format: NSLocalizedString("资源 %d", comment: ""), manager.resources.count),
                        systemImage: "doc.plaintext"
                    )
                    Spacer()
                    NavigationLink(NSLocalizedString("查看列表", comment: "")) {
                        MCPResourceListView()
                    }
                    .disabled(manager.resources.isEmpty)
                }
            }

            if !manager.activeToolCalls.isEmpty {
                Section(NSLocalizedString("活跃调用", comment: "")) {
                    ForEach(manager.activeToolCalls.values.sorted(by: { $0.startedAt > $1.startedAt }), id: \.id) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(call.serverDisplayName) · \(call.toolId)")
                                .etFont(.footnote)
                            if let progress = call.latestProgress, let total = call.latestTotal, total > 0 {
                                ProgressView(value: min(max(progress / total, 0), 1))
                            }
                            Button(NSLocalizedString("取消", comment: ""), role: .destructive) {
                                manager.cancelToolCall(callID: call.id, reason: NSLocalizedString("用户在手表取消调用", comment: ""))
                            }
                            .etFont(.caption2)
                        }
                    }
                }
            }

            moreSection
        }
        .navigationTitle(NSLocalizedString("MCP", comment: "MCP navigation title"))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "watch-mcp-toolbox",
                title: NSLocalizedString("MCP 工具箱", comment: "手表 MCP 向导上下文标题"),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
                tools: [
                    GuidePageTool(definition: GuideToolCatalog.updateMCPPreferences, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.createMCPServer, access: .proposeChange)
                ]
            ),
            snapshot: mcpGuideSnapshot,
            buildProposal: buildMCPGuideProposal,
            execute: executeMCPGuideProposal
        )
        .watchGuideEntry()
    }

    private func mcpGuideSnapshot() async -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "chat_tools_enabled": GuideSnapshotField(label: NSLocalizedString("向模型暴露 MCP 工具", comment: "手表 MCP 向导快照字段"), value: .bool(manager.chatToolsEnabled)),
            "tool_call_title_enabled": GuideSnapshotField(label: NSLocalizedString("让 AI 描述 MCP 任务", comment: "手表 MCP 向导快照字段"), value: .bool(manager.toolCallTitleEnabled)),
            "server_order": GuideSnapshotField(
                label: NSLocalizedString("服务器顺序", comment: "手表 MCP 向导快照字段"),
                value: GuideOrderedSettingsSupport.identifierOrderValue(
                    manager.servers.map { $0.id.uuidString.lowercased() }
                )
            ),
            "servers": GuideSnapshotField(
                label: NSLocalizedString("已配置服务器", comment: "手表 MCP 向导快照字段"),
                value: .array(manager.servers.map { server in
                    let status = manager.status(for: server)
                    return .dictionary([
                        "id": .string(server.id.uuidString.lowercased()),
                        "name": .string(server.displayName),
                        "transport": .string(mcpGuideTransportName(server.transport)),
                        "endpoint": .string(server.humanReadableEndpoint),
                        "selected_for_chat": .bool(server.isSelectedForChat),
                        "connection_state": .string(mcpGuideConnectionState(status.connectionState)),
                        "tool_count": .int(status.tools.count),
                        "resource_count": .int(status.resources.count)
                    ])
                }),
                access: .readOnly
            ),
            "published_tools": GuideSnapshotField(
                label: NSLocalizedString("已公布工具", comment: "手表 MCP 向导快照字段"),
                value: .array(manager.tools.map { available in
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
                }),
                access: .readOnly
            ),
            "server_count": GuideSnapshotField(label: NSLocalizedString("服务器数量", comment: "手表 MCP 向导快照字段"), value: .int(manager.servers.count), access: .readOnly),
            "published_tool_count": GuideSnapshotField(label: NSLocalizedString("可用工具数量", comment: "手表 MCP 向导快照字段"), value: .int(manager.tools.count), access: .readOnly)
        ])
    }

    private func buildMCPGuideProposal(
        call: InternalToolCall,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        if call.toolName == GuideToolCatalog.createMCPServer.name {
            return try GuideMCPServerProposalSupport.buildProposal(call: call, pageID: "watch-mcp-toolbox")
        }
        guard call.toolName == GuideToolCatalog.updateMCPPreferences.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        var normalizedArguments = arguments
        let labels: [String: String] = [
            "chat_tools_enabled": NSLocalizedString("向模型暴露 MCP 工具", comment: "手表 MCP 向导修改字段"),
            "tool_call_title_enabled": NSLocalizedString("让 AI 描述 MCP 任务", comment: "手表 MCP 向导修改字段")
        ]
        try GuideToolArguments.requireOnlyKeys(Set(labels.keys).union(["server_order"]), in: arguments)
        var mutations = try labels.compactMap { key, label -> GuideSettingMutation? in
            guard let value = try GuideToolArguments.optionalBool(key, in: arguments) else { return nil }
            let newValue = JSONValue.bool(value)
            guard snapshot.fields[key]?.value != newValue else { return nil }
            return GuideSettingMutation(
                path: key,
                label: label,
                oldValue: snapshot.fields[key]?.value,
                newValue: newValue
            )
        }
        if let orderValue = arguments["server_order"] {
            let normalized = try GuideOrderedSettingsSupport.normalizeIdentifierOrder(
                orderValue,
                currentIdentifiers: manager.servers.map { $0.id.uuidString.lowercased() }
            )
            normalizedArguments["server_order"] = normalized
            if snapshot.fields["server_order"]?.value != normalized {
                mutations.append(GuideSettingMutation(
                    path: "server_order",
                    label: NSLocalizedString("服务器顺序", comment: "手表 MCP 向导修改字段"),
                    oldValue: snapshot.fields["server_order"]?.value,
                    newValue: normalized
                ))
            }
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: "watch-mcp-toolbox",
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("修改 MCP 工具箱偏好", comment: "手表 MCP 向导提案摘要"),
            mutations: mutations,
            arguments: normalizedArguments
        )
    }

    private func executeMCPGuideProposal(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        if proposal.toolName == GuideToolCatalog.createMCPServer.name {
            let decoded = try GuideMCPServerProposalSupport.decode(proposal.arguments)
            manager.save(server: decoded.server)
            guard manager.servers.contains(where: { $0.id == decoded.server.id }) else {
                throw NSError(
                    domain: "GuideMCPServerCreation",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: manager.lastOperationError ?? NSLocalizedString("无法保存 MCP 服务器配置。", comment: "手表 MCP 向导创建失败")]
                )
            }
            manager.connectSelectedServersIfNeeded()
            return GuideActionExecution(
                message: String(
                    format: NSLocalizedString("已创建 MCP 服务器“%@”。", comment: "手表 MCP 向导创建执行结果"),
                    decoded.server.displayName
                )
            )
        }
        guard proposal.toolName == GuideToolCatalog.updateMCPPreferences.name else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        var oldArguments: [String: JSONValue] = [:]
        if let value = try GuideToolArguments.optionalBool("chat_tools_enabled", in: proposal.arguments) {
            oldArguments["chat_tools_enabled"] = .bool(manager.chatToolsEnabled)
            manager.setChatToolsEnabled(value)
        }
        if let value = try GuideToolArguments.optionalBool("tool_call_title_enabled", in: proposal.arguments) {
            oldArguments["tool_call_title_enabled"] = .bool(manager.toolCallTitleEnabled)
            manager.setToolCallTitleEnabled(value)
        }
        if let orderValue = proposal.arguments["server_order"] {
            let oldIdentifiers = manager.servers.map { $0.id.uuidString.lowercased() }
            oldArguments["server_order"] = GuideOrderedSettingsSupport.identifierOrderValue(oldIdentifiers)
            let identifiers = try GuideOrderedSettingsSupport.identifierOrder(
                from: orderValue,
                currentIdentifiers: oldIdentifiers
            )
            manager.setServerOrder(try identifiers.map { identifier in
                guard let id = UUID(uuidString: identifier) else { throw GuideError.invalidToolArguments }
                return id
            })
        }
        let undoSnapshot = await mcpGuideSnapshot()
        let undoCall = InternalToolCall(
            id: UUID().uuidString,
            toolName: proposal.toolName,
            arguments: GuideToolArguments.encodedResult(.dictionary(oldArguments))
        )
        return GuideActionExecution(
            message: NSLocalizedString("已保存 MCP 工具箱偏好。", comment: "手表 MCP 向导执行结果"),
            undoProposal: try buildMCPGuideProposal(call: undoCall, snapshot: undoSnapshot)
        )
    }

    private func mcpGuideTransportName(_ transport: MCPServerConfiguration.Transport) -> String {
        switch transport {
        case .http: return "http"
        case .httpSSE: return "sse"
        case .localStdio: return "stdio"
        case .oauth: return "oauth"
        case .builtInSearch: return "built_in_search"
        case .builtInAppTool: return "built_in_app_tool"
        case .builtInPersonalData: return "built_in_personal_data"
        }
    }

    private func mcpGuideConnectionState(_ state: MCPManager.ConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .ready: return "ready"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private func serverSelectionRow(for server: MCPServerConfiguration) -> some View {
        let isSelectedForChat = manager.status(for: server).isSelectedForChat

        return HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .opacity(isSelectedForChat ? 1 : 0)
                .accessibilityHidden(true)

            Text(server.displayName)
                .etFont(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            isSelectedForChat
                ? Text(NSLocalizedString("已选中用于聊天", comment: "MCP server selected for chat accessibility value"))
                : Text("")
        )
    }

    @ViewBuilder
    private var moreSection: some View {
        Section(NSLocalizedString("更多", comment: "")) {
            NavigationLink {
                MCPConfigurationTransferWatchView()
            } label: {
                Label(NSLocalizedString("导入与导出配置", comment: "MCP configuration transfer link"), systemImage: "arrow.up.arrow.down.square")
            }

            if !manager.restorableBuiltInServers.isEmpty {
                NavigationLink {
                    MCPBuiltInServerRestoreView()
                } label: {
                    Label(NSLocalizedString("内置工具", comment: "Built-in tools section title"), systemImage: "shippingbox.and.arrow.backward")
                }
            }
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "MCP 介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "MCP 介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "MCP 介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

}
