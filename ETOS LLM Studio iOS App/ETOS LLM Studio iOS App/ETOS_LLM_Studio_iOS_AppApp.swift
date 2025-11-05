// ============================================================================
// ETOS_LLM_Studio_iOS_AppApp.swift
// ============================================================================
// ETOS LLM Studio iOS App 应用入口文件
//
// 定义内容:
// - 定义 App 的主体 (@main)
// - 初始化 ChatViewModel 并将其注入到环境中
// - 设置应用的根视图为 ContentView
// ============================================================================

import SwiftUI
import Shared

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var syncManager = WatchSyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(syncManager)
        }
    }
}
