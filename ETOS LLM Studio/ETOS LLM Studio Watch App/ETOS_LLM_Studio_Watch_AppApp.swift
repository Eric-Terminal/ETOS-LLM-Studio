// ============================================================================
// ETOS_LLM_Studio_Watch_AppApp.swift
// ============================================================================
// ETOS LLM Studio Watch App 应用入口文件
//
// 定义内容:
// - 定义 App 的主体 (@main)
// - 设置应用的根视图为 ContentView
// - 启动时自动同步（如果已启用）
// ============================================================================

import SwiftUI
import Shared
import Network
import os.log

@main
struct ETOS_LLM_Studio_Watch_AppApp: App {
    @StateObject private var launchStateMachine = AppLaunchStateMachine()
    @StateObject private var syncManager = WatchSyncManager.shared
    @StateObject private var cloudSyncManager = CloudSyncManager.shared
    @StateObject private var mcpManager = MCPManager.shared
    @StateObject private var dailyPulseDeliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @StateObject private var feedbackService = FeedbackService.shared
    @State private var hasTriggeredFeedbackRefreshOnLaunch = false
    
    init() {
        DailyPulseDeliveryCoordinator.shared.activate()
        FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
        // 在 App 启动时预先触发本地网络权限
        // 这样用户在第一次使用远程调试前就会看到权限弹窗
        #if !targetEnvironment(simulator)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            Self.preWarmLocalNetworkPermission()
        }
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if launchStateMachine.phase == .ready {
                    ContentView()
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
                            triggerFeedbackRefreshOnLaunchIfNeeded()
                        }
                } else {
                    launchMainShellView
                }
            }
            .task {
                launchStateMachine.startIfNeeded()
            }
        }
    }

    private var launchMainShellView: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 8) {
                        launchBubblePlaceholder(width: 128, isOutgoing: false)
                        launchBubblePlaceholder(width: 104, isOutgoing: true)
                        launchBubblePlaceholder(width: 136, isOutgoing: false)
                    }
                    .padding(.top, 6)
                }

                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                        .foregroundStyle(.secondary)
                    Text("输入消息")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )

                HStack(spacing: 6) {
                    ProgressView()
                    Text(launchPreparingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .navigationTitle("新对话")
        }
    }

    private func launchBubblePlaceholder(width: CGFloat, isOutgoing: Bool) -> some View {
        HStack {
            if isOutgoing {
                Spacer(minLength: 8)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: width, height: 34)
            if !isOutgoing {
                Spacer(minLength: 8)
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
    
    /// 预热本地网络权限
    /// 在后台尝试一个虚拟的本地网络连接，触发系统权限弹窗
    private static func preWarmLocalNetworkPermission() {
        let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Permission")
        logger.info("预热本地网络权限。")
        
        // 尝试连接到本地保留地址（不会实际连接成功，但会触发权限）
        let endpoint = NWEndpoint.hostPort(host: "192.168.1.1", port: 1)
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        params.requiredInterfaceType = .wifi
        
        let connection = NWConnection(to: endpoint, using: params)
        
        connection.stateUpdateHandler = { state in
            logger.info("预热状态: \(String(describing: state))")
            
            switch state {
            case .ready, .failed:
                // 任务完成，取消连接
                connection.cancel()
                logger.info("预热完成。")
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .utility))
        
        // 3秒后强制取消
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            connection.cancel()
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
