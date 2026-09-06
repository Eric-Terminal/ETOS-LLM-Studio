// ============================================================================
// ToolCenterDetailViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 工具中心页的 MCP、拓展工具与快捷指令详情视图。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

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
                    Text(
                        String(
                            format: NSLocalizedString("参数结构：%@", comment: "Tool schema summary"),
                            schemaSummary
                        )
                    )
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
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: guidePageID,
                title: String(format: NSLocalizedString("MCP 工具：%@", comment: "MCP 工具向导上下文标题"), tool.toolId),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateMCPTool, access: .proposeChange)]
            ),
            snapshot: {
                guard let server = currentServer else { return .empty }
                return GuideMCPToolSettingsSupport.snapshot(server: server, tool: tool)
            },
            buildProposal: { call, _ in
                guard let server = currentServer else { throw GuideError.invalidToolArguments }
                return try GuideMCPToolSettingsSupport.buildProposal(call: call, pageID: guidePageID, server: server, tool: tool)
            },
            execute: { proposal in
                guard let server = currentServer else { throw GuideError.invalidToolArguments }
                let application = try GuideMCPToolSettingsSupport.apply(proposal, server: server, tool: tool)
                manager.setToolEnabled(serverID: serverID, toolId: tool.toolId, isEnabled: application.enabled)
                manager.setToolApprovalPolicy(serverID: serverID, toolId: tool.toolId, policy: application.approvalPolicy)
                return application.execution
            }
        )
    }

    private var currentServer: MCPServerConfiguration? {
        manager.servers.first(where: { $0.id == serverID })
    }

    private var guidePageID: GuidePageID {
        GuidePageID(rawValue: "tool-center-mcp-tool-\(serverID.uuidString.lowercased())-\(tool.toolId)")
    }

    private var currentStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "Tool unavailable due to session isolation")
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
    let currentSessionMemoryIsolationActive: Bool
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
                                currentSessionIsolationActive: isBlockedBySessionPolicy(available)
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
        .guideSettingsPageContext(
            id: "tool-center-mcp-tools",
            title: NSLocalizedString("MCP 工具", comment: "MCP 工具向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: [
                .bool("chat_tools_enabled", label: NSLocalizedString("向模型暴露 MCP 工具", comment: "向导设置字段"), get: { manager.chatToolsEnabled }, set: { manager.setChatToolsEnabled($0) }),
                .readOnly("current_session_isolation_active", label: NSLocalizedString("当前会话屏蔽工具上下文", comment: "向导设置字段"), value: { .bool(currentSessionIsolationActive) }),
                .readOnly("current_session_memory_isolation_active", label: NSLocalizedString("当前会话屏蔽记忆上下文", comment: "向导设置字段"), value: { .bool(currentSessionMemoryIsolationActive) }),
                .readOnly("visible_tools", label: NSLocalizedString("MCP 工具", comment: "向导设置字段"), value: {
                    .array(filteredTools.map { available in
                        .dictionary([
                            "server_id": .string(available.server.id.uuidString),
                            "server_name": .string(available.server.displayName),
                            "tool_id": .string(available.tool.toolId),
                            "description": .string(available.tool.description ?? ""),
                            "enabled": .bool(manager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)),
                            "approval_policy": .string(manager.approvalPolicy(serverID: available.server.id, toolId: available.tool.toolId).rawValue),
                            "blocked_by_session": .bool(isBlockedBySessionPolicy(available))
                        ])
                    })
                })
            ]
        )
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

        if isBlockedBySessionPolicy(available) {
            return NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "Tool unavailable due to session isolation")
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
        if isBlockedBySessionPolicy(available) || !manager.chatToolsEnabled || !isEnabled || policy == .alwaysDeny {
            return .secondary
        }
        return .green
    }

    private func isBlockedBySessionPolicy(_ available: MCPAvailableTool) -> Bool {
        currentSessionIsolationActive
            || (currentSessionMemoryIsolationActive
                && MCPBuiltInAppToolServer.category(for: available.server.id) == .memory)
    }
}

struct SkillToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let searchText: String
    let showEnabledOnly: Bool

    @ObservedObject private var manager = SkillManager.shared
    @State private var isShowingIntroDetails = false

    private var filteredSkills: [SkillMetadata] {
        manager.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { skill in
                let matchesSkill = matchesSearch(
                    for: [
                        skill.name,
                        skill.description,
                        skill.compatibility ?? "",
                        "Agent Skills",
                        "use_skill"
                    ]
                )
                guard matchesSkill else { return false }
                if showEnabledOnly {
                    return manager.isSkillEnabled(skill.name)
                }
                return true
            }
    }

    var body: some View {
        List {
            Section {
                ToolCenterIntroCard(
                    title: "Agent Skills",
                    summary: "把已安装技能通过 use_skill 暴露给模型。",
                    details: "Agent Skills 工具说明正文",
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(skillGroupFooterText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("向模型暴露 Agent Skills（use_skill）", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section(header: Text(NSLocalizedString("技能", comment: "Skills section title"))) {
                if manager.skills.isEmpty {
                    Text(NSLocalizedString("当前还没有已安装技能，可在设置里的 Agent Skills 页面添加。", comment: "没有已安装技能提示"))
                        .foregroundStyle(.secondary)
                } else if filteredSkills.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredSkills) { skill in
                        HStack(alignment: .top, spacing: 12) {
                            ToolCenterStatusRow(
                                title: skill.name,
                                subtitle: skill.description,
                                detail: skillStatusText(for: skill),
                                auxiliary: skill.compatibility,
                                color: skillStatusColor(for: skill)
                            )

                            Spacer(minLength: 8)

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { manager.isSkillEnabled(skill.name) },
                                    set: { manager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                                )
                            )
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Agent Skills", comment: "Agent Skills navigation title"))
    }

    private var skillGroupFooterText: String {
        var lines = [NSLocalizedString("统一查看已安装技能，并集中调整聊天暴露与单项启用状态。", comment: "Agent Skills 工具中心页脚")]
        if !manager.chatToolsEnabled {
            lines.append(NSLocalizedString("总开关关闭后，下面的单项启用状态会保留，但聊天时不会实际暴露这些技能。", comment: "Agent Skills 总开关关闭提示"))
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

    private func skillStatusText(for skill: SkillMetadata) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "工具因会话隔离不可用原因")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项启用状态会保留，但聊天时不会实际暴露这些技能。", comment: "Agent Skills 总开关关闭提示")
        }
        return manager.isSkillEnabled(skill.name)
            ? NSLocalizedString("该技能当前可参与聊天。", comment: "Agent Skills 可参与聊天状态")
            : NSLocalizedString("已停用。", comment: "工具已停用状态")
    }

    private func skillStatusColor(for skill: SkillMetadata) -> Color {
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !manager.isSkillEnabled(skill.name) {
            return .secondary
        }
        return .green
    }
}

struct ShortcutToolCategoryDetailView: View {
    let currentSessionIsolationActive: Bool
    let searchText: String
    let showEnabledOnly: Bool

    @ObservedObject private var manager = ShortcutToolManager.shared
    @State private var isShowingIntroDetails = false

    private var filteredTools: [ShortcutToolDefinition] {
        manager.tools
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .filter { tool in
                let matchesTool = matchesSearch(
                    for: [
                        tool.displayName,
                        tool.name,
                        tool.effectiveDescription
                    ]
                )
                guard matchesTool else { return false }
                if showEnabledOnly {
                    return tool.isEnabled
                }
                return true
            }
    }

    var body: some View {
        List {
            Section {
                ToolCenterIntroCard(
                    title: "快捷指令工具",
                    summary: "把已导入的 Siri 快捷指令作为聊天工具使用。",
                    details: "快捷指令工具说明正文",
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("启用状态", comment: "Enable status")),
                footer: Text(shortcutGroupFooterText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露快捷指令工具", comment: "Expose shortcut tools to model"),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section(header: Text(NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"))) {
                if manager.tools.isEmpty {
                    Text(NSLocalizedString("当前还没有已导入的快捷指令工具。", comment: "No imported shortcut tools"))
                        .foregroundStyle(.secondary)
                } else if filteredTools.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTools) { tool in
                        NavigationLink {
                            ShortcutToolCenterDetailView(
                                toolID: tool.id,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            ToolCenterStatusRow(
                                title: tool.displayName,
                                subtitle: tool.name,
                                detail: shortcutStatusText(for: tool),
                                auxiliary: tool.effectiveDescription,
                                color: shortcutStatusColor(for: tool)
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"))
        .guideSettingsPageContext(
            id: "tool-center-shortcut-tools",
            title: NSLocalizedString("快捷指令工具", comment: "快捷指令工具向导上下文标题"),
            documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcut Toolbox")],
            settings: [
                .bool("chat_tools_enabled", label: NSLocalizedString("向模型暴露快捷指令工具", comment: "向导设置字段"), get: { manager.chatToolsEnabled }, set: { manager.setChatToolsEnabled($0) }),
                .readOnly("current_session_isolation_active", label: NSLocalizedString("当前会话屏蔽工具上下文", comment: "向导设置字段"), value: { .bool(currentSessionIsolationActive) }),
                .readOnly("visible_tools", label: NSLocalizedString("快捷指令工具", comment: "向导设置字段"), value: {
                    .array(filteredTools.map { tool in
                        .dictionary([
                            "id": .string(tool.id.uuidString),
                            "shortcut_name": .string(tool.name),
                            "display_name": .string(tool.displayName),
                            "description": .string(tool.effectiveDescription),
                            "enabled": .bool(tool.isEnabled),
                            "run_mode": .string(tool.runModeHint.rawValue)
                        ])
                    })
                })
            ]
        )
    }

    private var shortcutGroupFooterText: String {
        var lines = [NSLocalizedString("统一查看已导入的快捷指令工具，并集中调整启用状态、运行模式与描述。", comment: "Shortcut tools footer")]
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

    private func shortcutStatusText(for tool: ShortcutToolDefinition) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "Tool unavailable due to session isolation")
        }
        if !manager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return tool.isEnabled
            ? NSLocalizedString("已启用。", comment: "Tool enabled status")
            : NSLocalizedString("已停用。", comment: "Tool disabled status")
    }

    private func shortcutStatusColor(for tool: ShortcutToolDefinition) -> Color {
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !tool.isEnabled {
            return .secondary
        }
        return .green
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
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: guidePageID,
                title: tool.map {
                    String(format: NSLocalizedString("快捷指令工具：%@", comment: "快捷指令工具向导上下文标题"), $0.displayName)
                } ?? NSLocalizedString("快捷指令工具", comment: "快捷指令工具向导上下文标题"),
                documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcut Toolbox")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateShortcutTool, access: .proposeChange)]
            ),
            snapshot: {
                guard let tool else { return .empty }
                return GuideShortcutToolSettingsSupport.snapshot(tool)
            },
            buildProposal: { call, _ in
                guard let tool else { throw GuideError.invalidToolArguments }
                return try GuideShortcutToolSettingsSupport.buildProposal(call: call, pageID: guidePageID, tool: tool)
            },
            execute: { proposal in
                guard let tool else { throw GuideError.invalidToolArguments }
                let application = try GuideShortcutToolSettingsSupport.apply(proposal, tool: tool)
                manager.setToolEnabled(id: toolID, isEnabled: application.enabled)
                manager.setRunModeHint(id: toolID, runModeHint: application.runMode)
                manager.updateUserDescription(id: toolID, description: application.userDescription)
                descriptionDraft = application.userDescription
                return application.execution
            }
        )
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

    private var guidePageID: GuidePageID {
        GuidePageID(rawValue: "tool-center-shortcut-tool-\(toolID.uuidString.lowercased())")
    }

    private func currentStatusText(for tool: ShortcutToolDefinition) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "Tool unavailable due to session isolation")
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
