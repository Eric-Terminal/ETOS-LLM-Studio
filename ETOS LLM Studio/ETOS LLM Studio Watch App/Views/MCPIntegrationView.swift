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

    @ViewBuilder
    private var autoApproveFooter: some View {
        if toolPermissionCenter.autoApproveEnabled {
            Text(NSLocalizedString("倒计时范围 1-30 秒，超出会自动修正。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("MCP 工具箱", comment: "MCP toolbox intro title"),
                    summary: NSLocalizedString("在手表端查看服务器状态、工具能力和治理日志。", comment: "Watch MCP toolbox intro summary"),
                    details: NSLocalizedString("MCP 工具箱说明正文", comment: "MCP toolbox intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text(NSLocalizedString("聊天工具总开关", comment: "")),
                footer: Text(NSLocalizedString("关闭后不会向模型暴露任何 MCP 工具，但你仍可继续管理服务器和查看日志。", comment: ""))
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
                            serverSelectionRow(for: server)
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
                footer: autoApproveFooter
            ) {
                Toggle(NSLocalizedString("自动批准", comment: ""),
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )

                if toolPermissionCenter.autoApproveEnabled {
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
                }
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

            moreSection
        }
        .navigationTitle(NSLocalizedString("MCP", comment: "MCP navigation title"))
    }

    private func serverSelectionRow(for server: MCPServerConfiguration) -> some View {
        let isSelectedForChat = manager.status(for: server).isSelectedForChat

        return HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .opacity(isSelectedForChat ? 1 : 0)
                .accessibilityHidden(true)

            Text(server.displayName)
                .etFont(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            isSelectedForChat
                ? Text(NSLocalizedString("已选中用于聊天", comment: "MCP server selected for chat accessibility value"))
                : Text("")
        )
    }

    @ViewBuilder
    private var moreSection: some View {
        if !manager.restorableBuiltInServers.isEmpty {
            Section(NSLocalizedString("更多", comment: "")) {
                NavigationLink {
                    MCPBuiltInServerRestoreView()
                } label: {
                    Label(NSLocalizedString("内置工具", comment: "Built-in tools section title"), systemImage: "shippingbox.and.arrow.backward")
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

}
