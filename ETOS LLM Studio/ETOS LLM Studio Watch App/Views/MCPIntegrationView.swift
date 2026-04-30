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
    @StateObject private var manager = MCPManager.shared
    @StateObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var isShowingIntroDetails = false
    
    private var countdownNumberFormatter: NumberFormatter {
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
                    ProgressView("同步中…")
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
                                manager.cancelToolCall(callID: call.id, reason: "用户在手表取消调用")
                            }
                            .etFont(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("MCP")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
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
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
    
    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中"
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return "重连中 \(attempt) 次 (\(remaining)s)"
        case .ready:
            return status.isSelectedForChat ? "聊天使用" : "已连接"
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }
    
    private func statusIcon(for server: MCPServerConfiguration) -> String {
        switch manager.status(for: server).connectionState {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .idle: return "circle"
        @unknown default: return "questionmark.circle"
        }
    }
    
    private func statusColor(for server: MCPServerConfiguration) -> Color {
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

private struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    
    private var server: MCPServerConfiguration? {
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
                                        Text(manager.isToolEnabled(serverID: server.id, toolId: tool.toolId) ? "已启用" : "已停用")
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
        .navigationTitle(server?.displayName ?? "服务器详情")
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

    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中"
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return "重连中 \(attempt) 次 (\(remaining)s)"
        case .ready:
            return status.isSelectedForChat ? "聊天使用" : "已连接"
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }

    private func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
    }

    private func schemaSummary(for schema: JSONValue?) -> String? {
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

private struct MCPToolSettingsDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    @ObservedObject private var manager = MCPManager.shared

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

    private func schemaSummary(for schema: JSONValue?) -> String? {
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

private struct MCPToolListView: View {
    @ObservedObject private var manager = MCPManager.shared
    
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

    private func schemaSummary(for schema: JSONValue?) -> String? {
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

private struct MCPResourceListView: View {
    @ObservedObject private var manager = MCPManager.shared
    
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

private struct MCPGovernanceLogListView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            if manager.governanceLogEntries.isEmpty {
                Text(NSLocalizedString("暂无治理日志。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.governanceLogEntries.suffix(80).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(entry.serverDisplayName ?? "全局")
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

// MARK: - Debugger Views

private struct MCPToolDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var toolIdInput: String = ""
    @State private var payloadInput: String = "{}"
    @State private var localError: String?
    @State private var selectedServerID: UUID?
    
    var body: some View {
        Form {
            Section(NSLocalizedString("工具标识", comment: "")) {
                Picker(NSLocalizedString("目标服务器", comment: ""), selection: $selectedServerID) {
                    Text(NSLocalizedString("请选择", comment: "")).tag(Optional<UUID>.none)
                    ForEach(manager.selectedServers().isEmpty ? manager.connectedServers() : manager.selectedServers()) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                TextField(NSLocalizedString("例如 filesystem/readFile", comment: ""), text: $toolIdInput.watchKeyboardNewlineBinding())
            }
            
            Section(NSLocalizedString("JSON 输入", comment: "")) {
                TextField(NSLocalizedString("JSON 参数", comment: ""), text: $payloadInput.watchKeyboardNewlineBinding())
            }
            
            if let localError {
                Section {
                    Text(localError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            Button(NSLocalizedString("执行工具", comment: "")) {
                executeTool()
            }
            .disabled(toolIdInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle(NSLocalizedString("调用工具", comment: ""))
    }
    
    private func executeTool() {
        do {
            let inputs = try decodeJSONDictionary(from: payloadInput)
            guard let serverID = resolveServerID() else {
                localError = "请选择已连接服务器。"
                return
            }
            manager.executeTool(on: serverID, toolId: toolIdInput.trimmingCharacters(in: .whitespacesAndNewlines), inputs: inputs)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func resolveServerID() -> UUID? {
        if let selectedServerID {
            return selectedServerID
        }
        if let preferred = manager.selectedServers().first?.id ?? manager.connectedServers().first?.id {
            selectedServerID = preferred
            return preferred
        }
        return nil
    }
}

private struct MCPResourceDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var resourceIdInput: String = ""
    @State private var queryInput: String = "{}"
    @State private var localError: String?
    @State private var selectedServerID: UUID?
    
    var body: some View {
        Form {
            Section(NSLocalizedString("资源标识", comment: "")) {
                Picker(NSLocalizedString("目标服务器", comment: ""), selection: $selectedServerID) {
                    Text(NSLocalizedString("请选择", comment: "")).tag(Optional<UUID>.none)
                    ForEach(manager.selectedServers().isEmpty ? manager.connectedServers() : manager.selectedServers()) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                TextField(NSLocalizedString("例如 documents/summary", comment: ""), text: $resourceIdInput.watchKeyboardNewlineBinding())
            }
            
            Section(NSLocalizedString("查询 JSON (可选)", comment: "")) {
                TextField(NSLocalizedString("JSON 查询", comment: ""), text: $queryInput.watchKeyboardNewlineBinding())
            }
            
            if let localError {
                Section {
                    Text(localError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            Button(NSLocalizedString("读取资源", comment: "")) {
                readResource()
            }
            .disabled(resourceIdInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle(NSLocalizedString("读取资源", comment: ""))
    }
    
    private func readResource() {
        do {
            let payload = try decodeJSONDictionary(from: queryInput)
            let query = payload.isEmpty ? nil : payload
            guard let serverID = resolveServerID() else {
                localError = "请选择已连接服务器。"
                return
            }
            manager.readResource(on: serverID, resourceId: resourceIdInput.trimmingCharacters(in: .whitespacesAndNewlines), query: query)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func resolveServerID() -> UUID? {
        if let selectedServerID {
            return selectedServerID
        }
        if let preferred = manager.selectedServers().first?.id ?? manager.connectedServers().first?.id {
            selectedServerID = preferred
            return preferred
        }
        return nil
    }
}

private struct MCPResponseDetailView: View {
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

// MARK: - Server Editor

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let existingServer: MCPServerConfiguration?
    private let onSave: (MCPServerConfiguration) -> Void
    
    @State private var displayName: String
    @State private var endpoint: String
    @State private var sseEndpoint: String
    @State private var apiKey: String
    @State private var tokenEndpoint: String
    @State private var clientID: String
    @State private var clientSecret: String
    @State private var oauthScope: String
    @State private var oauthGrantType: MCPOAuthGrantType
    @State private var oauthAuthorizationCode: String
    @State private var oauthRedirectURI: String
    @State private var oauthCodeVerifier: String
    @State private var transportOption: TransportOption
    @State private var notes: String
    @State private var headerOverrideEntries: [HeaderOverrideEntry]
    @State private var validationMessage: String?
    
    init(existingServer: MCPServerConfiguration?, onSave: @escaping (MCPServerConfiguration) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave
        
        if let server = existingServer {
            _displayName = State(initialValue: server.displayName)
            _notes = State(initialValue: server.notes ?? "")
            switch server.transport {
            case .http(let endpoint, let apiKey, _):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: server.additionalHeaders)
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .http)
                _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
                    ? [HeaderOverrideEntry(text: "")]
                    : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
            case .httpSSE(_, let sseEndpoint, let apiKey, _):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: server.additionalHeaders)
                _endpoint = State(initialValue: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseEndpoint).absoluteString)
                _sseEndpoint = State(initialValue: sseEndpoint.absoluteString)
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .sse)
                _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
                    ? [HeaderOverrideEntry(text: "")]
                    : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
            case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _tokenEndpoint = State(initialValue: tokenEndpoint.absoluteString)
                _clientID = State(initialValue: clientID)
                _clientSecret = State(initialValue: clientSecret ?? "")
                _oauthScope = State(initialValue: scope ?? "")
                _oauthGrantType = State(initialValue: grantType)
                _oauthAuthorizationCode = State(initialValue: authorizationCode ?? "")
                _oauthRedirectURI = State(initialValue: redirectURI ?? "")
                _oauthCodeVerifier = State(initialValue: codeVerifier ?? "")
                _apiKey = State(initialValue: "")
                _transportOption = State(initialValue: .oauth)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            @unknown default:
                _endpoint = State(initialValue: "")
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .http)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            }
        } else {
            _displayName = State(initialValue: "")
            _endpoint = State(initialValue: "")
            _sseEndpoint = State(initialValue: "")
            _apiKey = State(initialValue: "")
            _notes = State(initialValue: "")
            _tokenEndpoint = State(initialValue: "")
            _clientID = State(initialValue: "")
            _clientSecret = State(initialValue: "")
            _oauthScope = State(initialValue: "")
            _oauthGrantType = State(initialValue: .clientCredentials)
            _oauthAuthorizationCode = State(initialValue: "")
            _oauthRedirectURI = State(initialValue: "")
            _oauthCodeVerifier = State(initialValue: "")
            _transportOption = State(initialValue: .http)
            _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
        }
    }
    
    var body: some View {
        Form {
            Section(NSLocalizedString("基本信息", comment: "")) {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $displayName.watchKeyboardNewlineBinding())
                Picker(NSLocalizedString("传输类型", comment: ""), selection: $transportOption) {
                    ForEach(TransportOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                if transportOption == .sse {
                    TextField("SSE Endpoint", text: $sseEndpoint.watchKeyboardNewlineBinding())
                } else {
                    TextField("Streamable HTTP Endpoint", text: $endpoint.watchKeyboardNewlineBinding())
                }
                if transportOption.requiresAPIKey {
                    TextField(NSLocalizedString("Bearer API Key (可选)", comment: ""), text: $apiKey.watchKeyboardNewlineBinding())
                }
                if transportOption == .oauth {
                    Picker(NSLocalizedString("授权类型", comment: ""), selection: $oauthGrantType) {
                        Text("Client Credentials").tag(MCPOAuthGrantType.clientCredentials)
                        Text("Authorization Code").tag(MCPOAuthGrantType.authorizationCode)
                    }
                    TextField("OAuth Token Endpoint", text: $tokenEndpoint.watchKeyboardNewlineBinding())
                    TextField("Client ID", text: $clientID.watchKeyboardNewlineBinding())
                    SecureField(NSLocalizedString("Client Secret (可选)", comment: ""), text: $clientSecret.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("Scope (可选)", comment: ""), text: $oauthScope.watchKeyboardNewlineBinding())
                    if oauthGrantType == .authorizationCode {
                        TextField("Authorization Code", text: $oauthAuthorizationCode.watchKeyboardNewlineBinding())
                        TextField("Redirect URI", text: $oauthRedirectURI.watchKeyboardNewlineBinding())
                        TextField(NSLocalizedString("PKCE Code Verifier (可选)", comment: ""), text: $oauthCodeVerifier.watchKeyboardNewlineBinding())
                    }
                }
                TextField(NSLocalizedString("备注 (可选)", comment: ""), text: $notes.watchKeyboardNewlineBinding())
            }

            if transportOption.requiresAPIKey {
                Section(header: Text(NSLocalizedString("请求头覆盖", comment: "")), footer: Text(headerOverridesHint)) {
                    ForEach($headerOverrideEntries) { $entry in
                        HeaderOverrideRow(entry: $entry)
                            .onChange(of: entry.text) { _, _ in
                                validateHeaderOverrideEntry(withId: entry.id)
                            }
                    }
                    .onDelete(perform: deleteHeaderOverrideEntries)

                    Button(NSLocalizedString("添加表达式", comment: "")) {
                        addHeaderOverrideEntry()
                    }
                }

                Section(header: Text(NSLocalizedString("请求头预览", comment: ""))) {
                    Text(headerOverridesPreview.text)
                        .etFont(.footnote.monospaced())
                        .foregroundStyle(headerOverridesPreview.isPlaceholder ? .secondary : .primary)
                }
            }
            
            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            }
        }
        .navigationTitle(existingServer == nil ? "新增服务器" : "编辑服务器")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("保存", comment: "")) {
                    saveServer()
                }
                .disabled(isSaveDisabled)
            }
        }
    }
    
    private func saveServer() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalHeaders: [String: String]
        if transportOption.requiresAPIKey {
            guard let builtHeaders = buildHeaderOverrides() else { return }
            additionalHeaders = builtHeaders
        } else {
            additionalHeaders = [:]
        }
        
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport: MCPServerConfiguration.Transport
        switch transportOption {
        case .http:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme,
                  scheme.lowercased().hasPrefix("http") else {
                validationMessage = "请提供合法的 Streamable HTTP 地址。"
                return
            }
            transport = .http(endpoint: url, apiKey: trimmedKey.isEmpty ? nil : trimmedKey, additionalHeaders: additionalHeaders)
        case .sse:
            let trimmedSSE = sseEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sseURL = URL(string: trimmedSSE),
                  let sseScheme = sseURL.scheme,
                  sseScheme.lowercased().hasPrefix("http") else {
                validationMessage = "请提供合法的 SSE Endpoint。"
                return
            }
            transport = .httpSSE(
                messageEndpoint: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseURL),
                sseEndpoint: sseURL,
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
                additionalHeaders: additionalHeaders
            )
        case .oauth:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme,
                  scheme.lowercased().hasPrefix("http") else {
                validationMessage = "请提供合法的 HTTP/HTTPS 地址。"
                return
            }
            let tokenString = tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tokenURL = URL(string: tokenString) else {
                validationMessage = "请提供合法的 Token Endpoint。"
                return
            }
            let clientIDTrimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientIDTrimmed.isEmpty else {
                validationMessage = "Client ID 不能为空。"
                return
            }
            let scopeTrimmed = oauthScope.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecretTrimmed = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let authorizationCodeTrimmed = oauthAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let redirectURITrimmed = oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            let codeVerifierTrimmed = oauthCodeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if oauthGrantType == .authorizationCode {
                guard !authorizationCodeTrimmed.isEmpty, !redirectURITrimmed.isEmpty else {
                    validationMessage = "授权码模式下，Authorization Code 与 Redirect URI 不能为空。"
                    return
                }
            }
            transport = .oauth(
                endpoint: url,
                tokenEndpoint: tokenURL,
                clientID: clientIDTrimmed,
                clientSecret: clientSecretTrimmed.isEmpty ? nil : clientSecretTrimmed,
                scope: scopeTrimmed.isEmpty ? nil : scopeTrimmed,
                grantType: oauthGrantType,
                authorizationCode: authorizationCodeTrimmed.isEmpty ? nil : authorizationCodeTrimmed,
                redirectURI: redirectURITrimmed.isEmpty ? nil : redirectURITrimmed,
                codeVerifier: codeVerifierTrimmed.isEmpty ? nil : codeVerifierTrimmed
            )
        }
        
        var server = existingServer ?? MCPServerConfiguration(displayName: trimmedName, notes: notesOrNil(), transport: transport)
        server.displayName = trimmedName
        server.notes = notesOrNil()
        server.transport = transport
        
        onSave(server)
        dismiss()
    }
    
    private func notesOrNil() -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    private func oauthFieldsValid() -> Bool {
        if transportOption == .oauth {
            let hasBaseFields = !tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasBaseFields else { return false }
            if oauthGrantType == .authorizationCode {
                return !oauthAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        return true
    }

    private var headerOverridesHint: String {
        NSLocalizedString("使用 key=value 添加请求头，例如: Authorization=Bearer {token}。\n{token} 会替换为上方 Bearer API Key 输入的值。", comment: "")
    }

    private var isSaveDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty ||
        (transportOption == .sse
         ? sseEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
         : endpoint.trimmingCharacters(in: .whitespaces).isEmpty) ||
        !oauthFieldsValid() ||
        (transportOption.requiresAPIKey && headerOverrideEntries.contains { $0.error != nil })
    }

    private func addHeaderOverrideEntry() {
        headerOverrideEntries.append(HeaderOverrideEntry(text: ""))
    }

    private func deleteHeaderOverrideEntries(at offsets: IndexSet) {
        headerOverrideEntries.remove(atOffsets: offsets)
        if headerOverrideEntries.isEmpty {
            addHeaderOverrideEntry()
        }
    }

    private func validateHeaderOverrideEntry(withId id: UUID) {
        guard let index = headerOverrideEntries.firstIndex(where: { $0.id == id }) else { return }
        var entry = headerOverrideEntries[index]
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entry.error = nil
            headerOverrideEntries[index] = entry
            return
        }

        do {
            _ = try HeaderExpressionParser.parse(trimmed)
            entry.error = nil
        } catch {
            entry.error = error.localizedDescription
        }
        headerOverrideEntries[index] = entry
    }

    private func buildHeaderOverrides() -> [String: String]? {
        var updatedEntries = headerOverrideEntries
        var parsedExpressions: [HeaderExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            let trimmed = updatedEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                updatedEntries[index].error = nil
                continue
            }

            do {
                let parsed = try HeaderExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
                updatedEntries[index].error = nil
            } catch {
                updatedEntries[index].error = error.localizedDescription
                hasError = true
            }
        }

        headerOverrideEntries = updatedEntries
        if hasError {
            return nil
        }
        return HeaderExpressionParser.buildHeaders(from: parsedExpressions)
    }

    private var headerOverridesPreview: HeaderOverridesPreview {
        let result = previewHeaderOverrides()
        if result.hasError {
            return HeaderOverridesPreview(
                text: NSLocalizedString("表达式有误，无法预览", comment: ""),
                isPlaceholder: true
            )
        }
        if result.headers.isEmpty {
            return HeaderOverridesPreview(
                text: NSLocalizedString("暂无请求头表达式", comment: ""),
                isPlaceholder: true
            )
        }
        return HeaderOverridesPreview(
            text: prettyPrintedJSON(result.headers),
            isPlaceholder: false
        )
    }

    private func previewHeaderOverrides() -> (headers: [String: String], hasError: Bool) {
        var headers: [String: String] = [:]
        var hasError = false

        for entry in headerOverrideEntries {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let parsed = try HeaderExpressionParser.parse(trimmed)
                headers[parsed.key] = parsed.value
            } catch {
                hasError = true
            }
        }

        return (headers: headers, hasError: hasError)
    }

    private func prettyPrintedJSON(_ headers: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(headers),
              let data = try? JSONSerialization.data(withJSONObject: headers, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(headers)"
        }
        return string
    }
    
    private enum TransportOption: String, CaseIterable, Identifiable {
        case http
        case sse
        case oauth
        
        var id: String { rawValue }
        
        var label: String {
            switch self {
            case .http: return "Streamable HTTP"
            case .sse: return "SSE"
            case .oauth: return "OAuth 2.0"
            }
        }
        
        var requiresAPIKey: Bool {
            switch self {
            case .http, .sse: return true
            case .oauth: return false
            }
        }
    }
}

private struct HeaderOverridesPreview {
    let text: String
    let isPlaceholder: Bool
}

private struct HeaderOverrideEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var error: String?

    init(id: UUID = UUID(), text: String, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

private struct HeaderOverrideRow: View {
    @Binding var entry: HeaderOverrideEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(NSLocalizedString("请求头表达式，例如 User-Agent=Mozilla/5.0", comment: ""), text: $entry.text.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Helpers

private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    let data = Data(trimmed.utf8)
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
}
