// ============================================================================
// ToolCenterDetailViews.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 工具中心页的拓展工具、MCP、内置工具与快捷指令详情视图。
// ============================================================================

import Foundation
import SwiftUI
import Shared

struct WatchAppToolCenterDetailView: View {
    let kind: AppToolKind
    let currentSessionIsolationActive: Bool

    @ObservedObject private var manager = AppToolManager.shared
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "Tool info section")) {
                Text(kind.displayName)
                Text(kind.detailDescription)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: kind.parameters, fieldLimit: 4) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .etFont(.caption2)
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

                    HStack {
                        Text(NSLocalizedString("倒计时秒数", comment: "Auto approve countdown label"))
                        Spacer()
                        TextField(
                            "1",
                            value: Binding(
                                get: { permissionCenter.autoApproveCountdownSeconds },
                                set: { permissionCenter.setAutoApproveCountdownSeconds($0) }
                            ),
                            formatter: countdownNumberFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
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

    private var countdownNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
}

struct WatchBuiltInToolDetailView: View {
    let kind: ToolCatalogBuiltInToolKind
    let currentSessionIsolationActive: Bool

    @ObservedObject private var appToolManager = AppToolManager.shared
    @EnvironmentObject private var appConfig: AppConfigStore

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var state: ToolCatalogBuiltInToolState {
        ToolCatalogSupport.builtInToolStates(
            enableMemory: appConfig.enableMemory,
            enableMemoryWrite: appConfig.enableMemoryWrite,
            enableMemoryActiveRetrieval: appConfig.enableMemoryActiveRetrieval,
            memoryTopK: appConfig.memoryTopK,
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
                Text(subtitle)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(statusText(for: state))
                    .etFont(.caption2)
                    .foregroundStyle(state.isAvailableInCurrentSession ? .green : .secondary)
            }

            switch kind {
            case .memoryWrite:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                        isOn: $appConfig.enableMemory
                    )
                    Toggle(
                        NSLocalizedString("允许写入新的记忆", comment: "Allow memory writing"),
                        isOn: $appConfig.enableMemoryWrite
                    )
                    .disabled(!appConfig.enableMemory)
                }
            case .memorySearch:
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用记忆系统", comment: "Enable long-term memory"),
                        isOn: $appConfig.enableMemory
                    )
                    Toggle(
                        NSLocalizedString("主动检索", comment: "Active retrieval toggle title"),
                        isOn: $appConfig.enableMemoryActiveRetrieval
                    )
                    .disabled(!appConfig.enableMemory)
                    HStack {
                        Text(NSLocalizedString("Top K", comment: "Memory search top k label"))
                        Spacer()
                        TextField(
                            "0",
                            value: $appConfig.memoryTopK,
                            formatter: numberFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
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
                        .etFont(.caption2)
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
}

struct WatchMCPToolCenterDetailView: View {
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
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = ToolCatalogSupport.schemaSummary(for: tool.inputSchema, fieldLimit: 4) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                Text(currentStatusText)
                    .etFont(.caption2)
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

struct WatchShortcutToolCenterDetailView: View {
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
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let importStatusText = importStatusText(for: tool) {
                        Text(importStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("当前状态", comment: "Current status section")) {
                    Text(currentStatusText(for: tool))
                        .etFont(.caption2)
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
