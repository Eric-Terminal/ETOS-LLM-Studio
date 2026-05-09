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
// - AppDelegate 处理 APNs 静默推送（B2：CloudKit 订阅唤醒）
// ============================================================================

import SwiftUI
import BackgroundTasks
import Shared

// MARK: - AppDelegate（B2：处理 APNs 静默推送）

/// 处理 APNs 静默推送：CloudKit zone 有变更时后台唤醒，触发增量同步。
/// ⚠️ 需在 Xcode Signing & Capabilities → Background Modes 开启 Remote notifications。
final class ETOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // 判断是否为 CloudKit 静默推送（ck 字段存在）
        guard userInfo["ck"] != nil else {
            completionHandler(.noData)
            return
        }
        // 触发 CloudSync 自动同步，再接力通知 Watch 端
        Task { @MainActor in
            CloudSyncManager.shared.performAutoSyncIfEnabled()
            // 同步完成后接力推送给 Apple Watch
            WatchSyncManager.shared.performAutoSyncIfEnabled()
            completionHandler(.newData)
        }
    }
}

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
    @UIApplicationDelegateAdaptor(ETOSAppDelegate.self) private var appDelegate
    @StateObject private var launchStateMachine = AppLaunchStateMachine()
    @StateObject private var syncManager = WatchSyncManager.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var dailyPulseManager = DailyPulseManager.shared
    @StateObject private var dailyPulseDeliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @StateObject private var feedbackService = FeedbackService.shared
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var appConfig = AppConfigStore.shared
    @State private var hasTriggeredFeedbackRefreshOnLaunch = false

    init() {
        AppLanguageRuntime.apply(rawValue: AppConfigStore.shared.appLanguage.isEmpty
            ? AppLanguagePreference.defaultLanguage.rawValue
            : AppConfigStore.shared.appLanguage)
        DailyPulseDeliveryCoordinator.shared.activate()
        FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
        Task { @MainActor in
            ChatAppearanceProfileManager.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(syncManager)
                .environmentObject(cloudSyncManager)
                .environmentObject(appConfig)
                .onOpenURL { url in
                    Task {
                        _ = await ShortcutURLRouter.shared.handleIncomingURL(url)
                    }
                }
                .onAppear {
                    // 启动时自动重连已加入聊天路由的 MCP 服务器
                    mcpManager.connectSelectedServersIfNeeded()
                    dailyPulseDeliveryCoordinator.activate()
                    DailyPulseBackgroundDeliveryScheduler.shared.activate()
                    triggerFeedbackRefreshOnLaunchIfNeeded()
                }
                .onChange(of: dailyPulseDeliveryCoordinator.reminderEnabled) { _, _ in
                    DailyPulseBackgroundDeliveryScheduler.shared.refreshScheduleIfNeeded()
                }
                .onChange(of: dailyPulseDeliveryCoordinator.reminderHour) { _, _ in
                    DailyPulseBackgroundDeliveryScheduler.shared.refreshScheduleIfNeeded()
                }
                .onChange(of: dailyPulseDeliveryCoordinator.reminderMinute) { _, _ in
                    DailyPulseBackgroundDeliveryScheduler.shared.refreshScheduleIfNeeded()
                }
                .onChange(of: dailyPulseManager.todayRun?.dayKey) { _, _ in
                    DailyPulseBackgroundDeliveryScheduler.shared.refreshScheduleIfNeeded()
                }
                .task {
                    launchStateMachine.startIfNeeded()
                }
                .task(id: launchStateMachine.phase) {
                    guard launchStateMachine.phase == .ready else { return }
                    // 启动持久化预热完成后再触发自动同步，避免冷启动阶段覆盖未加载完的会话状态。
                    syncManager.performAutoSyncIfEnabled()
                    cloudSyncManager.performAutoSyncIfEnabled()
                    // B2：激活 CloudKit zone 订阅，注册 APNs 静默推送通道
                    cloudSyncManager.activateCloudKitSubscriptionIfNeeded()
                }
        }
        .backgroundTask(.appRefresh(DailyPulseBackgroundDeliveryScheduler.taskIdentifier)) {
            await DailyPulseBackgroundDeliveryScheduler.shared.handleAppRefresh()
        }
    }

    private func triggerFeedbackRefreshOnLaunchIfNeeded() {
        guard !hasTriggeredFeedbackRefreshOnLaunch else { return }
        hasTriggeredFeedbackRefreshOnLaunch = true
        Task(priority: .utility) {
            await feedbackService.refreshTicketsOnLaunch()
        }
    }
}
