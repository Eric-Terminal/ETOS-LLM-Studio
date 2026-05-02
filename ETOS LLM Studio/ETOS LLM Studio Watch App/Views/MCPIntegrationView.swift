// ============================================================================
// MCPIntegrationView.swift
// ============================================================================
// MCPIntegrationView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

//
//  MCPIntegrationView.swift
//  ETOS LLM Studio Watch App
//

import SwiftUI
import Foundation
import Shared

struct MCPIntegrationView: View {
    @StateObject var manager = MCPManager.shared
    @StateObject var toolPermissionCenter = ToolPermissionCenter.shared
    @State var isShowingIntroDetails = false
    
    var countdownNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "MCP 工具箱",
                    summary: "在手表端查看服务器状态，并快速进入 MCP 调试。",
                    details: """
                    快速上手
                    1. 在“服务器管理”确认至少一台服务器已连接。
                    2. 打开“向模型暴露 MCP 工具”总开关。
                    3. 在“能力概览”检查工具与资源是否已发布。
                    4. 用“调试面板”验证调用是否正常。

                    关键项说明
                    • 连接状态：已连接 / 聊天使用 / 重连中 / 失败。
                    • 自动批准：审批倒计时（1~30 秒）。
                    • 调用工具：手动测试工具执行链路。
                    • 读取资源：手动验证资源读取能力。

                    提示
                    • watch 端主要用于查看与快速排查；
                    • 复杂配置建议在 iPhone 端完成后同步到手表。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("聊天工具总开关", comment: "")),
                footer: Text(NSLocalizedString("关闭后不会向模型暴露任何 MCP 工具，但你仍可继续管理服务器和手动调试。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("向模型暴露 MCP 工具", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }
            
            Section(NSLocalizedString("服务器管理", comment: "")) {
                if manager.servers.isEmpty {
                    Text(NSLocalizedString("尚未添加服务器，点击下方入口新建。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .etFont(.headline)
                                    Text(server.humanReadableEndpoint)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(statusDescription(for: server))
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if manager.status(for: server).isSelectedForChat {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                Image(systemName: statusIcon(for: server))
                                    .foregroundStyle(statusColor(for: server))
                            }
                        }
                    }
                }
                
                NavigationLink {
                    MCPServerEditor(existingServer: nil) {
                        manager.save(server: $0)
                    }
                } label: {
                    Label(NSLocalizedString("新增 MCP Server", comment: ""), systemImage: "plus.circle")
                }
            }
            
            Section(NSLocalizedString("连接状态", comment: "")) {
                let connected = manager.connectedServers().count
                let selected = manager.selectedServers().count
                Text(
                    String(
                        format: NSLocalizedString("已连接 %d 台，聊天使用 %d 台。", comment: ""),
                        connected,
                        selected
                    )
                )
                    .etFont(.caption2)
                Button(NSLocalizedString("刷新", comment: "")) {
                    manager.refreshMetadata()
                }
                .disabled(manager.isBusy || connected == 0)
                
                if manager.isBusy {
                    ProgressView(NSLocalizedString("同步中…", comment: ""))
                }
            }

            Section(
                header: Text(NSLocalizedString("审批自动化", comment: "")),
                footer: Text(NSLocalizedString("倒计时范围 1-30 秒，超出会自动修正。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("自动批准", comment: ""),
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )
                
                HStack {
                    Text(NSLocalizedString("倒计时秒数", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""),
                        value: Binding(
                            get: { toolPermissionCenter.autoApproveCountdownSeconds },
                            set: { toolPermissionCenter.setAutoApproveCountdownSeconds($0) }
                        ),
                        formatter: countdownNumberFormatter
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                }
                .disabled(!toolPermissionCenter.autoApproveEnabled)
            }

            Section(NSLocalizedString("治理日志", comment: "")) {
                NavigationLink {
                    MCPGovernanceLogListView()
                } label: {
                    HStack {
                        Label(NSLocalizedString("查看治理日志", comment: ""), systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text("\(manager.governanceLogEntries.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(manager.governanceLogEntries.isEmpty)
            }
            
            Section(NSLocalizedString("能力概览", comment: "")) {
                HStack {
                    Label(
                        String(format: NSLocalizedString("工具 %d", comment: ""), manager.tools.count),
                        systemImage: "hammer"
                    )
                    Spacer()
                    NavigationLink(NSLocalizedString("查看列表", comment: "")) {
                        MCPToolListView()
                    }
                    .disabled(manager.tools.isEmpty)
                }
                HStack {
                    Label(
                        String(format: NSLocalizedString("资源 %d", comment: ""), manager.resources.count),
                        systemImage: "doc.plaintext"
                    )
                    Spacer()
                    NavigationLink(NSLocalizedString("查看列表", comment: "")) {
                        MCPResourceListView()
                    }
                    .disabled(manager.resources.isEmpty)
                }
            }
            
            Section(NSLocalizedString("调试面板", comment: "")) {
                NavigationLink {
                    MCPToolDebuggerView()
                } label: {
                    Label(NSLocalizedString("调用工具", comment: ""), systemImage: "play.circle")
                }
                NavigationLink {
                    MCPResourceDebuggerView()
                } label: {
                    Label(NSLocalizedString("读取资源", comment: ""), systemImage: "tray.and.arrow.down")
                }
                
                if manager.lastOperationOutput != nil || manager.lastOperationError != nil {
                    NavigationLink {
                        MCPResponseDetailView(
                            output: manager.lastOperationOutput,
                            error: manager.lastOperationError
                        )
                    } label: {
                        Label(NSLocalizedString("查看最新响应", comment: ""), systemImage: "text.bubble")
                    }
                }
            }

            if !manager.activeToolCalls.isEmpty {
                Section(NSLocalizedString("活跃调用", comment: "")) {
                    ForEach(manager.activeToolCalls.values.sorted(by: { $0.startedAt > $1.startedAt }), id: \.id) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(call.serverDisplayName) · \(call.toolId)")
                                .etFont(.footnote)
                            if let progress = call.latestProgress, let total = call.latestTotal, total > 0 {
                                ProgressView(value: min(max(progress / total, 0), 1))
                            }
                            Button(NSLocalizedString("取消", comment: ""), role: .destructive) {
                                manager.cancelToolCall(callID: call.id, reason: NSLocalizedString("用户在手表取消调用", comment: ""))
                            }
                            .etFont(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("MCP")
    }

    func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "MCP 介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "MCP 介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "MCP 介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
    
    func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return NSLocalizedString("未连接", comment: "")
        case .connecting:
            return NSLocalizedString("连接中", comment: "")
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return String(format: NSLocalizedString("重连中 %d 次 (%ds)", comment: ""), attempt, remaining)
        case .ready:
            return status.isSelectedForChat ? NSLocalizedString("聊天使用", comment: "") : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
        }
    }
    
    func statusIcon(for server: MCPServerConfiguration) -> String {
        switch manager.status(for: server).connectionState {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .idle: return "circle"
        @unknown default: return "questionmark.circle"
        }
    }
    
    func statusColor(for server: MCPServerConfiguration) -> Color {
        switch manager.status(for: server).connectionState {
        case .ready: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        @unknown default: return .secondary
        }
    }
}


// MARK: - Server Detail

struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject var manager = MCPManager.shared
    @Environment(\.dismiss) var dismiss
    @State var showingDeleteConfirmation = false
    
    var server: MCPServerConfiguration? {
        manager.servers.first(where: { $0.id == serverID })
    }
    
    var body: some View {
        List {
            if let server {
                let status = manager.status(for: server)
                Section(NSLocalizedString("服务器信息", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: ""), value: server.displayName)
                    LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                    if let notes = server.notes {
                        LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                    }
                    Text(statusDescription(for: server))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Section(NSLocalizedString("连接控制", comment: "")) {
                    Button(NSLocalizedString("连接", comment: "")) {
                        manager.connect(to: server)
                    }
                    .disabled(status.connectionState == .ready || status.connectionState == .connecting || isReconnecting(status.connectionState))
                    
                    Button(NSLocalizedString("断开", comment: "")) {
                        manager.disconnect(server: server)
                    }
                    .disabled(status.connectionState == .idle)

                    Button(NSLocalizedString("终止远端会话", comment: "")) {
                        Task {
                            await manager.terminateRemoteSession(for: server.id)
                        }
                    }
                    .disabled(status.connectionState == .idle)
                    
                    Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: Binding(
                        get: { manager.status(for: server).isSelectedForChat },
                        set: { newValue in
                            let current = manager.status(for: server).isSelectedForChat
                            if newValue != current {
                                manager.toggleSelection(for: server)
                            }
                        }
                    ))
                    .disabled(status.connectionState == .connecting || isReconnecting(status.connectionState))
                    
                    Button(NSLocalizedString("刷新工具/资源", comment: "")) {
                        manager.refreshMetadata(for: server)
                    }
                    .disabled(status.connectionState != .ready || status.isBusy)
                    
                    if status.isBusy {
                        ProgressView()
                    }
                }

                Section(NSLocalizedString("工具", comment: "")) {
                    if status.tools.isEmpty {
                        Text(NSLocalizedString("当前服务器尚未公布任何工具。", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.tools) { tool in
                            NavigationLink {
                                MCPToolSettingsDetailView(serverID: server.id, tool: tool)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(tool.toolId)
                                        Spacer()
                                        Text(manager.isToolEnabled(serverID: server.id, toolId: tool.toolId) ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("已停用", comment: ""))
                                            .etFont(.caption2)
                                            .foregroundStyle(
                                                manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                                    ? Color.green
                                                    : Color.secondary
                                            )
                                    }
                                    if let desc = tool.description, !desc.isEmpty {
                                        Text(desc)
                                            .etFont(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                                        Text("Schema: \(schemaSummary)")
                                            .etFont(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(3)
                                    }
                                    Text(NSLocalizedString("点击进入二级菜单配置开关与审批策略", comment: ""))
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                
                Section(NSLocalizedString("管理", comment: "")) {
                    NavigationLink(NSLocalizedString("编辑配置", comment: "")) {
                        MCPServerEditor(existingServer: server) {
                            manager.save(server: $0)
                        }
                    }
                    
                    Button(NSLocalizedString("删除服务器", comment: ""), role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            } else {
                Section {
                    Text(NSLocalizedString("该服务器已被删除。", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(server?.displayName ?? NSLocalizedString("服务器详情", comment: ""))
        .confirmationDialog(NSLocalizedString("确定要删除此服务器？", comment: ""), isPresented: $showingDeleteConfirmation) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let server {
                    manager.delete(server: server)
                }
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
    }

    func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return NSLocalizedString("未连接", comment: "")
        case .connecting:
            return NSLocalizedString("连接中", comment: "")
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return String(format: NSLocalizedString("重连中 %d 次 (%ds)", comment: ""), attempt, remaining)
        case .ready:
            return status.isSelectedForChat ? NSLocalizedString("聊天使用", comment: "") : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
        }
    }

    func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
    }

    func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        var segments: [String] = ["type=\(typeLabel)"]
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            segments.append("fields=\(properties.keys.sorted().prefix(4).joined(separator: ", "))")
        }
        return segments.joined(separator: " · ")
    }
}


struct MCPToolSettingsDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    @ObservedObject var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "")) {
                Text(tool.toolId)
                    .etFont(.headline)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }

            Section(NSLocalizedString("启用状态", comment: "")) {
                Toggle(NSLocalizedString("启用", comment: ""), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "")),
                footer: Text(NSLocalizedString("默认“每次询问”，可按工具单独设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: ""), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: ""))
    }

    var toolBinding: Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: tool.toolId, isEnabled: newValue)
        }
    }

    var toolApprovalPolicyBinding: Binding<MCPToolApprovalPolicy> {
        Binding {
            manager.approvalPolicy(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolApprovalPolicy(serverID: serverID, toolId: tool.toolId, policy: newValue)
        }
    }

    func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        var segments: [String] = ["type=\(typeLabel)"]
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            segments.append("fields=\(properties.keys.sorted().prefix(4).joined(separator: ", "))")
        }
        return segments.joined(separator: " · ")
    }
}


// MARK: - Tool & Resource Lists

struct MCPToolListView: View {
    @ObservedObject var manager = MCPManager.shared
    
    var body: some View {
        List {
            if !manager.chatToolsEnabled {
                Text(NSLocalizedString("当前总开关已关闭，以下工具仅用于查看与配置，不会参与聊天调用。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if manager.tools.isEmpty {
                Text(NSLocalizedString("当前服务器尚未公布任何工具。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.tools) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.tool.toolId)
                            .etFont(.headline)
                        Text(tool.server.displayName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = tool.tool.description, !description.isEmpty {
                            Text(description)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let schemaSummary = schemaSummary(for: tool.tool.inputSchema) {
                            Text("Schema: \(schemaSummary)")
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                        Text(tool.internalName)
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具列表", comment: ""))
    }

    func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            return "type=\(typeLabel) · fields=\(properties.keys.sorted().prefix(4).joined(separator: ", "))"
        }
        return "type=\(typeLabel)"
    }
}


struct MCPResourceListView: View {
    @ObservedObject var manager = MCPManager.shared
    
    var body: some View {
        List {
            if manager.resources.isEmpty {
                Text(NSLocalizedString("当前服务器尚未暴露资源。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.resources) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.resource.resourceId)
                            .etFont(.headline)
                        Text(resource.server.displayName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = resource.resource.description, !description.isEmpty {
                            Text(description)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("资源列表", comment: ""))
    }
}


struct MCPGovernanceLogListView: View {
    @ObservedObject var manager = MCPManager.shared

    var body: some View {
        List {
            if manager.governanceLogEntries.isEmpty {
                Text(NSLocalizedString("暂无治理日志。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.governanceLogEntries.suffix(80).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(entry.serverDisplayName ?? NSLocalizedString("全局", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .etFont(.footnote)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }

                Button(NSLocalizedString("清空治理日志", comment: ""), role: .destructive) {
                    manager.clearGovernanceLogEntries()
                }
            }
        }
        .navigationTitle(NSLocalizedString("治理日志", comment: ""))
    }
}


struct MCPResponseDetailView: View {
    let output: String?
    let error: String?
    
    var body: some View {
        List {
            if let output {
                Section("Result") {
                    Text(output)
                        .etFont(.system(.footnote, design: .monospaced))
                }
            }
            
            if let error {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            }
        }
        .navigationTitle(NSLocalizedString("最新响应", comment: ""))
    }
}


struct HeaderOverridesPreview {
    let text: String
    let isPlaceholder: Bool
}
