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
import BackgroundTasks
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
final class ETOSCloudSyncAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        Task { @MainActor in
            await CloudSyncManager.shared.ensureRemoteChangeSubscriptionIfEnabled()
        }
        return true
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification _: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let imported = await CloudSyncManager.shared.performAutoSyncNowIfEnabled()
            WatchSyncManager.shared.relayCloudSyncSignalToCompanion()
            completionHandler(imported ? .newData : .noData)
        }
    }
}
#endif

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ETOSCloudSyncAppDelegate.self) private var appDelegate
#endif
    @StateObject private var launchStateMachine = AppLaunchStateMachine()
    @StateObject private var syncManager = WatchSyncManager.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var dailyPulseManager = DailyPulseManager.shared
    @StateObject private var dailyPulseDeliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @StateObject private var updateTimelineManager = UpdateTimelineManager.shared
    @StateObject private var feedbackService = FeedbackService.shared
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var appConfig = AppConfigStore.shared
    @State private var hasTriggeredFeedbackRefreshOnLaunch = false

    init() {
        AppLanguageRuntime.applyConfiguredLanguage()
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
                .environmentObject(appConfig)
                .environmentObject(syncManager)
                .environmentObject(cloudSyncManager)
                .onOpenURL { url in
                    Task { @MainActor in
                        let handledByShortcutRouter = await ShortcutURLRouter.shared.handleIncomingURL(url)
                        if !handledByShortcutRouter {
                            if IncomingSnapshotRestoreSupport.isSnapshotURL(url) {
                                NotificationCenter.default.post(name: .requestIncomingSnapshotRestore, object: url)
                            } else {
                                viewModel.handleIncomingDocumentURL(url)
                            }
                        }
                    }
                }
                .onAppear {
                    // 启动时自动重连已加入聊天路由的 MCP 服务器
                    mcpManager.connectSelectedServersIfNeeded()
                    dailyPulseDeliveryCoordinator.activate()
                    DailyPulseBackgroundDeliveryScheduler.shared.activate()
                    updateTimelineManager.activateOnLaunchIfNeeded()
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
