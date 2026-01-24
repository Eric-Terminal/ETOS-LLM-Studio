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
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
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
        .confirmationDialog("允许执行工具？", isPresented: Binding(
            get: { toolPermissionCenter.activeRequest != nil },
            set: { isPresented in
                if !isPresented, toolPermissionCenter.activeRequest != nil {
                    toolPermissionCenter.resolveActiveRequest(with: .deny)
                }
            }
        )) {
            Button("拒绝", role: .destructive) {
                toolPermissionCenter.resolveActiveRequest(with: .deny)
            }
            Button("允许本次") {
                toolPermissionCenter.resolveActiveRequest(with: .allowOnce)
            }
            Button("保持允许") {
                toolPermissionCenter.resolveActiveRequest(with: .allowForTool)
            }
            Button("完全权限") {
                toolPermissionCenter.resolveActiveRequest(with: .allowAll)
            }
        } message: {
            Text(toolPermissionPrompt(for: toolPermissionCenter.activeRequest))
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
    
    private func toolPermissionPrompt(for request: ToolPermissionRequest?) -> String {
        guard let request else { return "" }
        let toolName = request.displayName ?? request.toolName
        let trimmedArguments = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let cappedArguments: String
        if trimmedArguments.count > 600 {
            cappedArguments = String(trimmedArguments.prefix(600)) + "..."
        } else {
            cappedArguments = trimmedArguments
        }
        var message = "工具：\(toolName)"
        if !cappedArguments.isEmpty {
            message += "\n参数：\(cappedArguments)"
        }
        message += "\n\n拒绝：本次调用不执行\n允许本次：仅执行这一次\n保持允许：本次运行内同工具自动允许\n完全权限：本次运行内允许所有工具"
        return message
    }
}

enum ChatNavigationDestination: Hashable {
    case sessions
    case settings
}
