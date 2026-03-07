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

    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @AppStorage("enableMemoryActiveRetrieval") private var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("memoryTopK") private var memoryTopK: Int = 3

    @State private var showEnabledOnly: Bool = false

    private var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isWorldbookContextIsolationActive ?? false
    }

    private var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            memoryTopK: memoryTopK,
            isIsolatedSession: currentSessionIsolationActive
        )
    }

    private var filteredBuiltInStates: [ToolCatalogBuiltInToolState] {
        builtInStates.filter { state in
            showEnabledOnly ? state.isConfiguredEnabled : true
        }
    }

    private var filteredMCPTools: [MCPAvailableTool] {
        mcpManager.tools
            .sorted {
                if $0.server.displayName == $1.server.displayName {
                    return $0.tool.toolId.localizedCaseInsensitiveCompare($1.tool.toolId) == .orderedAscending
                }
                return $0.server.displayName.localizedCaseInsensitiveCompare($1.server.displayName) == .orderedAscending
            }
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

    private var configuredMCPCount: Int {
        mcpManager.tools.filter {
            mcpManager.isToolEnabled(serverID: $0.server.id, toolId: $0.tool.toolId)
        }.count
    }

    private var configuredAppToolCount: Int {
        appToolManager.tools.filter(\.isEnabled).count
    }

    private var availableAppToolCount: Int {
        guard appToolManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredAppToolCount
    }

    private var availableMCPCount: Int {
        guard mcpManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return mcpManager.tools.filter {
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

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("统一查看聊天可用工具，并在这里集中调整启用状态与关键设置。", comment: "Tool center overview description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: NSLocalizedString("配置已启用 %d / %d", comment: "Configured enabled count"),
                        ToolCatalogSupport.configuredEnabledCount(for: builtInStates),
                        builtInStates.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("当前会话实际可用 %d / %d", comment: "Currently available count"),
                        ToolCatalogSupport.availableCount(for: builtInStates),
                        builtInStates.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("MCP 工具：配置已启用 %d / %d", comment: "MCP configured count"),
                        configuredMCPCount,
                        mcpManager.tools.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("MCP 工具：当前会话实际可用 %d / %d", comment: "MCP available count"),
                        availableMCPCount,
                        mcpManager.tools.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("拓展工具：配置已启用 %d / %d", comment: "App tool configured count"),
                        configuredAppToolCount,
                        appToolManager.tools.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("拓展工具：当前会话实际可用 %d / %d", comment: "App tool available count"),
                        availableAppToolCount,
                        appToolManager.tools.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("快捷指令工具：配置已启用 %d / %d", comment: "Shortcut configured count"),
                        configuredShortcutCount,
                        shortcutManager.tools.count
                    )
                )
                .font(.caption2)
                Text(
                    String(
                        format: NSLocalizedString("快捷指令工具：当前会话实际可用 %d / %d", comment: "Shortcut available count"),
                        availableShortcutCount,
                        shortcutManager.tools.count
                    )
                )
                .font(.caption2)
                if currentSessionIsolationActive {
                    Text(NSLocalizedString("当前会话已启用世界书隔离发送，聊天时不会发送记忆、MCP 与快捷指令工具。", comment: "Worldbook isolation warning in tool center"))
                        .font(.caption2)
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
                footer: Text(NSLocalizedString("内置工具会直接影响聊天时是否向模型暴露记忆相关能力。", comment: "Built-in tools footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("启用长期记忆系统", comment: "Enable long-term memory"),
                    isOn: $enableMemory
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
                                .font(.caption2)
                                .foregroundStyle(state.isAvailableInCurrentSession ? .green : .secondary)
                        }
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("MCP 工具", comment: "MCP tools section title")),
                footer: Text(NSLocalizedString("统一查看各个 MCP Server 公布的聊天工具，并集中调整启用状态与审批策略。", comment: "MCP tools footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露 MCP 工具", comment: "Expose MCP tools to model"),
                    isOn: Binding(
                        get: { mcpManager.chatToolsEnabled },
                        set: { mcpManager.setChatToolsEnabled($0) }
                    )
                )

                ForEach(filteredMCPTools) { available in
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
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(mcpStatusText(for: available))
                                .font(.caption2)
                                .foregroundStyle(mcpStatusColor(for: available))
                        }
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("拓展工具", comment: "App tools section title")),
                footer: Text(NSLocalizedString("这里用于承接后续要给 AI 写的本地工具，默认关闭，开启后才会暴露给模型。", comment: "App tools footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    NSLocalizedString("向模型暴露拓展工具", comment: "Expose app tools to model"),
                    isOn: Binding(
                        get: { appToolManager.chatToolsEnabled },
                        set: { appToolManager.setChatToolsEnabled($0) }
                    )
                )

                if !appToolManager.chatToolsEnabled {
                    Text(NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if appToolManager.tools.isEmpty {
                    Text(NSLocalizedString("当前还没有已注册的拓展工具。", comment: "No registered app tools"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredAppTools) { item in
                        NavigationLink {
                            WatchAppToolCenterDetailView(
                                kind: item.kind,
                                currentSessionIsolationActive: currentSessionIsolationActive
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.kind.displayName)
                                Text(item.kind.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(appToolStatusText(for: item))
                                    .font(.caption2)
                                    .foregroundStyle(appToolStatusColor(for: item))
                            }
                        }
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title")),
                footer: Text(NSLocalizedString("统一查看已导入的快捷指令工具，并集中调整启用状态、运行模式与描述。", comment: "Shortcut tools footer"))
                    .font(.footnote)
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
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(shortcutStatusText(for: tool))
                                .font(.caption2)
                                .foregroundStyle(shortcutStatusColor(for: tool))
                        }
                    }
                }
            }

            if filteredBuiltInStates.isEmpty && filteredAppTools.isEmpty && filteredMCPTools.isEmpty && filteredShortcutTools.isEmpty {
                Section {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具中心", comment: "Tool center title"))
    }

    private func builtInTitle(for kind: ToolCatalogBuiltInToolKind) -> String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("长期记忆写入", comment: "Memory write tool title")
        case .memorySearch:
            return NSLocalizedString("长期记忆主动检索", comment: "Memory search tool title")
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
                return NSLocalizedString("长期记忆总开关已关闭。", comment: "Memory system disabled")
            case .memoryWriteDisabled:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write disabled")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .activeRetrievalDisabled, .zeroTopK:
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
                return NSLocalizedString("长期记忆总开关已关闭。", comment: "Memory system disabled")
            case .activeRetrievalDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search disabled")
            case .zeroTopK:
                return NSLocalizedString("当前 Top K 为 0，聊天时不会暴露检索工具。", comment: "Memory search top k zero")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .memoryWriteDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search fallback")
            @unknown default:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search unknown status fallback")
            }
        @unknown default:
            return NSLocalizedString("该工具当前状态未知。", comment: "Built-in tool unknown kind fallback")
        }
    }

    private func mcpStatusText(for available: MCPAvailableTool) -> String {
        let isEnabled = mcpManager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
        let policy = mcpManager.approvalPolicy(serverID: available.server.id, toolId: available.tool.toolId)

        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !mcpManager.chatToolsEnabled {
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
        let isEnabled = mcpManager.isToolEnabled(serverID: available.server.id, toolId: available.tool.toolId)
        let policy = mcpManager.approvalPolicy(serverID: available.server.id, toolId: available.tool.toolId)
        if currentSessionIsolationActive || !mcpManager.chatToolsEnabled || !isEnabled || policy == .alwaysDeny {
            return .secondary
        }
        return .green
    }

    private func appToolStatusText(for item: AppToolCatalogItem) -> String {
        if currentSessionIsolationActive {
            return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
        }
        if !appToolManager.chatToolsEnabled {
            return NSLocalizedString("总开关关闭后，下面的单项配置会保留，但聊天时不会实际暴露这些工具。", comment: "Global switch off explanation")
        }
        return item.isEnabled
            ? NSLocalizedString("该工具当前可参与聊天。", comment: "Tool available in chat")
            : NSLocalizedString("当前未启用该拓展工具。", comment: "App tool disabled status")
    }

    private func appToolStatusColor(for item: AppToolCatalogItem) -> Color {
        if currentSessionIsolationActive || !appToolManager.chatToolsEnabled || !item.isEnabled {
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
}

private struct WatchAppToolCenterDetailView: View {
    let kind: AppToolKind
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = AppToolManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(kind.displayName)
                Text(kind.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: kind.parameters, fieldLimit: 4) {
                    Text("Schema: \(schemaSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .font(.caption2)
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

            Section(NSLocalizedString("工具描述", comment: "Tool description section")) {
                Text(kind.detailDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        return manager.isToolEnabled(kind)
            ? NSLocalizedString("该工具当前可参与聊天。", comment: "Tool available in chat")
            : NSLocalizedString("当前未启用该拓展工具。", comment: "App tool disabled status")
    }

    private var currentStatusColor: Color {
        if currentSessionIsolationActive || !manager.chatToolsEnabled || !manager.isToolEnabled(kind) {
            return .secondary
        }
        return .green
    }
}

private struct WatchBuiltInToolDetailView: View {
    let kind: ToolCatalogBuiltInToolKind
    let currentSessionIsolationActive: Bool

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
            isIsolatedSession: currentSessionIsolationActive
        ).first(where: { $0.kind == kind }) ?? ToolCatalogBuiltInToolState(
            kind: kind,
            isConfiguredEnabled: false,
            isAvailableInCurrentSession: false,
            statusReason: .memoryDisabled
        )
    }

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(statusText(for: state))
                    .font(.caption2)
                    .foregroundStyle(state.isAvailableInCurrentSession ? .green : .secondary)
            }

            switch kind {
            case .memoryWrite:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用长期记忆系统", comment: "Enable long-term memory"),
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
                        NSLocalizedString("启用长期记忆系统", comment: "Enable long-term memory"),
                        isOn: $enableMemory
                    )
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $enableMemoryActiveRetrieval
                    )
                    .disabled(!enableMemory)
                    HStack {
                        Text("Top K")
                        Spacer()
                        TextField(
                            "0",
                            value: $memoryTopK,
                            formatter: numberFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    }
                }
            @unknown default:
                Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                    Text(NSLocalizedString("该工具类型暂未提供可编辑设置。", comment: "Unknown built-in tool settings fallback"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
    }

    private var title: String {
        switch kind {
        case .memoryWrite:
            return NSLocalizedString("长期记忆写入", comment: "Memory write tool title")
        case .memorySearch:
            return NSLocalizedString("长期记忆主动检索", comment: "Memory search tool title")
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
        @unknown default:
            return NSLocalizedString("该内置工具当前可按配置参与聊天。", comment: "Built-in tool fallback subtitle")
        }
    }

    private func statusText(for state: ToolCatalogBuiltInToolState) -> String {
        switch state.kind {
        case .memoryWrite:
            switch state.statusReason {
            case .enabled:
                return NSLocalizedString("已允许写入新的记忆。", comment: "Memory write enabled")
            case .memoryDisabled:
                return NSLocalizedString("长期记忆总开关已关闭。", comment: "Memory system disabled")
            case .memoryWriteDisabled:
                return NSLocalizedString("当前未允许写入新的记忆。", comment: "Memory write disabled")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .activeRetrievalDisabled, .zeroTopK:
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
                return NSLocalizedString("长期记忆总开关已关闭。", comment: "Memory system disabled")
            case .activeRetrievalDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search disabled")
            case .zeroTopK:
                return NSLocalizedString("当前 Top K 为 0，聊天时不会暴露检索工具。", comment: "Memory search top k zero")
            case .isolatedByWorldbook:
                return NSLocalizedString("当前会话因世界书隔离发送而不会实际启用该工具。", comment: "Tool unavailable due to worldbook isolation")
            case .memoryWriteDisabled:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search fallback")
            @unknown default:
                return NSLocalizedString("当前未允许主动检索。", comment: "Memory search unknown status fallback")
            }
        @unknown default:
            return NSLocalizedString("该工具当前状态未知。", comment: "Built-in tool unknown kind fallback")
        }
    }
}

private struct WatchMCPToolCenterDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(tool.toolId)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.inputSchema, fieldLimit: 4) {
                    Text("Schema: \(schemaSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .font(.caption2)
                    .foregroundStyle(currentStatusColor)
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "Approval policy")),
                footer: Text(NSLocalizedString("默认每次询问，可在这里按工具单独调整。", comment: "Approval policy footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: "Approval policy"), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
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

private struct WatchShortcutToolCenterDetailView: View {
    let toolID: UUID
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = ShortcutToolManager.shared
    @State private var descriptionDraft: String = ""

    private var tool: ShortcutToolDefinition? {
        manager.tools.first(where: { $0.id == toolID })
    }

    var body: some View {
        List {
            if let tool {
                Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                    Text(tool.displayName)
                    Text(tool.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let importStatusText = importStatusText(for: tool) {
                        Text(importStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                    Text(currentStatusText(for: tool))
                        .font(.caption2)
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
                }

                Section(NSLocalizedString("自定义描述", comment: "Custom description section")) {
                    TextField(
                        NSLocalizedString("自定义描述", comment: "Custom description section"),
                        text: $descriptionDraft
                    )
                    Button(NSLocalizedString("保存", comment: "Save")) {
                        manager.updateUserDescription(id: tool.id, description: descriptionDraft)
                    }
                    Button(NSLocalizedString("重新生成", comment: "Regenerate description")) {
                        Task {
                            await manager.regenerateDescriptionWithLLM(for: tool.id)
                        }
                    }
                }
            } else {
                Text(NSLocalizedString("快捷指令不存在或已被删除。", comment: "Shortcut tool missing"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: "Tool settings title"))
        .onAppear {
            descriptionDraft = tool?.userDescription ?? ""
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
