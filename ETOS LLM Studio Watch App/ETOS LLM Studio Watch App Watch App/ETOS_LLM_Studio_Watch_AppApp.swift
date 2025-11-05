// ============================================================================
// ETOS_LLM_Studio_Watch_AppApp.swift
// ============================================================================
// ETOS LLM Studio Watch App 应用入口文件
//
// 定义内容:
// - 定义 App 的主体 (@main)
// - 设置应用的根视图为 ContentView
// ============================================================================

import SwiftUI
import Shared

@main
struct ETOS_LLM_Studio_Watch_AppApp: App {
    @StateObject private var syncManager = WatchSyncManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
        }
    }
}
