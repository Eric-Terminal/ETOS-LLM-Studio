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
                    title: NSLocalizedString("MCP 工具箱", comment: "MCP toolbox intro title"),
                    summary: NSLocalizedString("统一管理 MCP Server 的连接、聊天暴露与能力调试。", comment: "MCP toolbox intro summary"),
                    details: NSLocalizedString("MCP 工具箱说明正文", comment: "MCP toolbox intro details"),
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
            logNavigationSection
            moreSection
        }
    }

    private var publishedToolsList: some View {
        List {
            publishedToolsSection
        }
    }
}
