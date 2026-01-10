// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建底部 TabView，包含聊天、会话、设置三个主要模块
// - 通过环境注入的 ChatViewModel 在各子视图间共享状态
// ============================================================================

import SwiftUI
import Shared

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @StateObject private var announcementManager = AnnouncementManager.shared
    @State private var selection: Tab = .chat
    
    enum Tab: Hashable {
        case chat
        case sessions
        case settings
    }
    
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(Tab.chat)
            
            NavigationStack {
                SessionListView()
            }
            .tabItem {
                Label("会话", systemImage: "list.bullet")
            }
            .tag(Tab.sessions)
            
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .alert("记忆系统需要更新", isPresented: $viewModel.showDimensionMismatchAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.dimensionMismatchMessage)
        }
        // MARK: - 公告弹窗
        .sheet(isPresented: $announcementManager.shouldShowAlert) {
            if let announcement = announcementManager.currentAnnouncement {
                AnnouncementAlertView(
                    announcement: announcement,
                    onDismiss: {
                        announcementManager.dismissAlert()
                    }
                )
            }
        }
        // 启动时检查公告
        .task {
            await announcementManager.checkAnnouncement()
        }
    }
}

enum ChatNavigationDestination: Hashable {
    case sessions
    case settings
}
