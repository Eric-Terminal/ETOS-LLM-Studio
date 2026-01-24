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
    @State private var didAutoConnectMCP = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(syncManager)
                .onAppear {
                    // 启动时自动同步（静默模式）
                    syncManager.performAutoSyncIfEnabled()
                    if !didAutoConnectMCP {
                        didAutoConnectMCP = true
                        MCPManager.shared.connectSelectedServersIfNeeded()
                    }
                }
        }
    }
}
