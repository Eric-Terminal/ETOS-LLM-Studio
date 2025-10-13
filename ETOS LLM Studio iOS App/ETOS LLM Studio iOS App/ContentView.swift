// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio iOS App 主视图文件
//
// 定义内容:
// - App 的根视图，包含一个 TabView
// - TabView 管理三个主要页面: 聊天、会话历史和设置
// ============================================================================

import SwiftUI
import Shared

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Label("聊天", systemImage: "message.fill")
                }
                .tag(0)

            NavigationStack {
                SessionListView(
                    sessions: $viewModel.chatSessions,
                    currentSession: $viewModel.currentSession,
                    deleteAction: { indexSet in
                        viewModel.deleteSession(at: indexSet)
                    },
                    branchAction: { session, copyMessages in
                        viewModel.branchSession(from: session, copyMessages: copyMessages)
                    },
                    exportAction: { session in
                        viewModel.activeSheet = .export(session)
                    },
                    deleteLastMessageAction: { session in
                        viewModel.deleteLastMessage(for: session)
                    },
                    onSessionSelected: { selectedSession in
                        ChatService.shared.setCurrentSession(selectedSession)
                        selectedTab = 0
                    },
                    saveSessionsAction: {
                        viewModel.forceSaveSessions()
                    }
                )
            }
                .tabItem {
                    Label("会话", systemImage: "list.bullet")
                }
                .tag(1)

            NavigationStack {
                SettingsView(viewModel: viewModel)
            }
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
                .tag(2)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatViewModel())
}