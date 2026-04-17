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
import Shared

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
    @StateObject private var launchStateMachine = AppLaunchStateMachine()
    @StateObject private var syncManager = WatchSyncManager.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var dailyPulseManager = DailyPulseManager.shared
    @StateObject private var dailyPulseDeliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @StateObject private var feedbackService = FeedbackService.shared
    @State private var viewModel: ChatViewModel?
    @State private var hasTriggeredFeedbackRefreshOnLaunch = false

    init() {
        DailyPulseDeliveryCoordinator.shared.activate()
        FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let viewModel {
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
                } else {
                    launchMainShellView
                }
            }
            .task {
                launchStateMachine.startIfNeeded()
                initializeViewModelIfNeeded()
            }
            .onChange(of: launchStateMachine.phase) { _, _ in
                initializeViewModelIfNeeded()
            }
        }
        .backgroundTask(.appRefresh(DailyPulseBackgroundDeliveryScheduler.taskIdentifier)) {
            await DailyPulseBackgroundDeliveryScheduler.shared.handleAppRefresh()
        }
    }

    @MainActor
    private func initializeViewModelIfNeeded() {
        guard launchStateMachine.phase == .ready else { return }
        guard viewModel == nil else { return }
        viewModel = ChatViewModel()
    }

    private var launchMainShellView: some View {
        TabView {
            NavigationStack {
                launchChatShellView
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                launchSessionShellView
            }
            .tabItem {
                Label("会话", systemImage: "list.bullet")
            }

            NavigationStack {
                launchSettingsShellView
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
        }
    }

    private var launchChatShellView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    launchBubblePlaceholder(width: 220, isOutgoing: false)
                    launchBubblePlaceholder(width: 180, isOutgoing: true)
                    launchBubblePlaceholder(width: 260, isOutgoing: false)
                    launchBubblePlaceholder(width: 160, isOutgoing: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.line")
                        .foregroundStyle(.secondary)
                    Text("输入消息")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )

                HStack(spacing: 6) {
                    ProgressView()
                    Text(launchPreparingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("新对话")
    }

    private var launchSessionShellView: some View {
        List {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 10)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ProgressView()
                Text(launchPreparingMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .navigationTitle("会话")
    }

    private var launchSettingsShellView: some View {
        List {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 10) {
                    Image(systemName: index.isMultiple(of: 2) ? "slider.horizontal.3" : "gear")
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.16))
                        .frame(height: 12)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ProgressView()
                Text(launchPreparingMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .navigationTitle("设置")
    }

    private func launchBubblePlaceholder(width: CGFloat, isOutgoing: Bool) -> some View {
        HStack {
            if isOutgoing {
                Spacer(minLength: 20)
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: width, height: 54)
            if !isOutgoing {
                Spacer(minLength: 20)
            }
        }
    }

    private var launchPreparingMessage: String {
        switch launchStateMachine.phase {
        case .idle, .preparingPersistence:
            return "正在异步初始化数据库..."
        case .warmingServices:
            return "正在预热聊天服务..."
        case .ready:
            return "准备完成"
        }
    }

    private func triggerFeedbackRefreshOnLaunchIfNeeded() {
        guard !hasTriggeredFeedbackRefreshOnLaunch else { return }
        hasTriggeredFeedbackRefreshOnLaunch = true
        Task(priority: .utility) {
            await feedbackService.refreshAllTickets()
        }
    }
}
