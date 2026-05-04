// ============================================================================
// MCPIntegrationViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 工具箱的列表、概览、调试、日志和状态文案辅助。
// ============================================================================

import SwiftUI
import Foundation
import Shared

extension MCPIntegrationView {
    var serverListSection: some View {
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
    }

    var connectionOverviewSection: some View {
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
    }

    var approvalAutomationSection: some View {
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
    }

    @ViewBuilder
    var publishedToolsSection: some View {
        if manager.tools.isEmpty {
            EmptyView()
        } else {
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
    }

    @ViewBuilder
    var activeToolCallsSection: some View {
        if manager.activeToolCalls.isEmpty {
            EmptyView()
        } else {
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
    }

    @ViewBuilder
    var resourceSection: some View {
        if manager.resources.isEmpty {
            EmptyView()
        } else {
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
    }

    @ViewBuilder
    var promptSection: some View {
        if manager.prompts.isEmpty {
            EmptyView()
        } else {
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
    }

    @ViewBuilder
    var logSection: some View {
        if manager.logEntries.isEmpty {
            EmptyView()
        } else {
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
    }

    @ViewBuilder
    var governanceLogSection: some View {
        if manager.governanceLogEntries.isEmpty {
            EmptyView()
        } else {
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
    }

    var debugSection: some View {
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
    }

    @ViewBuilder
    var latestOutputSection: some View {
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
    }

    @ViewBuilder
    var latestErrorSection: some View {
        if let error = manager.lastOperationError {
            Section(NSLocalizedString("错误信息", comment: "")) {
                Text(error)
                    .foregroundStyle(.red)
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

    func triggerToolExecution() {
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

    func triggerResourceRead() {
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

    func resolveServerSelection(forTool: Bool) -> UUID? {
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

    func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    func logLevelIcon(_ level: MCPLogLevel) -> some View {
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

    func governanceCategoryIcon(_ category: MCPGovernanceLogCategory) -> some View {
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

    func statusDescription(for server: MCPServerConfiguration) -> String {
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

    func statusIcon(for server: MCPServerConfiguration) -> String {
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

    func statusColor(for server: MCPServerConfiguration) -> Color {
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

    func toolCallStateText(_ state: MCPToolCallState) -> String {
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
