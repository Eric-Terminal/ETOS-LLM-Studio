// ============================================================================
// MCPIntegrationViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 工具箱的列表、概览、调试、日志和状态文案辅助。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

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
                        if !MCPBuiltInAppToolServer.isBuiltInServer(server) {
                            Button(role: .destructive) {
                                manager.delete(server: server)
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
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

}
