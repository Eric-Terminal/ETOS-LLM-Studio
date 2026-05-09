// ============================================================================
// ToolCenterView.swift
// ============================================================================
// ToolCenterView 界面 (watchOS)
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

    
    
    
    @EnvironmentObject private var appConfig: AppConfigStore

    @State private var showEnabledOnly: Bool = false
    @State private var isShowingIntroDetails = false

    private var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    private var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            appConfig.enableMemory: appConfig.enableMemory,
            appConfig.enableMemoryWrite: appConfig.enableMemoryWrite,
            appConfig.enableMemoryActiveRetrieval: appConfig.enableMemoryActiveRetrieval,
            appConfig.memoryTopK: appConfig.memoryTopK,
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

    private var filteredAppTools: [AppToolCatalogItem] {
        appToolManager.tools.filter { item in
            showEnabledOnly ? item.isEnabled : true
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
                    title: "工具中心",
                    summary: "统一查看聊天可用工具，并集中调整启用状态。",
                    details: """
                    页面作用
                    • 快速判断各类工具在“配置层”与“会话层”是否真正可用。

                    指标怎么读
                    • 配置已启用：你在设置里已经打开。
                    • 当前会话实际可用：在总开关、审批策略、隔离策略后仍可用。

                    推荐流程
                    1. 先看汇总数字，确认问题范围。
                    2. 开启“仅显示已启用”缩小排查范围。
                    3. 进入具体工具页调整策略与状态。

                    常见情况
                    • 如果显示世界书隔离生效，记忆、MCP、Agent Skills、快捷指令可能被会话策略屏蔽。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Text(
                    String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        ToolCatalogSupport.configuredEnabledCount(for: builtInStates),
                        builtInStates.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
                        ToolCatalogSupport.availableCount(for: builtInStates),
                        builtInStates.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("MCP 工具：配置已启用 %d / %d", comment: "MCP configured count"),
                        configuredMCPCount,
                        mcpCatalogTools.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("MCP 工具：当前会话实际可用 %d / %d", comment: "MCP available count"),
                        availableMCPCount,
                        mcpCatalogTools.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("拓展工具：配置已启用 %d / %d", comment: "App tool configured count"),
                        configuredAppToolCount,
                        appToolManager.tools.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("拓展工具：当前会话实际可用 %d / %d", comment: "App tool available count"),
                        availableAppToolCount,
                        appToolManager.tools.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("Agent Skills：配置已启用 %d / %d", comment: "Skills configured count"),
                        configuredSkillCount,
                        skillManager.skills.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("Agent Skills：当前会话实际可用 %d / %d", comment: "Skills available count"),
                        availableSkillCount,
                        skillManager.skills.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("快捷指令工具：配置已启用 %d / %d", comment: "Shortcut configured count"),
                        configuredShortcutCount,
                        shortcutManager.tools.count
                    )
                )
                .etFont(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("快捷指令工具：当前会话实际可用 %d / %d", comment: "Shortcut available count"),
                        availableShortcutCount,
                        shortcutManager.tools.count
                    )
                )
                .etFont(.caption2)
                if currentSessionIsolationActive {
                    Text(NSLocalizedString("当前会话已启用世界书隔离发送，聊天时不会发送记忆、MCP、Agent Skills 与快捷指令工具。", comment: "世界书隔离发送提示"))
                        .etFont(.caption2)
                        .foregroundStyle(.orange)
                }
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
                Toggle(
                    NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                    isOn: $appConfig.enableMemory
                )

                ForEach(filteredBuiltInStates) { state in
                    NavigationLink {
                        WatchBuiltInToolDetailView(
                            kind: state.kind,
                            currentSessionIsolationActive: currentSessionIsolationActive
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
                    WatchAppToolCategoryDetailView(
                        currentSessionIsolationActive: currentSessionIsolationActive,
                        showEnabledOnly: showEnabledOnly
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("拓展工具", comment: "App tools section title"))
                        Text(
                            String(
                                format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                                configuredAppToolCount,
                                appToolManager.tools.count
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        Text(appToolCategoryStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(appToolCategoryStatusColor)
                    }
                }
            }

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
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if skillManager.skills.isEmpty {
                    Text(NSLocalizedString("当前还没有已安装技能，可在 Agent Skills 页面添加。", comment: "没有已安装技能提示"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredSkills) { skill in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                Text(skill.description)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(skillStatusText(for: skill))
                                    .etFont(.caption2)
                                    .foregroundStyle(skillStatusColor(for: skill))
                            }
                            Spacer(minLength: 4)
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { skillManager.isSkillEnabled(skill.name) },
                                    set: { skillManager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                                )
                            )
                            .labelsHidden()
                        }
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

                ForEach(filteredShortcutTools) { tool in
                    NavigationLink {
                        WatchShortcutToolCenterDetailView(
                            toolID: tool.id,
                            currentSessionIsolationActive: currentSessionIsolationActive
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.displayName)
                            Text(tool.name)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Text(shortcutStatusText(for: tool))
                                .etFont(.caption2)
                                .foregroundStyle(shortcutStatusColor(for: tool))
                        }
                    }
                }
            }

            if filteredBuiltInStates.isEmpty && filteredAppTools.isEmpty && filteredMCPTools.isEmpty && filteredSkills.isEmpty && filteredShortcutTools.isEmpty {
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
                    state.appConfig.memoryTopK
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
