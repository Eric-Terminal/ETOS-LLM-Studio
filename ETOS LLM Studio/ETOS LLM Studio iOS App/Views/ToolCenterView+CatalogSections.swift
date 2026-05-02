// ============================================================================
// ToolCenterView.swift
// ============================================================================
// ToolCenterView 界面 (iOS)
// - 统一预览聊天工具
// - 在同一入口集中调整启用状态与关键设置
// ============================================================================

import SwiftUI
import Shared

extension ToolCenterView {
    var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    var builtInStates: [ToolCatalogBuiltInToolState] {
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

    var overviewSection: some View {
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

    func settingsIntroCard(
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

    var appToolSection: some View {
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

    var filterSection: some View {
        Section {
            Toggle(
                NSLocalizedString("仅显示已启用", comment: "Filter enabled only"),
                isOn: $showEnabledOnly
            )
        }
    }

    var builtInSection: some View {
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

    var mcpSection: some View {
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

    var shortcutSection: some View {
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

    var skillsSection: some View {
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

    func matchesSearch(for keywords: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return keywords.contains { keyword in
            keyword.localizedCaseInsensitiveContains(query)
        }
    }

    func builtInKeywords(for kind: ToolCatalogBuiltInToolKind) -> [String] {
        [builtInTitle(for: kind), builtInSubtitle(for: kind)]
    }

    func builtInTitle(for kind: ToolCatalogBuiltInToolKind) -> String {
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

    func builtInSubtitle(for kind: ToolCatalogBuiltInToolKind) -> String {
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

    func builtInStatusText(for state: ToolCatalogBuiltInToolState) -> String {
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

    func builtInStatusColor(for state: ToolCatalogBuiltInToolState) -> Color {
        state.isAvailableInCurrentSession ? .green : .secondary
    }

    var mcpCategoryStatusText: String {
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

    var mcpCategoryStatusColor: Color {
        if currentSessionIsolationActive || !mcpManager.chatToolsEnabled || availableMCPCount == 0 {
            return .secondary
        }
        return .green
    }

    var appToolCategoryStatusText: String {
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

    var appToolCategoryStatusColor: Color {
        if currentSessionIsolationActive || !appToolManager.chatToolsEnabled || availableAppToolCount == 0 {
            return .secondary
        }
        return .green
    }
}
