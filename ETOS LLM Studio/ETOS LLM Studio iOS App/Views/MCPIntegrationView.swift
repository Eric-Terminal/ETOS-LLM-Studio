// ============================================================================
// MCPIntegrationView.swift
// ============================================================================
// MCPIntegrationView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

//
//  MCPIntegrationView.swift
//  ETOS LLM Studio iOS App
//
//  创建一个用于管理 MCP Server 的交互界面。
//

import SwiftUI
import Foundation
import ETOSCore

private enum MCPIntegrationTab: String, CaseIterable, Identifiable {
    case servers
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers:
            return NSLocalizedString("服务器", comment: "")
        case .tools:
            return NSLocalizedString("工具", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .servers:
            return "server.rack"
        case .tools:
            return "hammer"
        }
    }
}

struct MCPIntegrationView: View {
    @StateObject var manager = MCPManager.shared
    @StateObject var toolPermissionCenter = ToolPermissionCenter.shared
    @State var isPresentingEditor = false
    @State var serverToEdit: MCPServerConfiguration?
    @State var isShowingIntroDetails = false
    @State private var selectedTab: MCPIntegrationTab = .servers
    
    var body: some View {
        TabView(selection: $selectedTab) {
            managementList
                .tabItem {
                    Label(MCPIntegrationTab.servers.title, systemImage: MCPIntegrationTab.servers.iconName)
                }
                .tag(MCPIntegrationTab.servers)

            publishedToolsList
                .tabItem {
                    Label(MCPIntegrationTab.tools.title, systemImage: MCPIntegrationTab.tools.iconName)
                }
                .tag(MCPIntegrationTab.tools)
        }
        .navigationTitle(NSLocalizedString("MCP 工具箱", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .servers {
                    Button {
                        serverToEdit = nil
                        isPresentingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { serverToEdit = nil }) {
            NavigationStack {
                MCPServerEditor(existingServer: serverToEdit) { server in
                    manager.save(server: server)
                }
            }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "mcp-toolbox",
                title: NSLocalizedString("MCP 工具箱", comment: "MCP 向导上下文标题"),
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
    }

    private func mcpGuideSnapshot() async -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "selected_tab": GuideSnapshotField(
                label: NSLocalizedString("当前标签页", comment: "MCP 向导快照字段"),
                value: .string(selectedTab.rawValue),
                access: .readOnly
            ),
            "chat_tools_enabled": GuideSnapshotField(
                label: NSLocalizedString("向模型暴露 MCP 工具", comment: "MCP 向导快照字段"),
                value: .bool(manager.chatToolsEnabled)
            ),
            "tool_call_title_enabled": GuideSnapshotField(
                label: NSLocalizedString("让 AI 描述 MCP 任务", comment: "MCP 向导快照字段"),
                value: .bool(manager.toolCallTitleEnabled)
            ),
            "server_count": GuideSnapshotField(
                label: NSLocalizedString("服务器数量", comment: "MCP 向导快照字段"),
                value: .int(manager.servers.count),
                access: .readOnly
            ),
            "published_tool_count": GuideSnapshotField(
                label: NSLocalizedString("可用工具数量", comment: "MCP 向导快照字段"),
                value: .int(manager.tools.count),
                access: .readOnly
            )
        ])
    }

    private func buildMCPGuideProposal(
        call: InternalToolCall,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        if call.toolName == GuideToolCatalog.createMCPServer.name {
            return try GuideMCPServerProposalSupport.buildProposal(call: call, pageID: "mcp-toolbox")
        }
        guard call.toolName == GuideToolCatalog.updateMCPPreferences.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let labels: [String: String] = [
            "chat_tools_enabled": NSLocalizedString("向模型暴露 MCP 工具", comment: "MCP 向导修改字段"),
            "tool_call_title_enabled": NSLocalizedString("让 AI 描述 MCP 任务", comment: "MCP 向导修改字段")
        ]
        try GuideToolArguments.requireOnlyKeys(Set(labels.keys), in: arguments)
        let mutations = try labels.compactMap { key, label -> GuideSettingMutation? in
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
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: "mcp-toolbox",
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("修改 MCP 工具箱偏好", comment: "MCP 向导提案摘要"),
            mutations: mutations,
            arguments: arguments
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
                    userInfo: [NSLocalizedDescriptionKey: manager.lastOperationError ?? NSLocalizedString("无法保存 MCP 服务器配置。", comment: "MCP 向导创建失败")]
                )
            }
            manager.connectSelectedServersIfNeeded()
            return GuideActionExecution(
                message: String(
                    format: NSLocalizedString("已创建 MCP 服务器“%@”。", comment: "MCP 向导创建执行结果"),
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
        let undoSnapshot = await mcpGuideSnapshot()
        let undoCall = InternalToolCall(
            id: UUID().uuidString,
            toolName: proposal.toolName,
            arguments: GuideToolArguments.encodedResult(.dictionary(oldArguments))
        )
        return GuideActionExecution(
            message: NSLocalizedString("已保存 MCP 工具箱偏好。", comment: "MCP 向导执行结果"),
            undoProposal: try buildMCPGuideProposal(call: undoCall, snapshot: undoSnapshot)
        )
    }

    private var managementList: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("MCP 工具箱", comment: "MCP toolbox intro title"),
                    summary: NSLocalizedString("统一管理 MCP Server 的连接、聊天暴露与能力调试。", comment: "MCP toolbox intro summary"),
                    details: NSLocalizedString("MCP 工具箱说明正文", comment: "MCP toolbox intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("向模型暴露 MCP 工具", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            } header: {
                Text(NSLocalizedString("聊天工具总开关", comment: ""))
            } footer: {
                Text(NSLocalizedString("关闭后不会再把任何 MCP 工具提供给模型，也不会响应聊天中的 MCP 工具调用。服务器连接、调试和单项配置仍可继续使用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            serverListSection
            connectionOverviewSection
            approvalAutomationSection
            activeToolCallsSection
            resourceSection
            promptSection
            logNavigationSection
            moreSection
        }
    }

    private var publishedToolsList: some View {
        List {
            publishedToolsSection

            Section {
                Toggle(
                    NSLocalizedString("让 AI 描述 MCP 任务", comment: "MCP tool call title setting"),
                    isOn: Binding(
                        get: { manager.toolCallTitleEnabled },
                        set: { manager.setToolCallTitleEnabled($0) }
                    )
                )
            } header: {
                Text(NSLocalizedString("工具调用标题", comment: "MCP tool call title section"))
            } footer: {
                Text(NSLocalizedString("开启后，模型会为每次 MCP 工具调用生成简短标题，并显示在聊天缩略图中。标题只供 ETOS 显示，不会发送给 MCP Server；关闭后继续使用原有的参数与结果预览。", comment: "MCP tool call title setting footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
