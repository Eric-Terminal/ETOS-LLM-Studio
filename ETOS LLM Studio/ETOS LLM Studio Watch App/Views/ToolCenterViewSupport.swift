// ============================================================================
// ToolCenterViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 工具中心页的分类视图与详情视图支撑文件。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct WatchAppToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let showEnabledOnly: Bool

    @ObservedObject private var manager = AppToolManager.shared

    private var categoryStates: [AppToolCatalogCategoryState] {
        ToolCatalogSupport.appToolCategoryStates(
            tools: manager.tools,
            chatToolsEnabled: manager.chatToolsEnabled,
            isIsolatedSession: currentSessionIsolationActive
        ) { kind in
            manager.approvalPolicy(for: kind)
        }
    }

    private var filteredCategoryStates: [AppToolCatalogCategoryState] {
        categoryStates.filter { state in
            showEnabledOnly ? state.configuredEnabledCount > 0 : true
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("拓展工具", comment: "App tools section title"))
                    Text(NSLocalizedString("先按用途选择分类，再进入具体工具。", comment: "App tools grouped watch intro"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(appToolGroupFooterText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露拓展工具", comment: "Expose app tools to model"),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section(header: Text(NSLocalizedString("工具分类", comment: "App tool categories section title"))) {
                if filteredCategoryStates.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredCategoryStates) { state in
                        NavigationLink {
                            WatchAppToolCategoryToolsView(
                                category: state.category,
                                currentSessionIsolationActive: currentSessionIsolationActive,
                                showEnabledOnly: showEnabledOnly
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.category.displayName)
                                Text(state.category.summary)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(categoryStatusText(for: state))
                                    .etFont(.caption2)
                                    .foregroundStyle(categoryStatusColor(for: state))
                                Text(
                                    String(
                                        format: NSLocalizedString("工具 %d 个", comment: "Tool count"),
                                        state.totalCount
                                    )
                                )
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("拓展工具", comment: "App tools section title"))
    }

    private var appToolGroupFooterText: String {
        var lines = [NSLocalizedString("这里用于承接后续要给 AI 写的本地工具，默认关闭，开启后才会暴露给模型。", comment: "App tools intro")]
        if !manager.chatToolsEnabled {
            lines.append(NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation"))
        }
        return lines.joined(separator: "\n\n")
    }

    private func categoryStatusText(for state: AppToolCatalogCategoryState) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            state.availableCount,
            state.totalCount
        )
    }

    private func categoryStatusColor(for state: AppToolCatalogCategoryState) -> Color {
        if currentSessionIsolationActive || !manager.chatToolsEnabled || state.availableCount == 0 {
            return .secondary
        }
        return .green
    }
}

struct WatchAppToolCategoryToolsView: View {
    let category: AppToolCatalogCategory
    let currentSessionIsolationActive: Bool
    let showEnabledOnly: Bool

    @ObservedObject private var manager = AppToolManager.shared

    private var filteredTools: [AppToolCatalogItem] {
        manager.tools.filter { item in
            guard ToolCatalogSupport.appToolCategory(for: item.kind) == category else { return false }
            if showEnabledOnly {
                return item.isEnabled
            }
            return true
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.displayName)
                    Text(category.detailDescription)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text(NSLocalizedString("工具", comment: "Tools section title"))) {
                if filteredTools.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTools) { item in
                        NavigationLink {
                            WatchAppToolCenterDetailView(
                                kind: item.kind,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.kind.displayName)
                                Text(item.kind.toolName)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(appToolStatusText(for: item))
                                    .etFont(.caption2)
                                    .foregroundStyle(appToolStatusColor(for: item))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(category.displayName)
    }

    private func appToolStatusText(for item: AppToolCatalogItem) -> String {
        let policy = manager.approvalPolicy(for: item.kind)
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        if !item.isEnabled {
            return NSLocalizedString("当前未启用该拓展工具。", comment: "App tool disabled status")
        }
        if !item.kind.requiresApproval {
            return NSLocalizedString("内置免审批，启用后可直接调用。", comment: "No approval required status for built-in-like app tool")
        }
        if policy == .alwaysDeny {
            return NSLocalizedString("当前审批策略为始终拒绝，聊天时不会调用该工具。", comment: "Tool always deny status")
        }
        return policy.displayName
    }

    private func appToolStatusColor(for item: AppToolCatalogItem) -> Color {
        let policy = manager.approvalPolicy(for: item.kind)
        let isUnavailableByApproval = item.kind.requiresApproval && policy == .alwaysDeny
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !item.isEnabled || isUnavailableByApproval {
            return .secondary
        }
        return .green
    }
}

struct WatchMCPToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let showEnabledOnly: Bool

    @ObservedObject private var manager = MCPManager.shared

    private var catalogTools: [MCPAvailableTool] {
        ToolCatalogSupport.mcpCatalogTools(
            servers: manager.servers,
            statuses: manager.serverStatuses
        )
    }

    private var filteredTools: [MCPAvailableTool] {
        ToolCatalogSupport.sortedMCPCatalogTools(catalogTools)
            .filter { available in
                showEnabledOnly
                    ? manager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
                    : true
            }
    }

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(mcpToolGroupFooterText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露 MCP 工具", comment: "Expose MCP tools to model"),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section(header: Text(NSLocalizedString("MCP 工具", comment: "MCP tools section title"))) {
                if filteredTools.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTools) { available in
                        NavigationLink {
                            WatchMCPToolCenterDetailView(
                                serverID: available.server.id,
                                tool: available.tool,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(available.tool.toolId)
                                Text(available.server.displayName)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(mcpStatusText(for: available))
                                    .etFont(.caption2)
                                    .foregroundStyle(mcpStatusColor(for: available))
                                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: available.tool.inputSchema, fieldLimit: 4) {
                                    Text(schemaSummary)
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("MCP 工具", comment: "MCP tools section title"))
    }

    private var mcpToolGroupFooterText: String {
        var lines = [NSLocalizedString("统一查看各个 MCP Server 公布的聊天工具，并集中调整启用状态与审批策略。", comment: "MCP tools footer")]
        if !manager.chatToolsEnabled {
            lines.append(NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation"))
        }
        return lines.joined(separator: "\n\n")
    }

    private func mcpStatusText(for available: MCPAvailableTool) -> String {
        let isEnabled = manager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
        let policy = manager.approvalPolicy(serverID: available.server.id, toolId: available.tool.toolId)

        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        if !isEnabled {
            return NSLocalizedString("已停用。", comment: "Tool disabled status")
        }
        if policy == .alwaysDeny {
            return NSLocalizedString("当前审批策略为始终拒绝，聊天时不会调用该工具。", comment: "Tool always deny status")
        }
        return policy.displayName
    }

    private func mcpStatusColor(for available: MCPAvailableTool) -> Color {
        let isEnabled = manager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
        let policy = manager.approvalPolicy(serverID: available.server.id, toolId: available.tool.toolId)
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !isEnabled || policy == .alwaysDeny {
            return .secondary
        }
        return .green
    }
}

// 详情视图已拆分到 `ToolCenterDetailViews.swift`。
