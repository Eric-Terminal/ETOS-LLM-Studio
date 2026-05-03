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
                    ProgressView(NSLocalizedString("正在同步…", comment: ""))
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
                    Text(String(format: NSLocalizedString("倒计时：%ds", comment: ""), toolPermissionCenter.autoApproveCountdownSeconds))
                }
                .disabled(!toolPermissionCenter.autoApproveEnabled)
                let disabledCount = toolPermissionCenter.disabledAutoApproveTools.count
                Text(String(format: NSLocalizedString("已禁用自动批准工具：%d", comment: ""), disabledCount))
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
                                Text(String(format: NSLocalizedString("输入 Schema：%@", comment: ""), schemaSummary))
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
                                    Text(String(format: NSLocalizedString("进度 %.0f / %.0f", comment: ""), progress, total))
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: NSLocalizedString("进度 %.0f", comment: ""), progress))
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                if let timeout = call.timeout {
                                    Text(String(format: NSLocalizedString("空闲超时 %ds", comment: ""), Int(timeout)))
                                }
                                if let totalTimeout = call.maxTotalTimeout {
                                    Text(String(format: NSLocalizedString("总超时 %ds", comment: ""), Int(totalTimeout)))
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
                                Text(entry.serverDisplayName ?? NSLocalizedString("全局", comment: ""))
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
            return NSLocalizedString("未连接", comment: "")
        case .connecting:
            return NSLocalizedString("正在连接...", comment: "")
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return String(format: NSLocalizedString("重连中（第%d次，约 %ds）", comment: ""), attempt, remaining)
        case .ready:
            return status.isSelectedForChat
                ? NSLocalizedString("已连接并参与聊天", comment: "")
                : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
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
            return NSLocalizedString("运行中", comment: "")
        case .cancelling:
            return NSLocalizedString("取消中", comment: "")
        case .succeeded:
            return NSLocalizedString("成功", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        case .cancelled(let reason):
            if let reason, !reason.isEmpty {
                return String(format: NSLocalizedString("已取消：%@", comment: ""), reason)
            }
            return NSLocalizedString("已取消", comment: "")
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
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
