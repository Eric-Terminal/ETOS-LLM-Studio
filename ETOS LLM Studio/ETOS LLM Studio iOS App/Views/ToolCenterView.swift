// ============================================================================
// ToolCenterView.swift
// ============================================================================
// ToolCenterView 界面 (iOS)
// - 统一预览聊天工具
// - 在同一入口集中调整启用状态与关键设置
// ============================================================================

import SwiftUI
import Shared

struct ToolCenterView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    @StateObject var appToolManager = AppToolManager.shared
    @StateObject var mcpManager = MCPManager.shared
    @StateObject var shortcutManager = ShortcutToolManager.shared
    @StateObject var skillManager = SkillManager.shared
    @EnvironmentObject private var appConfig: AppConfigStore

    @State var searchText: String = ""
    @State var showEnabledOnly: Bool = false
    @State var isShowingIntroDetails = false

    var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: appConfig.enableMemory,
            enableMemoryWrite: appConfig.enableMemoryWrite,
            enableMemoryActiveRetrieval: appConfig.enableMemoryActiveRetrieval,
            memoryTopK: appConfig.memoryTopK,
            enableWidgetTool: appToolManager.isToolEnabled(.showWidget),
            enableAskUserInputTool: appToolManager.isToolEnabled(.askUserInput),
            enableGetSystemTimeTool: appToolManager.isToolEnabled(.getSystemTime),
            isIsolatedSession: currentSessionIsolationActive
        )
    }

    var configuredBuiltInCount: Int {
        ToolCatalogSupport.configuredEnabledCount(for: builtInStates)
    }

    var availableBuiltInCount: Int {
        ToolCatalogSupport.availableCount(for: builtInStates)
    }

    var filteredAppTools: [AppToolCatalogItem] {
        appToolManager.tools.filter { item in
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

    var isAppToolSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredAppTools.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                NSLocalizedString("拓展工具", comment: "App tools section title"),
                NSLocalizedString("向模型暴露拓展工具", comment: "Expose app tools to model")
            ]
        )
    }

    var filteredBuiltInStates: [ToolCatalogBuiltInToolState] {
        builtInStates.filter { state in
            guard matchesSearch(for: builtInKeywords(for: state.kind)) else { return false }
            if showEnabledOnly {
                return state.isConfiguredEnabled
            }
            return true
        }
    }

    var mcpCatalogTools: [MCPAvailableTool] {
        ToolCatalogSupport.mcpCatalogTools(
            servers: mcpManager.servers,
            statuses: mcpManager.serverStatuses
        )
    }

    var filteredMCPTools: [MCPAvailableTool] {
        ToolCatalogSupport.sortedMCPCatalogTools(mcpCatalogTools)
            .filter { available in
                let keywords = [
                    available.tool.toolId,
                    available.server.displayName,
                    available.tool.description ?? "",
                    available.internalName
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return mcpManager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
                }
                return true
        }
    }

    var isMCPSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredMCPTools.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                NSLocalizedString("MCP 工具", comment: "MCP tools section title"),
                NSLocalizedString("向模型暴露 MCP 工具", comment: "Expose MCP tools to model")
            ]
        )
    }

    var filteredShortcutTools: [ShortcutToolDefinition] {
        shortcutManager.tools
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .filter { tool in
                let keywords = [
                    tool.displayName,
                    tool.name,
                    tool.effectiveDescription
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return tool.isEnabled
                }
                return true
            }
    }

    var filteredSkills: [SkillMetadata] {
        skillManager.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { skill in
                let keywords = [
                    skill.name,
                    skill.description,
                    skill.compatibility ?? "",
                    "Agent Skills",
                    "use_skill"
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return skillManager.isSkillEnabled(skill.name)
                }
                return true
            }
    }

    var isSkillsSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredSkills.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                "Agent Skills",
                "use_skill",
                "向模型暴露 Agent Skills（use_skill）"
            ]
        )
    }

    var configuredMCPCount: Int {
        mcpCatalogTools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
        }.count
    }

    var configuredAppToolCount: Int {
        appToolManager.tools.filter(\.isEnabled).count
    }

    var availableAppToolCount: Int {
        guard appToolManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return appToolManager.tools.filter {
            $0.isEnabled && appToolManager.approvalPolicy(for: $0.kind) != .alwaysDeny
        }.count
    }

    var availableMCPCount: Int {
        guard mcpManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return mcpCatalogTools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
            && mcpManager.approvalPolicy(serverID: $0.server.id, toolId: $0.tool.toolId) != .alwaysDeny
        }.count
    }

    var configuredShortcutCount: Int {
        shortcutManager.tools.filter(\.isEnabled).count
    }

    var configuredSkillCount: Int {
        skillManager.skills.filter { skillManager.isSkillEnabled($0.name) }.count
    }

    var availableShortcutCount: Int {
        guard shortcutManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredShortcutCount
    }

    var availableSkillCount: Int {
        guard skillManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredSkillCount
    }

    var hasVisibleTools: Bool {
        !filteredBuiltInStates.isEmpty
        || isAppToolSectionVisible
        || isMCPSectionVisible
        || isSkillsSectionVisible
        || !filteredShortcutTools.isEmpty
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "工具中心",
                    summary: "集中管理内置记忆、拓展工具、MCP、Agent Skills 与快捷指令的聊天暴露状态。",
                    details: """
                    适用场景
                    • 你想快速判断“当前会话到底能用哪些工具”。
                    • 你想统一调整不同类型工具的启用与审批策略。

                    页面怎么看
                    • 配置已启用：表示你在设置层面已打开。
                    • 当前会话可用：在“总开关 + 审批策略 + 会话隔离”等条件下，聊天时真的可用。
                    • 两个数字不一致通常不是 bug，而是被会话条件限制（例如世界书隔离发送）。

                    推荐使用流程
                    1. 先看概览区，确认五类工具的可用数量。
                    2. 用“仅显示已启用”快速聚焦当前生效配置。
                    3. 分别进入内置/拓展/MCP/Skills/快捷指令分类做单项微调。

                    关键开关说明
                    • 启用记忆系统：决定记忆相关内置工具是否可参与聊天。
                    • 各分类“向模型暴露…工具”：控制该类工具是否整体开放给模型。
                    • 审批策略：决定调用前是否确认、自动通过或拒绝。

                    排查建议
                    • 工具不生效：优先核对“当前会话可用”而不是“配置已启用”。
                    • 会话隔离提示为橙色时：记忆、MCP、Agent Skills、快捷指令会被会话级策略屏蔽。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            overviewSection
            filterSection
            builtInSection
            if isAppToolSectionVisible {
                appToolSection
            }
            if isMCPSectionVisible {
                mcpSection
            }
            if isSkillsSectionVisible {
                skillsSection
            }
            shortcutSection

            if !hasVisibleTools {
                Section {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具中心", comment: "Tool center title"))
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text(NSLocalizedString("搜索工具", comment: "Search tools prompt"))
        )
        .onAppear {
            skillManager.reloadFromDisk()
        }
    }
}
