// ============================================================================
// ToolCenterView.swift
// ============================================================================
// ToolCenterView 界面 (watchOS)
// - 统一预览聊天工具
// - 在同一入口集中调整启用状态与关键设置
// ============================================================================

import SwiftUI
import ETOSCore

struct ToolCenterView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @StateObject private var appToolManager = AppToolManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var shortcutManager = ShortcutToolManager.shared
    @StateObject private var skillManager = SkillManager.shared

    @ObservedObject private var appConfig = AppConfigStore.shared

    @State private var showEnabledOnly: Bool = false
    @State private var isShowingIntroDetails = false

    private var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    private var enableMemory: Bool {
        viewModel.enableMemory
    }

    private var enableMemoryWrite: Bool {
        viewModel.enableMemoryWrite
    }

    private var enableMemoryActiveRetrieval: Bool {
        viewModel.enableMemoryActiveRetrieval
    }

    private var memoryTopK: Int {
        appConfig.memoryTopK
    }

    private var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            memoryTopK: memoryTopK,
            enableWidgetTool: appToolManager.isToolEnabled(.showWidget),
            enableAskUserInputTool: appToolManager.isToolEnabled(.askUserInput),
            enableGetSystemTimeTool: appToolManager.isToolEnabled(.getSystemTime),
            isIsolatedSession: currentSessionIsolationActive
        )
    }

    private var filteredBuiltInStates: [ToolCatalogBuiltInToolState] {
        builtInStates.filter { state in
            showEnabledOnly ? state.isConfiguredEnabled : true
        }
    }

    private var mcpCatalogTools: [MCPAvailableTool] {
        ToolCatalogSupport.mcpCatalogTools(
            servers: mcpManager.servers,
            statuses: mcpManager.serverStatuses
        )
    }

    private var filteredMCPTools: [MCPAvailableTool] {
        ToolCatalogSupport.sortedMCPCatalogTools(mcpCatalogTools)
            .filter { available in
                showEnabledOnly
                    ? mcpManager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
                    : true
            }
    }

    private var filteredShortcutTools: [ShortcutToolDefinition] {
        shortcutManager.tools
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .filter { tool in
                showEnabledOnly ? tool.isEnabled : true
            }
    }

    private var filteredSkills: [SkillMetadata] {
        skillManager.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { skill in
                showEnabledOnly ? skillManager.isSkillEnabled(skill.name) : true
            }
    }

    private var configuredMCPCount: Int {
        mcpCatalogTools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
        }.count
    }

    private var availableMCPCount: Int {
        guard mcpManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return mcpCatalogTools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
            && mcpManager.approvalPolicy(serverID: $0.server.id, toolId: $0.tool.toolId) != .alwaysDeny
        }.count
    }

    private var configuredShortcutCount: Int {
        shortcutManager.tools.filter(\.isEnabled).count
    }

    private var availableShortcutCount: Int {
        guard shortcutManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredShortcutCount
    }

    private var configuredSkillCount: Int {
        skillManager.skills.filter { skillManager.isSkillEnabled($0.name) }.count
    }

    private var availableSkillCount: Int {
        guard skillManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredSkillCount
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("工具中心", comment: "Tool center intro title"),
                    summary: NSLocalizedString("先看当前会话能用什么，再按工具来源进入细分设置。", comment: "Tool center intro summary"),
                    details: NSLocalizedString("工具中心新版说明正文", comment: "Tool center intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(
                    NSLocalizedString("仅显示已启用", comment: "Filter enabled only"),
                    isOn: $showEnabledOnly
                )
            }

            Section(
                header: Text(NSLocalizedString("内置工具", comment: "Built-in tools section title")),
                footer: Text(NSLocalizedString("内置工具会直接影响聊天时是否向模型暴露记忆能力、网页卡片渲染能力与结构化问答能力。", comment: "Built-in tools footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                NavigationLink {
                    builtInToolCategoryDetailView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
                        Text(
                            String(
                                format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                                ToolCatalogSupport.configuredEnabledCount(for: builtInStates),
                                builtInStates.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        Text(builtInCategoryStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(builtInCategoryStatusColor)
                        Text(
                            String(
                                format: NSLocalizedString("工具 %d 个", comment: "Tool count"),
                                builtInStates.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("MCP 工具", comment: "MCP tools section title")),
                footer: Text(NSLocalizedString("统一查看各个 MCP Server 公布的聊天工具，并集中调整启用状态与审批策略。", comment: "MCP tools footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露 MCP 工具", comment: "Expose MCP tools to model"),
                    isOn: Binding(
                        get: { mcpManager.chatToolsEnabled },
                        set: { mcpManager.setChatToolsEnabled($0) }
                    )
                )

                NavigationLink {
                    WatchMCPToolCategoryDetailView(
                        currentSessionIsolationActive: currentSessionIsolationActive,
                        showEnabledOnly: showEnabledOnly
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("MCP 工具", comment: "MCP tools section title"))
                        Text(
                            String(
                                format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                                configuredMCPCount,
                                mcpCatalogTools.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        Text(mcpCategoryStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(mcpCategoryStatusColor)
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("Agent Skills", comment: "Agent Skills section title")),
                footer: Text(NSLocalizedString("统一查看已安装技能，并集中调整聊天暴露与单项启用状态。", comment: "Agent Skills 工具中心页脚"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("向模型暴露 Agent Skills（use_skill）", comment: ""),
                    isOn: Binding(
                        get: { skillManager.chatToolsEnabled },
                        set: { skillManager.setChatToolsEnabled($0) }
                    )
                )

                if !skillManager.chatToolsEnabled {
                    Text(NSLocalizedString("总开关关闭后，下面的单项启用状态会保留，但聊天时不会实际暴露这些技能。", comment: "Agent Skills 总开关关闭提示"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    WatchSkillToolCategoryDetailView(
                        currentSessionIsolationActive: currentSessionIsolationActive,
                        showEnabledOnly: showEnabledOnly
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Agent Skills", comment: "Agent Skills row title"))
                        Text(
                            String(
                                format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                                configuredSkillCount,
                                skillManager.skills.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        Text(skillCategoryStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(skillCategoryStatusColor)
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title")),
                footer: Text(NSLocalizedString("统一查看已导入的快捷指令工具，并集中调整启用状态、运行模式与描述。", comment: "Shortcut tools footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露快捷指令工具", comment: "Expose shortcut tools to model"),
                    isOn: Binding(
                        get: { shortcutManager.chatToolsEnabled },
                        set: { shortcutManager.setChatToolsEnabled($0) }
                    )
                )

                NavigationLink {
                    WatchShortcutToolCategoryDetailView(
                        currentSessionIsolationActive: currentSessionIsolationActive,
                        showEnabledOnly: showEnabledOnly
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"))
                        Text(
                            String(
                                format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                                configuredShortcutCount,
                                shortcutManager.tools.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        Text(shortcutCategoryStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(shortcutCategoryStatusColor)
                    }
                }
            }

            if filteredBuiltInStates.isEmpty && filteredMCPTools.isEmpty && filteredSkills.isEmpty && filteredShortcutTools.isEmpty {
                Section {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具中心", comment: "Tool center title"))
        .onAppear {
            skillManager.reloadFromDisk()
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "工具中心介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "工具中心介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "工具中心介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "工具中心介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func builtInToolCategoryDetailView() -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
                    Text(NSLocalizedString("系统自带能力集中在这里，按单项调整记忆、网页卡片、问答与时间工具。", comment: "Built-in tools intro summary"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(
                header: Text(NSLocalizedString("记忆系统", comment: "Memory system section title")),
                footer: Text(NSLocalizedString("启用记忆系统后，记忆写入与主动检索工具才可能参与聊天。", comment: "Built-in memory system footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                    isOn: $viewModel.enableMemory
                )
            }

            Section(header: Text(NSLocalizedString("工具", comment: "Tools section title"))) {
                if filteredBuiltInStates.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredBuiltInStates) { state in
                        NavigationLink {
                            WatchBuiltInToolDetailView(
                                kind: state.kind,
                                currentSessionIsolationActive: currentSessionIsolationActive,
                                enableMemory: $viewModel.enableMemory,
                                enableMemoryWrite: $viewModel.enableMemoryWrite,
                                enableMemoryActiveRetrieval: $viewModel.enableMemoryActiveRetrieval,
                                memoryTopK: $appConfig.memoryTopK
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(builtInTitle(for: state.kind))
                                Text(builtInStatusText(for: state))
                                    .etFont(.caption2)
                                    .foregroundStyle(state.isAvailableInCurrentSession ? .green : .secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
    }

    private func builtInTitle(for kind: ToolCatalogBuiltInToolKind) -> String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("记忆系统写入", comment: "Memory write tool title")
        case .memorySearch:
            return NSLocalizedString("记忆系统主动检索", comment: "Memory search tool title")
        case .widgetCard:
            return NSLocalizedString("显示网页卡片", comment: "Built-in widget tool title")
        case .askUserInput:
            return NSLocalizedString("询问用户选项", comment: "Built-in ask user input tool title")
        case .getSystemTime:
            return NSLocalizedString("获取系统时间", comment: "Get system time tool title")
        @unknown default:
            return NSLocalizedString("内置工具", comment: "Built-in tool fallback title")
        }
    }

    private func builtInStatusText(for state: ToolCatalogBuiltInToolState) -> String {
        switch state.kind {
        case .memoryWrite:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已允许写入新的记忆。", comment: "Memory write enabled")
            case .memoryDisabled:
                return NSLocalizedString("记忆系统总开关已关闭。", comment: "Memory system disabled")
            case .memoryWriteDisabled:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write disabled")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .activeRetrievalDisabled, .zeroTopK, .widgetDisabled, .askUserInputDisabled, .getSystemTimeDisabled:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write fallback")
            @unknown default:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write unknown status fallback")
            }
        case .memorySearch:
            switch state.statusReason {
            case .enabled:
                return String(
                    format: NSLocalizedString("已允许主动检索，Top K = %d。", comment: "Memory search enabled with top k"),
                    state.memoryTopK
                )
            case .memoryDisabled:
                return NSLocalizedString("记忆系统总开关已关闭。", comment: "Memory system disabled")
            case .activeRetrievalDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search disabled")
            case .zeroTopK:
                return NSLocalizedString("当前 Top K 为 0，聊天时不会暴露检索工具。", comment: "Memory search top k zero")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .memoryWriteDisabled, .widgetDisabled, .askUserInputDisabled, .getSystemTimeDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search fallback")
            @unknown default:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search unknown status fallback")
            }
        case .widgetCard:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已启用网页卡片渲染能力。", comment: "Built-in widget enabled status")
            case .widgetDisabled:
                return NSLocalizedString("当前未启用网页卡片渲染能力。", comment: "Built-in widget disabled status")
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .askUserInputDisabled, .getSystemTimeDisabled:
                return NSLocalizedString("当前未启用网页卡片渲染能力。", comment: "Built-in widget disabled status fallback")
            @unknown default:
                return NSLocalizedString("当前未启用网页卡片渲染能力。", comment: "Built-in widget unknown status fallback")
            }
        case .askUserInput:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已启用结构化问答能力。", comment: "Built-in ask user input enabled status")
            case .askUserInputDisabled:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input disabled status")
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .widgetDisabled, .getSystemTimeDisabled:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input disabled status fallback")
            @unknown default:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input unknown status fallback")
            }
        case .getSystemTime:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已启用系统时间获取能力。", comment: "Get system time enabled status")
            case .getSystemTimeDisabled:
                return NSLocalizedString("当前未启用获取系统时间工具。", comment: "Get system time disabled status")
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .widgetDisabled, .askUserInputDisabled:
                return NSLocalizedString("当前未启用获取系统时间工具。", comment: "Get system time disabled status fallback")
            @unknown default:
                return NSLocalizedString("当前未启用获取系统时间工具。", comment: "Get system time unknown status fallback")
            }
        @unknown default:
            return NSLocalizedString("该工具当前状态未知。", comment: "Built-in tool unknown kind fallback")
        }
    }

    private var builtInCategoryStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            ToolCatalogSupport.availableCount(for: builtInStates),
            builtInStates.count
        )
    }

    private var builtInCategoryStatusColor: Color {
        if currentSessionIsolationActive || ToolCatalogSupport.availableCount(for: builtInStates) == 0 {
            return .secondary
        }
        return .green
    }

    private var mcpCategoryStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !mcpManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            availableMCPCount,
            mcpCatalogTools.count
        )
    }

    private var mcpCategoryStatusColor: Color {
        if currentSessionIsolationActive || !mcpManager.chatToolsEnabled || availableMCPCount == 0 {
            return .secondary
        }
        return .green
    }

    private var shortcutCategoryStatusText: String {
        if shortcutManager.tools.isEmpty {
            return NSLocalizedString("当前还没有已导入的快捷指令工具。", comment: "No imported shortcut tools")
        }
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !shortcutManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            availableShortcutCount,
            shortcutManager.tools.count
        )
    }

    private var shortcutCategoryStatusColor: Color {
        if currentSessionIsolationActive || !shortcutManager.chatToolsEnabled || availableShortcutCount == 0 {
            return .secondary
        }
        return .green
    }

    private var skillCategoryStatusText: String {
        if skillManager.skills.isEmpty {
            return NSLocalizedString("当前还没有已安装技能，可在 Agent Skills 页面添加。", comment: "没有已安装技能提示")
        }
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "工具因世界书隔离不可用原因")
        }
        if !skillManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项启用状态会保留，但聊天时不会实际暴露这些技能。", comment: "Agent Skills 总开关关闭提示")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            availableSkillCount,
            skillManager.skills.count
        )
    }

    private var skillCategoryStatusColor: Color {
        if currentSessionIsolationActive || !skillManager.chatToolsEnabled || availableSkillCount == 0 {
            return .secondary
        }
        return .green
    }

    private func shortcutStatusText(for tool: ShortcutToolDefinition) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !shortcutManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return tool.isEnabled
            ? NSLocalizedString("已启用。", comment: "Tool enabled status")
            : NSLocalizedString("已停用。", comment: "Tool disabled status")
    }

    private func shortcutStatusColor(for tool: ShortcutToolDefinition) -> Color {
        if currentSessionIsolationActive || !shortcutManager.chatToolsEnabled || !tool.isEnabled {
            return .secondary
        }
        return .green
    }

    private func skillStatusText(for skill: SkillMetadata) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "工具因世界书隔离不可用原因")
        }
        if !skillManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项启用状态会保留，但聊天时不会实际暴露这些技能。", comment: "Agent Skills 总开关关闭提示")
        }
        return skillManager.isSkillEnabled(skill.name)
            ? NSLocalizedString("该技能当前可参与聊天。", comment: "Agent Skills 可参与聊天状态")
            : NSLocalizedString("已停用。", comment: "工具已停用状态")
    }

    private func skillStatusColor(for skill: SkillMetadata) -> Color {
        if currentSessionIsolationActive || !skillManager.chatToolsEnabled || !skillManager.isSkillEnabled(skill.name) {
            return .secondary
        }
        return .green
    }
}
