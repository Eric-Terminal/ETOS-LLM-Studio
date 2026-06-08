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
import ETOSCore

private enum MCPIntegrationTab: String, CaseIterable, Identifiable {
    case servers
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers:
            return NSLocalizedString("服务器", comment: "")
        case .tools:
            return NSLocalizedString("工具", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .servers:
            return "server.rack"
        case .tools:
            return "hammer"
        }
    }
}

struct MCPIntegrationView: View {
    @StateObject var manager = MCPManager.shared
    @StateObject var toolPermissionCenter = ToolPermissionCenter.shared
    @State var isPresentingEditor = false
    @State var serverToEdit: MCPServerConfiguration?
    @State var toolIdInput: String = ""
    @State var toolPayloadInput: String = "{}"
    @State var resourceIdInput: String = ""
    @State var resourceQueryInput: String = "{}"
    @State var localError: String?
    @State var selectedToolServerID: UUID?
    @State var selectedResourceServerID: UUID?
    @State var isShowingIntroDetails = false
    @State private var selectedTab: MCPIntegrationTab = .servers
    
    var body: some View {
        TabView(selection: $selectedTab) {
            managementList
                .tabItem {
                    Label(MCPIntegrationTab.servers.title, systemImage: MCPIntegrationTab.servers.iconName)
                }
                .tag(MCPIntegrationTab.servers)

            publishedToolsList
                .tabItem {
                    Label(MCPIntegrationTab.tools.title, systemImage: MCPIntegrationTab.tools.iconName)
                }
                .tag(MCPIntegrationTab.tools)
        }
        .navigationTitle(NSLocalizedString("MCP 工具箱", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .servers {
                    Button {
                        serverToEdit = nil
                        isPresentingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
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

    private var managementList: some View {
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
            
            serverListSection
            connectionOverviewSection
            approvalAutomationSection
            activeToolCallsSection
            resourceSection
            promptSection
            logSection
            governanceLogSection
            debugSection
            latestOutputSection
            latestErrorSection
        }
    }

    private var publishedToolsList: some View {
        List {
            publishedToolsSection
        }
    }
}
