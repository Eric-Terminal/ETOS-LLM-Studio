// ============================================================================
// MCPIntegrationView.swift
// ============================================================================
// MCPIntegrationView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

//
//  MCPIntegrationView.swift
//  ETOS LLM Studio iOS App
//
//  创建一个用于管理 MCP Server 的交互界面。
//

import SwiftUI
import Foundation
import Shared

struct MCPIntegrationView: View {
    @StateObject private var manager = MCPManager.shared
    @StateObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var isPresentingEditor = false
    @State private var serverToEdit: MCPServerConfiguration?
    @State private var toolIdInput: String = ""
    @State private var toolPayloadInput: String = "{}"
    @State private var resourceIdInput: String = ""
    @State private var resourceQueryInput: String = "{}"
    @State private var localError: String?
    @State private var selectedToolServerID: UUID?
    @State private var selectedResourceServerID: UUID?
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "MCP 工具箱",
                    summary: "统一管理 MCP Server 的连接、聊天暴露与能力调试。",
                    details: """
                    适用场景
                    • 你想把外部服务能力接入聊天（例如检索、执行工具、读取资源）。
                    • 你需要快速定位“为什么工具没被模型调用”这类问题。

                    怎么用（建议顺序）
                    1. 在“已配置服务器”添加或编辑 MCP Server，先确保连接正常。
                    2. 打开“向模型暴露 MCP 工具”，否则聊天阶段不会调用 MCP。
                    3. 在“连接概览”确认“已连接数量 / 参与聊天数量”。
                    4. 用“快速调试”先做一次手动调用，确认参数、返回和超时策略都正常。

                    关键参数说明
                    • 倒计时自动批准：自动审批等待秒数，范围 1~30 秒。
                    • 工具 ID：必须填写服务端公布的 toolId。
                    • 工具 Payload（JSON）：调用参数对象，必须是合法 JSON 字典。
                    • 资源 ID：资源读取标识符。
                    • 资源 Query（JSON）：可选查询参数，留空等价于不传。

                    常见状态解读
                    • 已连接并参与聊天：可被模型正常调用。
                    • 已连接：可调试，但当前未参与聊天。
                    • 重连中 / 失败：优先检查 Endpoint、鉴权头和网络可达性。

                    排查建议
                    • 模型不调用工具：先看总开关、工具是否启用、审批策略是否 alwaysDeny。
                    • 调用失败：看“活跃调用”“治理日志”“最新响应”三处信息定位。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("向模型暴露 MCP 工具", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            } header: {
                Text(NSLocalizedString("聊天工具总开关", comment: ""))
            } footer: {
                Text(NSLocalizedString("关闭后不会再把任何 MCP 工具提供给模型，也不会响应聊天中的 MCP 工具调用。服务器连接、调试和单项配置仍可继续使用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section(NSLocalizedString("已配置服务器", comment: "")) {
                if manager.servers.isEmpty {
                    Text(NSLocalizedString("尚未添加任何 MCP Server。点击右上角“＋”创建。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(server: server)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.displayName)
                                        .etFont(.headline)
                                    Text(server.humanReadableEndpoint)
                                        .etFont(.caption)
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
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.delete(server: server)
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                            Button {
                                serverToEdit = server
                                isPresentingEditor = true
                            } label: {
                                Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            
            Section(NSLocalizedString("连接概览", comment: "")) {
                let connectedCount = manager.connectedServers().count
                let selectedCount = manager.selectedServers().count
                Text(
                    String(
                        format: NSLocalizedString("已连接 %d 台，参与聊天 %d 台。", comment: ""),
                        connectedCount,
                        selectedCount
                    )
                )
                    .etFont(.footnote)
                Button(NSLocalizedString("刷新已连接服务器", comment: "")) {
                    manager.refreshMetadata()
                }
                .disabled(manager.isBusy || connectedCount == 0)
                
                if manager.isBusy {
                    ProgressView("正在同步…")
                }
            }

            Section(NSLocalizedString("审批自动化", comment: "")) {
                Toggle(NSLocalizedString("启用倒计时自动批准", comment: ""),
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )
                Stepper(
                    value: Binding(
                        get: { toolPermissionCenter.autoApproveCountdownSeconds },
                        set: { toolPermissionCenter.setAutoApproveCountdownSeconds($0) }
                    ),
                    in: 1...30
                ) {
                    Text("倒计时：\(toolPermissionCenter.autoApproveCountdownSeconds)s")
                }
                .disabled(!toolPermissionCenter.autoApproveEnabled)
                let disabledCount = toolPermissionCenter.disabledAutoApproveTools.count
                Text("已禁用自动批准工具：\(disabledCount)")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                if disabledCount > 0 {
                    Button(NSLocalizedString("清空禁用列表", comment: ""), role: .destructive) {
                        toolPermissionCenter.clearDisabledAutoApproveTools()
                    }
                }
            }
            
            if !manager.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("已公布工具 (%d)", comment: ""), manager.tools.count)
                ) {
                    if !manager.chatToolsEnabled {
                        Text(NSLocalizedString("当前总开关已关闭，以下工具仅用于查看与配置，不会参与聊天调用。", comment: ""))
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.tools) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.tool.toolId)
                                .etFont(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.tool.description, !desc.isEmpty {
                                Text(desc)
                                    .etFont(.footnote)
                            }
                            Text(
                                String(
                                    format: NSLocalizedString("内部名称：%@", comment: ""),
                                    available.internalName
                                )
                            )
                                .etFont(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            if let schemaSummary = schemaSummary(for: available.tool.inputSchema) {
                                Text("输入 Schema：\(schemaSummary)")
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !manager.activeToolCalls.isEmpty {
                Section(NSLocalizedString("活跃调用", comment: "")) {
                    ForEach(manager.activeToolCalls.values.sorted(by: { $0.startedAt > $1.startedAt }), id: \.id) { call in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(call.serverDisplayName) · \(call.toolId)")
                                    .etFont(.footnote.weight(.semibold))
                                Spacer()
                                Text(toolCallStateText(call.state))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let progress = call.latestProgress {
                                if let total = call.latestTotal, total > 0 {
                                    let fraction = min(max(progress / total, 0), 1)
                                    ProgressView(value: fraction)
                                    Text(String(format: "进度 %.0f / %.0f", progress, total))
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: "进度 %.0f", progress))
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                if let timeout = call.timeout {
                                    Text("空闲超时 \(Int(timeout))s")
                                }
                                if let totalTimeout = call.maxTotalTimeout {
                                    Text("总超时 \(Int(totalTimeout))s")
                                }
                            }
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                            Button(NSLocalizedString("取消调用", comment: ""), role: .destructive) {
                                manager.cancelToolCall(callID: call.id, reason: "用户在 MCP 工具箱取消")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
            if !manager.resources.isEmpty {
                Section(
                    String(format: NSLocalizedString("可用资源 (%d)", comment: ""), manager.resources.count)
                ) {
                    ForEach(manager.resources) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.resource.resourceId)
                                .etFont(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.resource.description, !desc.isEmpty {
                                Text(desc)
                                    .etFont(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !manager.prompts.isEmpty {
                Section(
                    String(format: NSLocalizedString("提示词模板 (%d)", comment: ""), manager.prompts.count)
                ) {
                    ForEach(manager.prompts) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.prompt.name)
                                .etFont(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.prompt.description, !desc.isEmpty {
                                Text(desc)
                                    .etFont(.footnote)
                            }
                            if let args = available.prompt.arguments, !args.isEmpty {
                                Text(
                                    String(
                                        format: NSLocalizedString("参数：%@", comment: ""),
                                        args.map { $0.name }.joined(separator: NSLocalizedString("，", comment: ""))
                                    )
                                )
                                    .etFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !manager.logEntries.isEmpty {
                Section {
                    ForEach(manager.logEntries.suffix(20).reversed(), id: \.self) { entry in
                        HStack {
                            logLevelIcon(entry.level)
                            VStack(alignment: .leading, spacing: 2) {
                                if let logger = entry.logger {
                                    Text(logger)
                                        .etFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let data = entry.data {
                                    Text(data.prettyPrintedCompact())
                                        .etFont(.system(.caption2, design: .monospaced))
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    Button(NSLocalizedString("清空日志", comment: ""), role: .destructive) {
                        manager.clearLogEntries()
                    }
                } header: {
                    Text(NSLocalizedString("服务器日志 (最近 20 条)", comment: ""))
                }
            }

            if !manager.governanceLogEntries.isEmpty {
                Section {
                    ForEach(manager.governanceLogEntries.suffix(40).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                governanceCategoryIcon(entry.category)
                                Text(entry.serverDisplayName ?? "全局")
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.timestamp, style: .time)
                                    .etFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.message)
                                .etFont(.footnote)
                            if let payload = entry.payload {
                                Text(payload.prettyPrintedCompact())
                                    .etFont(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button(NSLocalizedString("清空治理日志", comment: ""), role: .destructive) {
                        manager.clearGovernanceLogEntries()
                    }
                } header: {
                    Text(NSLocalizedString("治理日志 (最近 40 条)", comment: ""))
                }
            }
            
            Section(NSLocalizedString("快速调试", comment: "")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("调用工具", comment: ""))
                        .etFont(.subheadline)
                        .bold()
                    Picker(NSLocalizedString("目标服务器", comment: ""), selection: $selectedToolServerID) {
                        Text(NSLocalizedString("请选择", comment: "")).tag(Optional<UUID>.none)
                        ForEach(manager.selectedServers().isEmpty ? manager.connectedServers() : manager.selectedServers()) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    TextField(NSLocalizedString("工具 ID", comment: ""), text: $toolIdInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $toolPayloadInput)
                        .etFont(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                    Button(NSLocalizedString("执行工具", comment: "")) {
                        triggerToolExecution()
                    }
                    .disabled(manager.isBusy)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("读取资源", comment: ""))
                        .etFont(.subheadline)
                        .bold()
                    Picker(NSLocalizedString("目标服务器", comment: ""), selection: $selectedResourceServerID) {
                        Text(NSLocalizedString("请选择", comment: "")).tag(Optional<UUID>.none)
                        ForEach(manager.selectedServers().isEmpty ? manager.connectedServers() : manager.selectedServers()) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    TextField(NSLocalizedString("资源 ID", comment: ""), text: $resourceIdInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $resourceQueryInput)
                        .etFont(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                    Button(NSLocalizedString("读取资源", comment: "")) {
                        triggerResourceRead()
                    }
                    .disabled(manager.isBusy)
                }
                
                if let error = localError {
                    Text(error)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            if let output = manager.lastOperationOutput {
                Section(NSLocalizedString("最新响应", comment: "")) {
                    ScrollView(.vertical) {
                        Text(output)
                            .etFont(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120)
                }
            }
            
            if let error = manager.lastOperationError {
                Section(NSLocalizedString("错误信息", comment: "")) {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("MCP 工具箱", comment: ""))
        .toolbar {
            Button {
                serverToEdit = nil
                isPresentingEditor = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { serverToEdit = nil }) {
            NavigationStack {
                MCPServerEditor(existingServer: serverToEdit) { server in
                    manager.save(server: server)
                }
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
            Text(title)
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
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
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
    
    private func triggerToolExecution() {
        do {
            let payload = try decodeJSONDictionary(from: toolPayloadInput)
            guard let serverID = resolveServerSelection(forTool: true) else {
                localError = NSLocalizedString("请选择一个已连接的服务器。", comment: "")
                return
            }
            let toolID = toolIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
            manager.executeTool(on: serverID, toolId: toolID, inputs: payload)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func triggerResourceRead() {
        do {
            let payload = try decodeJSONDictionary(from: resourceQueryInput)
            guard let serverID = resolveServerSelection(forTool: false) else {
                localError = NSLocalizedString("请选择一个已连接的服务器。", comment: "")
                return
            }
            let query = payload.isEmpty ? nil : payload
            let resourceID = resourceIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
            manager.readResource(on: serverID, resourceId: resourceID, query: query)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func resolveServerSelection(forTool: Bool) -> UUID? {
        let explicit = forTool ? selectedToolServerID : selectedResourceServerID
        if let explicit { return explicit }
        if let preferred = manager.selectedServers().first?.id {
            if forTool {
                selectedToolServerID = preferred
            } else {
                selectedResourceServerID = preferred
            }
            return preferred
        }
        if let fallback = manager.connectedServers().first?.id {
            if forTool {
                selectedToolServerID = fallback
            } else {
                selectedResourceServerID = fallback
            }
            return fallback
        }
        return nil
    }
    
    private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func logLevelIcon(_ level: MCPLogLevel) -> some View {
        let (icon, color): (String, Color) = {
            switch level {
            case .debug:
                return ("ant", .gray)
            case .info:
                return ("info.circle", .blue)
            case .notice:
                return ("bell", .cyan)
            case .warning:
                return ("exclamationmark.triangle", .yellow)
            case .error:
                return ("xmark.circle", .red)
            case .critical, .alert, .emergency:
                return ("exclamationmark.octagon", .red)
            @unknown default:
                return ("questionmark.circle", .gray)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
    }

    private func governanceCategoryIcon(_ category: MCPGovernanceLogCategory) -> some View {
        let icon: String = {
            switch category {
            case .lifecycle:
                return "link"
            case .cache:
                return "externaldrive"
            case .routing:
                return "arrow.triangle.branch"
            case .toolCall:
                return "hammer"
            case .notification:
                return "bell"
            case .serverLog:
                return "doc.text"
            case .progress:
                return "gauge.with.dots.needle.67percent"
            @unknown default:
                return "questionmark.circle"
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(.secondary)
    }
    
    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "正在连接..."
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return "重连中（第\(attempt)次，约 \(remaining)s）"
        case .ready:
            return status.isSelectedForChat
                ? NSLocalizedString("已连接并参与聊天", comment: "")
                : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }
    
    private func statusIcon(for server: MCPServerConfiguration) -> String {
        let state = manager.status(for: server).connectionState
        switch state {
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .reconnecting:
            return "arrow.clockwise.circle.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle"
        case .idle:
            return "circle"
        @unknown default:
            return "questionmark.circle"
        }
    }
    
    private func statusColor(for server: MCPServerConfiguration) -> Color {
        let state = manager.status(for: server).connectionState
        switch state {
        case .ready:
            return .green
        case .connecting:
            return .blue
        case .reconnecting:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private func toolCallStateText(_ state: MCPToolCallState) -> String {
        switch state {
        case .running:
            return "运行中"
        case .cancelling:
            return "取消中"
        case .succeeded:
            return "成功"
        case .failed(let reason):
            return "失败：\(reason)"
        case .cancelled(let reason):
            if let reason, !reason.isEmpty {
                return "已取消：\(reason)"
            }
            return "已取消"
        @unknown default:
            return "未知状态"
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
            let keys = properties.keys.sorted()
            let previewKeys = keys.prefix(6).joined(separator: ", ")
            segments.append("fields=\(previewKeys)")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue,
           !requiredItems.isEmpty {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
    }
}

// MARK: - Server Detail

private struct MCPServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MCPManager.shared
    let server: MCPServerConfiguration
    @State private var isEditing = false
    @State private var showingDeleteConfirmation = false
    
    private var status: MCPServerStatus {
        manager.status(for: server)
    }
    
    var body: some View {
        Form {
            Section(NSLocalizedString("服务器信息", comment: "")) {
                LabeledContent(NSLocalizedString("名称", comment: ""), value: server.displayName)
                LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                if let notes = server.notes {
                    LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                }
            }
            
            Section(NSLocalizedString("连接控制", comment: "")) {
                Button(NSLocalizedString("连接", comment: "")) {
                    manager.connect(to: server)
                }
                .disabled(status.connectionState == .ready || status.connectionState == .connecting || isReconnecting(status.connectionState))
                
                Button(NSLocalizedString("断开连接", comment: "")) {
                    manager.disconnect(server: server)
                }
                .disabled(status.connectionState == .idle)

                Button(NSLocalizedString("终止远端会话", comment: "")) {
                    Task {
                        await manager.terminateRemoteSession(for: server.id)
                    }
                }
                .disabled(status.connectionState == .idle)
                
                Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: bindingForSelection())
                    .disabled(status.connectionState == .connecting || isReconnecting(status.connectionState))
                
                Button(NSLocalizedString("刷新元数据", comment: "")) {
                    manager.refreshMetadata(for: server)
                }
                .disabled(status.connectionState != .ready || status.isBusy)
                
                if status.isBusy {
                    ProgressView()
                }
            }
            
            if let info = status.info {
                Section(NSLocalizedString("服务器能力", comment: "")) {
                    Text(info.name + (info.version.map { " \($0)" } ?? ""))
                    if let capabilities = info.capabilities, !capabilities.isEmpty {
                        Text("Capabilities: \(capabilities.keys.joined(separator: ", "))")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            if !status.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("工具 (%d)", comment: ""), status.tools.count)
                ) {
                    ForEach(status.tools) { tool in
                        NavigationLink {
                            MCPToolSettingsDetailView(serverID: server.id, tool: tool)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(tool.toolId)
                                    Spacer()
                                    Text(
                                        manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                        ? NSLocalizedString("已启用", comment: "MCP tool enabled status")
                                        : NSLocalizedString("已停用", comment: "MCP tool disabled status")
                                    )
                                    .etFont(.caption)
                                    .foregroundStyle(
                                        manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                        ? .green
                                        : .secondary
                                    )
                                }
                                if let desc = tool.description {
                                    Text(desc)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                                    Text("输入 Schema：\(schemaSummary)")
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }
            }
            
            if !status.resources.isEmpty {
                Section(
                    String(format: NSLocalizedString("资源 (%d)", comment: ""), status.resources.count)
                ) {
                    ForEach(status.resources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.resourceId)
                            if let desc = resource.description {
                                Text(desc)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(server.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(NSLocalizedString("编辑", comment: "")) {
                    isEditing = true
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                MCPServerEditor(existingServer: server) { updated in
                    manager.save(server: updated)
                }
            }
        }
        .confirmationDialog(NSLocalizedString("确定要删除此服务器？", comment: ""), isPresented: $showingDeleteConfirmation) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                manager.delete(server: server)
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        }
    }
    
    private func bindingForSelection() -> Binding<Bool> {
        Binding {
            manager.status(for: server).isSelectedForChat
        } set: { newValue in
            let current = manager.status(for: server).isSelectedForChat
            if newValue != current {
                manager.toggleSelection(for: server)
            }
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
            segments.append("fields=\(properties.keys.sorted().prefix(6).joined(separator: ", "))")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
    }

    private func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
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

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
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
                .pickerStyle(.menu)
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
            segments.append("fields=\(properties.keys.sorted().prefix(6).joined(separator: ", "))")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
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
                TextField(NSLocalizedString("显示名称", comment: ""), text: $displayName)
                Picker(NSLocalizedString("传输类型", comment: ""), selection: $transportOption) {
                    ForEach(TransportOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                if transportOption == .sse {
                    TextField("SSE Endpoint", text: $sseEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("Streamable HTTP Endpoint", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if transportOption.requiresAPIKey {
                    TextField(NSLocalizedString("Bearer API Key (可选)", comment: ""), text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if transportOption == .oauth {
                    Picker(NSLocalizedString("授权类型", comment: ""), selection: $oauthGrantType) {
                        Text("Client Credentials").tag(MCPOAuthGrantType.clientCredentials)
                        Text("Authorization Code").tag(MCPOAuthGrantType.authorizationCode)
                    }
                    TextField("OAuth Token Endpoint", text: $tokenEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(NSLocalizedString("Client Secret (可选)", comment: ""), text: $clientSecret)
                    TextField(NSLocalizedString("Scope (可选)", comment: ""), text: $oauthScope)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if oauthGrantType == .authorizationCode {
                        TextField("Authorization Code", text: $oauthAuthorizationCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Redirect URI", text: $oauthRedirectURI)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField(NSLocalizedString("PKCE Code Verifier (可选)", comment: ""), text: $oauthCodeVerifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
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

                    Button {
                        addHeaderOverrideEntry()
                    } label: {
                        Label(NSLocalizedString("添加表达式", comment: ""), systemImage: "plus")
                    }
                }

                Section(header: Text(NSLocalizedString("请求头预览", comment: ""))) {
                    Text(headerOverridesPreview.text)
                        .etFont(.footnote.monospaced())
                        .foregroundStyle(headerOverridesPreview.isPlaceholder ? .secondary : .primary)
                        .textSelection(.enabled)
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
        .navigationTitle(existingServer == nil ? "新增 MCP Server" : "编辑 MCP Server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
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
                validationMessage = "请提供合法的 HTTP 或 HTTPS 地址。"
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
        VStack(alignment: .leading, spacing: 6) {
            TextField(NSLocalizedString("请求头表达式，例如 User-Agent=Mozilla/5.0", comment: ""), text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
