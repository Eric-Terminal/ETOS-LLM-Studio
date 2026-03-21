// ============================================================================
// ETOS_LLM_Studio_iOS_AppApp.swift
// ============================================================================
// ETOS LLM Studio iOS App 应用入口文件
//
// 定义内容:
// - 定义 App 的主体 (@main)
// - 初始化 ChatViewModel 并将其注入到环境中
// - 设置应用的根视图为 ContentView
// - 启动时自动同步（如果已启用）
// ============================================================================

import SwiftUI
import Shared

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var syncManager = WatchSyncManager.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var dailyPulseDeliveryCoordinator = DailyPulseDeliveryCoordinator.shared

    init() {
        DailyPulseDeliveryCoordinator.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(syncManager)
                .environmentObject(cloudSyncManager)
                .onOpenURL { url in
                    Task {
                        _ = await ShortcutURLRouter.shared.handleIncomingURL(url)
                    }
                }
                .onAppear {
                    // 启动时自动同步（静默模式）
                    syncManager.performAutoSyncIfEnabled()
                    cloudSyncManager.performAutoSyncIfEnabled()
                    // 启动时自动重连已加入聊天路由的 MCP 服务器
                    mcpManager.connectSelectedServersIfNeeded()
                    dailyPulseDeliveryCoordinator.activate()
                }
        }
    }
}
