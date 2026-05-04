// ============================================================================
// ToolCenterDetailViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 工具中心页的 MCP、拓展工具与快捷指令详情视图。
// ============================================================================

import Foundation
import SwiftUI
import Shared

struct MCPToolCenterDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(tool.toolId)
                    .etFont(.headline)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.inputSchema, fieldLimit: 6) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .foregroundStyle(currentStatusColor)
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "Approval policy")),
                footer: Text(NSLocalizedString("默认每次询问，可在这里按工具单独调整。", comment: "Approval policy footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: "Approval policy"), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
    }

    private var currentStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        if !manager.isToolEnabled(serverID: serverID, toolId: tool.toolId) {
            return NSLocalizedString("已停用。", comment: "Tool disabled status")
        }
        if manager.approvalPolicy(serverID: serverID, toolId: tool.toolId) == .alwaysDeny {
            return NSLocalizedString("当前审批策略为始终拒绝，聊天时不会调用该工具。", comment: "Tool always deny status")
        }
        return NSLocalizedString("该工具当前可参与聊天。", comment: "Tool available in chat")
    }

    private var currentStatusColor: Color {
        if currentSessionIsolationActive
            || !manager.chatToolsEnabled
            || !manager.isToolEnabled(serverID: serverID, toolId: tool.toolId)
            || manager.approvalPolicy(serverID: serverID, toolId: tool.toolId) == .alwaysDeny {
            return .secondary
        }
        return .green
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

struct MCPToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let searchText: String
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
                let keywords = [
                    available.tool.toolId,
                    available.server.displayName,
                    available.tool.description ?? "",
                    available.internalName
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return manager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
                }
                return true
            }
    }

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(mcpToolGroupFooterText)
                    .etFont(.footnote)
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

            Section(
                header: Text(NSLocalizedString("MCP 工具", comment: "MCP tools section title"))
            ) {
                if filteredTools.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTools) { available in
                        NavigationLink {
                            MCPToolCenterDetailView(
                                serverID: available.server.id,
                                tool: available.tool,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            ToolCenterStatusRow(
                                title: available.tool.toolId,
                                subtitle: String(
                                    format: NSLocalizedString("来源：%@", comment: "Tool source format"),
                                    available.server.displayName
                                ),
                                detail: mcpStatusText(for: available),
                                auxiliary: ToolCatalogSupport.schemaSummary(for: available.tool.inputSchema, fieldLimit: 4),
                                color: mcpStatusColor(for: available)
                            )
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

    private func matchesSearch(for keywords: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return keywords.contains { keyword in
            keyword.localizedCaseInsensitiveContains(query)
        }
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

struct AppToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let searchText: String
    let showEnabledOnly: Bool

    @ObservedObject private var manager = AppToolManager.shared

    private var filteredTools: [AppToolCatalogItem] {
        manager.tools.filter { item in
            let keywords = [
                item.kind.displayName,
                item.kind.summary,
                item.kind.toolName
            ]
            guard matchesSearch(for: keywords) else { return false }
            if showEnabledOnly {
                return item.isEnabled
            }
            return true
        }
    }

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(appToolGroupFooterText)
                    .etFont(.footnote)
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

            Section(
                header: Text(NSLocalizedString("拓展工具", comment: "App tools section title"))
            ) {
                if filteredTools.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTools) { item in
                        NavigationLink {
                            AppToolCenterDetailView(
                                kind: item.kind,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            ToolCenterStatusRow(
                                title: item.kind.displayName,
                                subtitle: item.kind.toolName,
                                detail: appToolStatusText(for: item),
                                color: appToolStatusColor(for: item)
                            )
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

    private func matchesSearch(for keywords: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return keywords.contains { keyword in
            keyword.localizedCaseInsensitiveContains(query)
        }
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

struct AppToolCenterDetailView: View {
    let kind: AppToolKind
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = AppToolManager.shared
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(kind.displayName)
                    .etFont(.headline)
                Text(kind.detailDescription)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: kind.parameters, fieldLimit: 6) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .foregroundStyle(currentStatusColor)
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(
                    NSLocalizedString("启用", comment: "Enable"),
                    isOn: Binding(
                        get: { manager.isToolEnabled(kind) },
                        set: { manager.setToolEnabled(kind: kind, isEnabled: $0) }
                    )
                )
            }

            if kind.requiresApproval {
                Section(
                    header: Text(NSLocalizedString("审批策略", comment: "Approval policy")),
                    footer: Text(NSLocalizedString("默认每次询问，可在这里按工具单独调整。", comment: "Approval policy footer"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                ) {
                    Picker(NSLocalizedString("审批策略", comment: "Approval policy"), selection: toolApprovalPolicyBinding) {
                        ForEach(AppToolApprovalPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(
                    header: Text(NSLocalizedString("自动同意", comment: "Auto approve section title")),
                    footer: Text(NSLocalizedString("倒计时为全局设置，当前工具可单独关闭自动同意。", comment: "Auto approve section footer"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                ) {
                    Toggle(
                        NSLocalizedString("全局启用倒计时自动同意", comment: "Enable global auto approve"),
                        isOn: Binding(
                            get: { permissionCenter.autoApproveEnabled },
                            set: { permissionCenter.setAutoApproveEnabled($0) }
                        )
                    )

                    Stepper(
                        value: Binding(
                            get: { permissionCenter.autoApproveCountdownSeconds },
                            set: { permissionCenter.setAutoApproveCountdownSeconds($0) }
                        ),
                        in: 1...30
                    ) {
                        Text(
                            String(
                                format: NSLocalizedString("倒计时：%ds", comment: "Auto approve countdown value"),
                                permissionCenter.autoApproveCountdownSeconds
                            )
                        )
                    }
                    .disabled(!permissionCenter.autoApproveEnabled)

                    Toggle(
                        NSLocalizedString("允许该工具自动同意", comment: "Allow auto approve for this tool"),
                        isOn: autoApproveToolBinding
                    )
                    .disabled(!permissionCenter.autoApproveEnabled)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
    }

    private var currentStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        if !manager.isToolEnabled(kind) {
            return NSLocalizedString("已停用。", comment: "Tool disabled status")
        }
        if kind.requiresApproval && manager.approvalPolicy(for: kind) == .alwaysDeny {
            return NSLocalizedString("当前审批策略为始终拒绝，聊天时不会调用该工具。", comment: "Tool always deny status")
        }
        if !kind.requiresApproval {
            return NSLocalizedString("该工具为内置免审批工具，启用后可直接参与聊天。", comment: "No approval tool available status")
        }
        return NSLocalizedString("该工具当前可参与聊天。", comment: "Tool available in chat")
    }

    private var currentStatusColor: Color {
        let isUnavailableByApproval = kind.requiresApproval && manager.approvalPolicy(for: kind) == .alwaysDeny
        if currentSessionIsolationActive
            || !manager.chatToolsEnabled
            || !manager.isToolEnabled(kind)
            || isUnavailableByApproval {
            return .secondary
        }
        return .green
    }

    private var toolApprovalPolicyBinding: Binding<AppToolApprovalPolicy> {
        Binding {
            manager.approvalPolicy(for: kind)
        } set: { newValue in
            manager.setToolApprovalPolicy(kind: kind, policy: newValue)
        }
    }

    private var autoApproveToolBinding: Binding<Bool> {
        Binding {
            !permissionCenter.isAutoApproveDisabled(for: kind.toolName)
        } set: { isEnabled in
            permissionCenter.setAutoApproveDisabled(!isEnabled, for: kind.toolName)
        }
    }
}

struct ShortcutToolCenterDetailView: View {
    let toolID: UUID
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = ShortcutToolManager.shared
    @State private var isEditingDescription = false
    @State private var descriptionDraft = ""

    private var tool: ShortcutToolDefinition? {
        manager.tools.first(where: { $0.id == toolID })
    }

    var body: some View {
        List {
            if let tool {
                Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                    Text(tool.displayName)
                        .etFont(.headline)
                    Text(tool.name)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    if let importStatusText = importStatusText(for: tool) {
                        Text(importStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                    Text(currentStatusText(for: tool))
                        .foregroundStyle(currentStatusColor(for: tool))
                }

                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用", comment: "Enable"),
                        isOn: Binding(
                            get: { tool.isEnabled },
                            set: { manager.setToolEnabled(id: tool.id, isEnabled: $0) }
                        )
                    )
                }

                Section(NSLocalizedString("运行模式", comment: "Run mode section title")) {
                    Picker(
                        NSLocalizedString("运行模式", comment: "Run mode picker title"),
                        selection: Binding(
                            get: { tool.runModeHint },
                            set: { manager.setRunModeHint(id: tool.id, runModeHint: $0) }
                        )
                    ) {
                        Text(NSLocalizedString("直连优先", comment: "Shortcut run mode direct preferred"))
                            .tag(ShortcutRunModeHint.direct)
                        Text(NSLocalizedString("桥接优先", comment: "Shortcut run mode bridge preferred"))
                            .tag(ShortcutRunModeHint.bridge)
                    }
                    .pickerStyle(.segmented)
                    .tint(.blue)
                }

                Section(NSLocalizedString("工具描述", comment: "Tool description section")) {
                    Text(tool.effectiveDescription)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        descriptionDraft = tool.userDescription ?? ""
                        isEditingDescription = true
                    } label: {
                        Label(NSLocalizedString("编辑描述", comment: "Edit description"), systemImage: "square.and.pencil")
                    }

                    Button {
                        Task {
                            await manager.regenerateDescriptionWithLLM(for: tool.id)
                        }
                    } label: {
                        Label(NSLocalizedString("重新生成", comment: "Regenerate description"), systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Text(NSLocalizedString("快捷指令不存在或已被删除。", comment: "Shortcut tool missing"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
        .sheet(isPresented: $isEditingDescription) {
            if let tool {
                NavigationStack {
                    Form {
                        Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                            Text(tool.displayName)
                            Text(tool.name)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Section(NSLocalizedString("自定义描述", comment: "Custom description section")) {
                            TextEditor(text: $descriptionDraft)
                                .frame(minHeight: 180)
                        }
                    }
                    .navigationTitle(NSLocalizedString("编辑描述", comment: "Edit description"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(NSLocalizedString("取消", comment: "Cancel")) {
                                isEditingDescription = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("保存", comment: "Save")) {
                                manager.updateUserDescription(id: tool.id, description: descriptionDraft)
                                isEditingDescription = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func currentStatusText(for tool: ShortcutToolDefinition) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return tool.isEnabled
            ? NSLocalizedString("该工具当前可参与聊天。", comment: "Tool available in chat")
            : NSLocalizedString("已停用。", comment: "Tool disabled status")
    }

    private func currentStatusColor(for tool: ShortcutToolDefinition) -> Color {
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !tool.isEnabled {
            return .secondary
        }
        return .green
    }

    private func importStatusText(for tool: ShortcutToolDefinition) -> String? {
        guard let importMode = stringMetadata(of: tool, key: "importMode") else { return nil }
        if importMode == "light" {
            return NSLocalizedString("导入方式：轻度导入（仅名称）", comment: "")
        }
        if importMode == "deep" {
            let scanStatus = stringMetadata(of: tool, key: "scanStatus")
            if scanStatus == "parsed" {
                return NSLocalizedString("导入方式：深度导入（已解析流程）", comment: "")
            }
            return NSLocalizedString("导入方式：深度导入（仅链接，未解析）", comment: "")
        }
        return nil
    }

    private func stringMetadata(of tool: ShortcutToolDefinition, key: String) -> String? {
        guard let value = tool.metadata[key],
              case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
