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
    @EnvironmentObject private var viewModel: ChatViewModel

    @StateObject private var appToolManager = AppToolManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var shortcutManager = ShortcutToolManager.shared
    @StateObject private var skillManager = SkillManager.shared

    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @AppStorage("enableMemoryActiveRetrieval") private var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("memoryTopK") private var memoryTopK: Int = 3

    @State private var searchText: String = ""
    @State private var showEnabledOnly: Bool = false
    @State private var isShowingIntroDetails = false

    private var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    private var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            memoryTopK: memoryTopK,
            enableWidgetTool: appToolManager.isToolEnabled(.showWidget),
            enableAskUserInputTool: appToolManager.isToolEnabled(.askUserInput),
            isIsolatedSession: currentSessionIsolationActive
        )
    }

    private var configuredBuiltInCount: Int {
        ToolCatalogSupport.configuredEnabledCount(for: builtInStates)
    }

    private var availableBuiltInCount: Int {
        ToolCatalogSupport.availableCount(for: builtInStates)
    }

    private var filteredAppTools: [AppToolCatalogItem] {
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

    private var isAppToolSectionVisible: Bool {
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

    private var filteredBuiltInStates: [ToolCatalogBuiltInToolState] {
        builtInStates.filter { state in
            guard matchesSearch(for: builtInKeywords(for: state.kind)) else { return false }
            if showEnabledOnly {
                return state.isConfiguredEnabled
            }
            return true
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

    private var isMCPSectionVisible: Bool {
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

    private var filteredShortcutTools: [ShortcutToolDefinition] {
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

    private var filteredSkills: [SkillMetadata] {
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

    private var isSkillsSectionVisible: Bool {
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

    private var configuredMCPCount: Int {
        mcpCatalogTools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
        }.count
    }

    private var configuredAppToolCount: Int {
        appToolManager.tools.filter(\.isEnabled).count
    }

    private var availableAppToolCount: Int {
        guard appToolManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return appToolManager.tools.filter {
            $0.isEnabled && appToolManager.approvalPolicy(for: $0.kind) != .alwaysDeny
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

    private var configuredSkillCount: Int {
        skillManager.skills.filter { skillManager.isSkillEnabled($0.name) }.count
    }

    private var availableShortcutCount: Int {
        guard shortcutManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredShortcutCount
    }

    private var availableSkillCount: Int {
        guard skillManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredSkillCount
    }

    private var hasVisibleTools: Bool {
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

    private var overviewSection: some View {
        Section {
            ToolCenterSummaryRow(
                title: NSLocalizedString("内置工具", comment: "Built-in tools section title"),
                configuredEnabled: configuredBuiltInCount,
                availableNow: availableBuiltInCount,
                total: builtInStates.count
            )

            ToolCenterSummaryRow(
                title: NSLocalizedString("MCP 工具", comment: "MCP tools section title"),
                configuredEnabled: configuredMCPCount,
                availableNow: availableMCPCount,
                total: mcpCatalogTools.count
            )

            ToolCenterSummaryRow(
                title: NSLocalizedString("拓展工具", comment: "App tools section title"),
                configuredEnabled: configuredAppToolCount,
                availableNow: availableAppToolCount,
                total: appToolManager.tools.count
            )

            ToolCenterSummaryRow(
                title: "Agent Skills",
                configuredEnabled: configuredSkillCount,
                availableNow: availableSkillCount,
                total: skillManager.skills.count
            )

            ToolCenterSummaryRow(
                title: NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"),
                configuredEnabled: configuredShortcutCount,
                availableNow: availableShortcutCount,
                total: shortcutManager.tools.count
            )

            if currentSessionIsolationActive {
                Text(NSLocalizedString("当前会话已启用世界书隔离发送，聊天时不会发送记忆、MCP、Agent Skills 与快捷指令工具。", comment: "世界书隔离发送提示"))
                    .etFont(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "工具中心介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "工具中心介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "工具中心介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "工具中心介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "工具中心介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var appToolSection: some View {
        Section(
            header: Text(NSLocalizedString("拓展工具", comment: "App tools section title"))
        ) {
            Toggle(
                NSLocalizedString("向模型暴露拓展工具", comment: "Expose app tools to model"),
                isOn: Binding(
                    get: { appToolManager.chatToolsEnabled },
                    set: { appToolManager.setChatToolsEnabled($0) }
                )
            )

            NavigationLink {
                AppToolCategoryDetailView(
                    currentSessionIsolationActive: currentSessionIsolationActive,
                    searchText: searchText,
                    showEnabledOnly: showEnabledOnly
                )
            } label: {
                ToolCenterStatusRow(
                    title: NSLocalizedString("拓展工具", comment: "App tools section title"),
                    subtitle: String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredAppToolCount,
                        appToolManager.tools.count
                    ),
                    detail: appToolCategoryStatusText,
                    color: appToolCategoryStatusColor
                )
            }
        }
    }

    private var filterSection: some View {
        Section {
            Toggle(
                NSLocalizedString("仅显示已启用", comment: "Filter enabled only"),
                isOn: $showEnabledOnly
            )
        }
    }

    private var builtInSection: some View {
        Section(
            header: Text(NSLocalizedString("内置工具", comment: "Built-in tools section title")),
            footer: Text(NSLocalizedString("内置工具会直接影响聊天时是否向模型暴露记忆能力、网页卡片渲染能力与结构化问答能力。", comment: "Built-in tools footer"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        ) {
            Toggle(
                NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                isOn: $enableMemory
            )

            ForEach(filteredBuiltInStates) { state in
                NavigationLink {
                    BuiltInToolDetailView(
                        kind: state.kind,
                        currentSessionIsolationActive: currentSessionIsolationActive
                    )
                } label: {
                    ToolCenterStatusRow(
                        title: builtInTitle(for: state.kind),
                        subtitle: builtInSubtitle(for: state.kind),
                        detail: builtInStatusText(for: state),
                        color: builtInStatusColor(for: state)
                    )
                }
            }
        }
    }

    private var mcpSection: some View {
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
                MCPToolCategoryDetailView(
                    currentSessionIsolationActive: currentSessionIsolationActive,
                    searchText: searchText,
                    showEnabledOnly: showEnabledOnly
                )
            } label: {
                ToolCenterStatusRow(
                    title: NSLocalizedString("MCP 工具", comment: "MCP tools section title"),
                    subtitle: String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredMCPCount,
                        mcpCatalogTools.count
                    ),
                    detail: mcpCategoryStatusText,
                    color: mcpCategoryStatusColor
                )
            }
        }
    }

    private var shortcutSection: some View {
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

            if !shortcutManager.chatToolsEnabled {
                Text(NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(filteredShortcutTools) { tool in
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

    private var skillsSection: some View {
        Section(
            header: Text("Agent Skills"),
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
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if skillManager.skills.isEmpty {
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
                                get: { skillManager.isSkillEnabled(skill.name) },
                                set: { skillManager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                            )
                        )
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func matchesSearch(for keywords: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return keywords.contains { keyword in
            keyword.localizedCaseInsensitiveContains(query)
        }
    }

    private func builtInKeywords(for kind: ToolCatalogBuiltInToolKind) -> [String] {
        [builtInTitle(for: kind), builtInSubtitle(for: kind)]
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
        @unknown default:
            return NSLocalizedString("内置工具", comment: "Built-in tool fallback title")
        }
    }

    private func builtInSubtitle(for kind: ToolCatalogBuiltInToolKind) -> String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("允许模型调用 save_memory，将有长期价值的信息写入记忆。", comment: "Memory write tool subtitle")
        case .memorySearch:
            return NSLocalizedString("允许模型调用 search_memory，在回答前主动检索记忆。", comment: "Memory search tool subtitle")
        case .widgetCard:
            return NSLocalizedString("允许模型调用 show_widget，在对话中渲染 HTML 网页卡片。", comment: "Built-in widget tool subtitle")
        case .askUserInput:
            return NSLocalizedString("允许模型调用 ask_user_input，在回答前向用户发起结构化问答。", comment: "Built-in ask user input tool subtitle")
        @unknown default:
            return NSLocalizedString("该内置工具当前可按配置参与聊天。", comment: "Built-in tool fallback subtitle")
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
            case .activeRetrievalDisabled, .zeroTopK, .widgetDisabled, .askUserInputDisabled:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write disabled fallback")
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
            case .memoryWriteDisabled, .widgetDisabled, .askUserInputDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search disabled fallback")
            @unknown default:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search unknown status fallback")
            }
        case .widgetCard:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已启用网页卡片渲染能力。", comment: "Built-in widget enabled status")
            case .widgetDisabled:
                return NSLocalizedString("当前未启用网页卡片渲染能力。", comment: "Built-in widget disabled status")
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .askUserInputDisabled:
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
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .widgetDisabled:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input disabled status fallback")
            @unknown default:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input unknown status fallback")
            }
        @unknown default:
            return NSLocalizedString("该工具当前状态未知。", comment: "Built-in tool unknown kind fallback")
        }
    }

    private func builtInStatusColor(for state: ToolCatalogBuiltInToolState) -> Color {
        state.isAvailableInCurrentSession ? .green : .secondary
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

    private var appToolCategoryStatusText: String {
        if appToolManager.tools.isEmpty {
            return NSLocalizedString("当前还没有已注册的拓展工具。", comment: "No registered app tools")
        }
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !appToolManager.chatToolsEnabled {
            return NSLocalizedString("拓展工具总开关已关闭。", comment: "App tools group disabled")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            availableAppToolCount,
            appToolManager.tools.count
        )
    }

    private var appToolCategoryStatusColor: Color {
        if currentSessionIsolationActive || !appToolManager.chatToolsEnabled || availableAppToolCount == 0 {
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

private struct ToolCenterSummaryRow: View {
    let title: String
    let configuredEnabled: Int
    let availableNow: Int
    let total: Int

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredEnabled,
                        total
                    )
                )
                .etFont(.caption)
                .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
                        availableNow,
                        total
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ToolCenterStatusRow: View {
    let title: String
    let subtitle: String
    let detail: String
    var auxiliary: String? = nil
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .etFont(.headline)

            Text(subtitle)
                .etFont(.caption)
                .foregroundStyle(.secondary)

            Text(detail)
                .etFont(.caption)
                .foregroundStyle(color)

            if let auxiliary, !auxiliary.isEmpty {
                Text(auxiliary)
                    .etFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BuiltInToolDetailView: View {
    let kind: ToolCatalogBuiltInToolKind
    let currentSessionIsolationActive: Bool

    @ObservedObject private var appToolManager = AppToolManager.shared
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @AppStorage("enableMemoryActiveRetrieval") private var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("memoryTopK") private var memoryTopK: Int = 3

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var state: ToolCatalogBuiltInToolState {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            memoryTopK: memoryTopK,
            enableWidgetTool: appToolManager.isToolEnabled(.showWidget),
            enableAskUserInputTool: appToolManager.isToolEnabled(.askUserInput),
            isIsolatedSession: currentSessionIsolationActive
        ).first(where: { $0.kind == kind }) ?? ToolCatalogBuiltInToolState(
            kind: kind,
            isConfiguredEnabled: false,
            isAvailableInCurrentSession: false,
            statusReason: fallbackStatusReason(for: kind)
        )
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(title)
                    .etFont(.headline)
                Text(subtitle)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(statusText(for: state))
                    .foregroundStyle(state.isAvailableInCurrentSession ? .green : .secondary)
                if currentSessionIsolationActive && state.statusReason == .isolatedByWorldbook {
                    Text(NSLocalizedString("当前会话已启用世界书隔离发送，聊天时不会发送记忆、MCP、Agent Skills 与快捷指令工具。", comment: "世界书隔离发送提示"))
                        .etFont(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            switch kind {
            case .memoryWrite:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                        isOn: $enableMemory
                    )
                    Toggle(
                        NSLocalizedString("允许写入新的记忆", comment: "Allow memory writing"),
                        isOn: $enableMemoryWrite
                    )
                    .disabled(!enableMemory)
                }
            case .memorySearch:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                        isOn: $enableMemory
                    )
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $enableMemoryActiveRetrieval
                    )
                    .disabled(!enableMemory)
                    LabeledContent("Top K") {
                        TextField("0", value: $memoryTopK, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .onChange(of: memoryTopK) { _, newValue in
                                memoryTopK = max(0, newValue)
                            }
                    }
                    .disabled(!enableMemory)
                }
            case .widgetCard:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用显示网页卡片工具", comment: "Enable show widget built-in tool"),
                        isOn: Binding(
                            get: { appToolManager.isToolEnabled(.showWidget) },
                            set: { appToolManager.setToolEnabled(kind: .showWidget, isEnabled: $0) }
                        )
                    )
                }
            case .askUserInput:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用询问用户选项工具", comment: "Enable ask user input built-in tool"),
                        isOn: Binding(
                            get: { appToolManager.isToolEnabled(.askUserInput) },
                            set: { appToolManager.setToolEnabled(kind: .askUserInput, isEnabled: $0) }
                        )
                    )
                }
            @unknown default:
                Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                    Text(NSLocalizedString("该工具类型暂未提供可编辑设置。", comment: "Unknown built-in tool settings fallback"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
    }

    private var title: String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("记忆系统写入", comment: "Memory write tool title")
        case .memorySearch:
            return NSLocalizedString("记忆系统主动检索", comment: "Memory search tool title")
        case .widgetCard:
            return NSLocalizedString("显示网页卡片", comment: "Built-in widget tool title")
        case .askUserInput:
            return NSLocalizedString("询问用户选项", comment: "Built-in ask user input tool title")
        @unknown default:
            return NSLocalizedString("内置工具", comment: "Built-in tool fallback title")
        }
    }

    private var subtitle: String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("允许模型调用 save_memory，将有长期价值的信息写入记忆。", comment: "Memory write tool subtitle")
        case .memorySearch:
            return NSLocalizedString("允许模型调用 search_memory，在回答前主动检索记忆。", comment: "Memory search tool subtitle")
        case .widgetCard:
            return NSLocalizedString("允许模型调用 show_widget，在对话中渲染 HTML 网页卡片。", comment: "Built-in widget tool subtitle")
        case .askUserInput:
            return NSLocalizedString("允许模型调用 ask_user_input，在回答前向用户发起结构化问答。", comment: "Built-in ask user input tool subtitle")
        @unknown default:
            return NSLocalizedString("该内置工具当前可按配置参与聊天。", comment: "Built-in tool fallback subtitle")
        }
    }

    private func fallbackStatusReason(for kind: ToolCatalogBuiltInToolKind) -> ToolCatalogBuiltInToolStatusReason {
        switch kind {
        case .widgetCard:
            return .widgetDisabled
        case .askUserInput:
            return .askUserInputDisabled
        case .memoryWrite, .memorySearch:
            return .memoryDisabled
        @unknown default:
            return .memoryDisabled
        }
    }

    private func statusText(for state: ToolCatalogBuiltInToolState) -> String {
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
            case .activeRetrievalDisabled, .zeroTopK, .widgetDisabled, .askUserInputDisabled:
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
            case .memoryWriteDisabled, .widgetDisabled, .askUserInputDisabled:
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
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .askUserInputDisabled:
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
            case .memoryDisabled, .memoryWriteDisabled, .activeRetrievalDisabled, .zeroTopK, .isolatedByWorldbook, .widgetDisabled:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input disabled status fallback")
            @unknown default:
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input unknown status fallback")
            }
        @unknown default:
            return NSLocalizedString("该工具当前状态未知。", comment: "Built-in tool unknown kind fallback")
        }
    }
}

private struct MCPToolCenterDetailView: View {
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

private struct MCPToolCategoryDetailView: View {
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

private struct AppToolCategoryDetailView: View {
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

private struct AppToolCenterDetailView: View {
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

private struct ShortcutToolCenterDetailView: View {
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
