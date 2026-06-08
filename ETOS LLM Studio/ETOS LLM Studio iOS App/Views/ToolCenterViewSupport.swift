// ============================================================================
// ToolCenterViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 工具中心视图的分类入口与状态文案辅助。
// ============================================================================

import SwiftUI
import ETOSCore

struct ToolCenterStatusRow: View {
    let title: String
    let subtitle: String
    let detail: String
    var auxiliary: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .etFont(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Text(subtitle)
                .etFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(detail)
                .etFont(.caption)
                .foregroundStyle(color)
                .lineLimit(3)

            if let auxiliary, !auxiliary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(auxiliary)
                    .etFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct ToolCenterIntroCard: View {
    let title: String
    let summary: String
    let details: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "工具中心介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "工具中心介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "工具中心介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $isExpanded) {
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
}

extension ToolCenterView {
    func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        ToolCenterIntroCard(
            title: title,
            summary: summary,
            details: details,
            isExpanded: isExpanded
        )
    }

    var appToolSection: some View {
        Section(
            header: Text(NSLocalizedString("拓展工具", comment: "App tools section title")),
            footer: Text(NSLocalizedString("拓展工具已按用途分组；进入分类后再查看具体工具、启用状态与审批策略。", comment: "App tool grouped section footer"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
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
                    auxiliary: String(
                        format: NSLocalizedString("分类 %d 个", comment: "App tool category count"),
                        appToolCategoryStates.count
                    ),
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
            NavigationLink {
                builtInToolCategoryDetailView()
            } label: {
                ToolCenterStatusRow(
                    title: NSLocalizedString("内置工具", comment: "Built-in tools section title"),
                    subtitle: String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredBuiltInCount,
                        builtInStates.count
                    ),
                    detail: builtInCategoryStatusText,
                    auxiliary: String(
                        format: NSLocalizedString("工具 %d 个", comment: "Tool count"),
                        builtInStates.count
                    ),
                    color: builtInCategoryStatusColor
                )
            }
        }
    }

    func builtInToolCategoryDetailView() -> some View {
        List {
            Section {
                ToolCenterIntroCard(
                    title: "内置工具",
                    summary: "系统自带能力集中在这里，按单项调整记忆、网页卡片、问答与时间工具。",
                    details: "内置工具说明正文",
                    isExpanded: $isShowingBuiltInIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("记忆系统", comment: "Memory system section title")),
                footer: Text(NSLocalizedString("启用记忆系统后，记忆写入与主动检索工具才可能参与聊天。", comment: "Built-in memory system footer"))
                    .etFont(.footnote)
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
                            BuiltInToolDetailView(
                                kind: state.kind,
                                currentSessionIsolationActive: currentSessionIsolationActive,
                                enableMemory: $viewModel.enableMemory,
                                enableMemoryWrite: $viewModel.enableMemoryWrite,
                                enableMemoryActiveRetrieval: $viewModel.enableMemoryActiveRetrieval,
                                memoryTopK: $appConfig.memoryTopK
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
        }
        .navigationTitle(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
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

            NavigationLink {
                ShortcutToolCategoryDetailView(
                    currentSessionIsolationActive: currentSessionIsolationActive,
                    searchText: searchText,
                    showEnabledOnly: showEnabledOnly
                )
            } label: {
                ToolCenterStatusRow(
                    title: NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"),
                    subtitle: String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredShortcutCount,
                        shortcutManager.tools.count
                    ),
                    detail: shortcutCategoryStatusText,
                    color: shortcutCategoryStatusColor
                )
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

            NavigationLink {
                SkillToolCategoryDetailView(
                    currentSessionIsolationActive: currentSessionIsolationActive,
                    searchText: searchText,
                    showEnabledOnly: showEnabledOnly
                )
            } label: {
                ToolCenterStatusRow(
                    title: "Agent Skills",
                    subtitle: String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        configuredSkillCount,
                        skillManager.skills.count
                    ),
                    detail: skillCategoryStatusText,
                    color: skillCategoryStatusColor
                )
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
        case .getSystemTime:
            return NSLocalizedString("获取系统时间", comment: "Get system time tool title")
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
        case .getSystemTime:
            return NSLocalizedString("允许模型调用 get_system_time，免审批获取当前设备时间，解决 KV 缓存时间感知问题。", comment: "Get system time tool subtitle")
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
            case .activeRetrievalDisabled, .zeroTopK, .widgetDisabled, .askUserInputDisabled, .getSystemTimeDisabled:
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
            case .memoryWriteDisabled, .widgetDisabled, .askUserInputDisabled, .getSystemTimeDisabled:
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

    func builtInStatusColor(for state: ToolCatalogBuiltInToolState) -> Color {
        state.isAvailableInCurrentSession ? .green : .secondary
    }

    var builtInCategoryStatusText: String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        return String(
            format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
            availableBuiltInCount,
            builtInStates.count
        )
    }

    var builtInCategoryStatusColor: Color {
        if currentSessionIsolationActive || availableBuiltInCount == 0 {
            return .secondary
        }
        return .green
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

    var shortcutCategoryStatusText: String {
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

    var shortcutCategoryStatusColor: Color {
        if currentSessionIsolationActive || !shortcutManager.chatToolsEnabled || availableShortcutCount == 0 {
            return .secondary
        }
        return .green
    }

    var skillCategoryStatusText: String {
        if skillManager.skills.isEmpty {
            return NSLocalizedString("当前还没有已安装技能，可在设置里的 Agent Skills 页面添加。", comment: "没有已安装技能提示")
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

    var skillCategoryStatusColor: Color {
        if currentSessionIsolationActive || !skillManager.chatToolsEnabled || availableSkillCount == 0 {
            return .secondary
        }
        return .green
    }

    func shortcutStatusText(for tool: ShortcutToolDefinition) -> String {
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

    func shortcutStatusColor(for tool: ShortcutToolDefinition) -> Color {
        if currentSessionIsolationActive || !shortcutManager.chatToolsEnabled || !tool.isEnabled {
            return .secondary
        }
        return .green
    }

    func skillStatusText(for skill: SkillMetadata) -> String {
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

    func skillStatusColor(for skill: SkillMetadata) -> Color {
        if currentSessionIsolationActive || !skillManager.chatToolsEnabled || !skillManager.isSkillEnabled(skill.name) {
            return .secondary
        }
        return .green
    }
}

struct BuiltInToolDetailView: View {
    let kind: ToolCatalogBuiltInToolKind
    let currentSessionIsolationActive: Bool
    @Binding var enableMemory: Bool
    @Binding var enableMemoryWrite: Bool
    @Binding var enableMemoryActiveRetrieval: Bool
    @Binding var memoryTopK: Int

    @ObservedObject private var appToolManager = AppToolManager.shared

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
            enableGetSystemTimeTool: appToolManager.isToolEnabled(.getSystemTime),
            isIsolatedSession: currentSessionIsolationActive
        ).first(where: { $0.kind == kind }) ?? ToolCatalogBuiltInToolState(
            kind: kind,
            isConfiguredEnabled: false,
            isAvailableInCurrentSession: false,
            statusReason: fallbackStatusReason(for: kind)
        )
    }

    var body: some View {
        List {
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
            }

            switch kind {
            case .memoryWrite:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"), isOn: $enableMemory)
                    Toggle(NSLocalizedString("允许写入新的记忆", comment: "Allow memory writing"), isOn: $enableMemoryWrite)
                        .disabled(!enableMemory)
                }
            case .memorySearch:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"), isOn: $enableMemory)
                    Toggle(NSLocalizedString("主动检索", comment: "Active retrieval toggle title"), isOn: $enableMemoryActiveRetrieval)
                        .disabled(!enableMemory)
                    HStack {
                        Text(NSLocalizedString("Top K", comment: "Memory search top k label"))
                        Spacer()
                        TextField("0", value: $memoryTopK, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                    }
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
            case .getSystemTime:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用获取系统时间工具", comment: "Enable get system time built-in tool"),
                        isOn: Binding(
                            get: { appToolManager.isToolEnabled(.getSystemTime) },
                            set: { appToolManager.setToolEnabled(kind: .getSystemTime, isEnabled: $0) }
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
        case .getSystemTime:
            return NSLocalizedString("获取系统时间", comment: "Get system time tool title")
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
        case .getSystemTime:
            return NSLocalizedString("允许模型调用 get_system_time，免审批获取当前设备时间，解决 KV 缓存时间感知问题。", comment: "Get system time tool subtitle")
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
        case .getSystemTime:
            return .getSystemTimeDisabled
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
                return NSLocalizedString("当前未启用网页卡片渲染能力。", comment: "Built-in widget fallback")
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
                return NSLocalizedString("当前未启用结构化问答能力。", comment: "Built-in ask user input fallback")
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
}
