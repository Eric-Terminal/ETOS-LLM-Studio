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
import ETOSCore

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

    private var serversBinding: Binding<[MCPServerConfiguration]> {
        Binding {
            manager.servers
        } set: { orderedServers in
            manager.setServerOrder(orderedServers.map(\.id))
        }
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
                    ForEach(serversBinding, id: \.id, editActions: .move) { $server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            serverSummaryRow(for: server)
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

    private func settingsIntroCard(
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

    private func statusDescription(for server: MCPServerConfiguration) -> String {
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

    private func serverSummaryRow(for server: MCPServerConfiguration) -> some View {
        let connectionBadge = serverConnectionBadge(for: server)
        let transportBadge = serverTransportBadge(for: server)
        let toolsBadge = serverToolsBadge(for: server)

        return VStack(alignment: .leading, spacing: 6) {
            Text(server.displayName)
                .etFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    WatchMCPServerSummaryBadge(text: connectionBadge.text, color: connectionBadge.color)
                    WatchMCPServerSummaryBadge(text: transportBadge.text, color: transportBadge.color)
                    WatchMCPServerSummaryBadge(text: toolsBadge.text, color: toolsBadge.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        WatchMCPServerSummaryBadge(text: connectionBadge.text, color: connectionBadge.color)
                        WatchMCPServerSummaryBadge(text: transportBadge.text, color: transportBadge.color)
                    }
                    WatchMCPServerSummaryBadge(text: toolsBadge.text, color: toolsBadge.color)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func serverConnectionBadge(for server: MCPServerConfiguration) -> (text: String, color: Color) {
        switch manager.status(for: server).connectionState {
        case .idle:
            return (NSLocalizedString("未连接", comment: "MCP server list connection badge"), .secondary)
        case .connecting:
            return (NSLocalizedString("连接中", comment: "MCP server list connection badge"), .blue)
        case .reconnecting:
            return (NSLocalizedString("重连中", comment: "MCP server list connection badge"), .orange)
        case .ready:
            return (NSLocalizedString("已连接", comment: "MCP server list connection badge"), .green)
        case .failed:
            return (NSLocalizedString("失败", comment: "MCP server list connection badge"), .red)
        @unknown default:
            return (NSLocalizedString("未知", comment: "MCP server list connection badge"), .secondary)
        }
    }

    private func serverTransportBadge(for server: MCPServerConfiguration) -> (text: String, color: Color) {
        switch server.transport {
        case .builtInSearch, .builtInAppTool:
            return (NSLocalizedString("内置", comment: "MCP server transport badge"), .indigo)
        case .http:
            return (NSLocalizedString("HTTP", comment: "MCP server transport badge"), .blue)
        case .httpSSE:
            return (NSLocalizedString("SSE", comment: "MCP server transport badge"), .purple)
        case .oauth:
            return (NSLocalizedString("OAuth", comment: "MCP server transport badge"), .blue)
        }
    }

    private func serverToolsBadge(for server: MCPServerConfiguration) -> (text: String, color: Color) {
        let tools = manager.status(for: server).tools
        let disabledToolIds = Set(server.disabledToolIds)
        let enabledCount = tools.filter { !disabledToolIds.contains($0.toolId) }.count
        let text = String(format: NSLocalizedString("工具：%d/%d", comment: "MCP server enabled/total tools badge"), enabledCount, tools.count)
        return (text, .secondary)
    }

    private func statusIcon(for server: MCPServerConfiguration) -> String? {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .ready: return status.isSelectedForChat ? "checkmark.circle.fill" : "checkmark"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return status.isSelectedForChat ? "checkmark.circle.fill" : nil
        @unknown default: return "questionmark.circle"
        }
    }

    private func statusColor(for server: MCPServerConfiguration) -> Color {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .ready: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return status.isSelectedForChat ? .green : .secondary
        @unknown default: return .secondary
        }
    }
}

private struct WatchMCPServerSummaryBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .etFont(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.28), lineWidth: 1)
            }
    }
}
