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
    @StateObject private var syncManager = WatchSyncManager.shared
    @State private var didAutoConnectMCP = false
    
    init() {
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
            ContentView()
                .environmentObject(syncManager)
                .onOpenURL { url in
                    Task {
                        _ = await ShortcutURLRouter.shared.handleIncomingURL(url)
                    }
                }
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
}
