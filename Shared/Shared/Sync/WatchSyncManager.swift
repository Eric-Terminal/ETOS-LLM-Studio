// ============================================================================
// WatchSyncManager.swift
// ============================================================================
// 利用 WatchConnectivity 在 iPhone 与 Apple Watch 之间同步应用数据
// - 支持双向同步：双方比较差异后合并
// - 使用文件传输承载 JSON 同步包，避免消息大小限制
// - 在接收端应用 SyncEngine 合并数据，并自动回传
// - 支持启动时自动同步，静默处理失败，成功发送通知
// ============================================================================

import Foundation
import Combine
import UserNotifications
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

#if canImport(WatchConnectivity)
@MainActor
public final class WatchSyncManager: NSObject, ObservableObject {
    
    public enum SyncState: Equatable {
        case idle
        case syncing(String)
        case success(SyncMergeSummary)
        case failed(String)
    }
    
    public static let shared = WatchSyncManager()
    
    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?
    
    /// 自动同步开关的 UserDefaults key
    public static let autoSyncEnabledKey = "sync.autoSyncEnabled"
    
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
    
    private var pendingTransfers: [ObjectIdentifier: SyncOptions] = [:]
    /// 标记是否为静默同步（启动时自动同步）
    private var isSilentSync = false
    
    private override init() {
        super.init()
        activateSessionIfNeeded()
        requestNotificationPermission()
    }
    
    // MARK: - Public API
    
    /// 执行双向同步：发送本地数据并接收对端数据
    public func performSync(options: SyncOptions, silent: Bool = false) {
        isSilentSync = silent
        
        guard let session else {
            if !silent {
                state = .failed("此设备不支持 WatchConnectivity。")
            }
            return
        }
        
        guard !options.isEmpty else {
            if !silent {
                state = .failed("请至少勾选一项同步内容。")
            }
            return
        }
        
#if os(iOS)
        guard session.isPaired else {
            if !silent {
                state = .failed("未检测到已配对的对端设备。")
            }
            return
        }
#elseif os(watchOS)
        guard session.isCompanionAppInstalled else {
            if !silent {
                state = .failed("未检测到配套的 iPhone 应用。")
            }
            return
        }
#endif
        
        guard session.isReachable else {
            if !silent {
                state = .failed("对端不在线，稍后重试。")
            }
            return
        }
        
        if !silent {
            state = .syncing("正在同步数据…")
        }
        lastSummary = .empty
        
        // 双向同步：发送本地数据，对端会自动回传
        sendPackage(options: options, isResponse: false)
    }
    
    /// 启动时自动同步（静默模式）
    public func performAutoSyncIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.autoSyncEnabledKey) else { return }
        
        // 构建同步选项
        let options = buildSyncOptionsFromSettings()
        guard !options.isEmpty else { return }
        
        // 延迟一小段时间确保 WCSession 已激活
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            performSync(options: options, silent: true)
        }
    }
    
    /// 从用户设置构建同步选项
    private func buildSyncOptionsFromSettings() -> SyncOptions {
        var options: SyncOptions = []
        if UserDefaults.standard.bool(forKey: "sync.options.providers") { options.insert(.providers) }
        if UserDefaults.standard.bool(forKey: "sync.options.sessions") { options.insert(.sessions) }
        if UserDefaults.standard.bool(forKey: "sync.options.backgrounds") { options.insert(.backgrounds) }
        if UserDefaults.standard.bool(forKey: "sync.options.memories") { options.insert(.memories) }
        if UserDefaults.standard.bool(forKey: "sync.options.mcpServers") { options.insert(.mcpServers) }
        if UserDefaults.standard.bool(forKey: "sync.options.imageFiles") { options.insert(.imageFiles) }
        if UserDefaults.standard.bool(forKey: "sync.options.shortcutTools") { options.insert(.shortcutTools) }
        return options
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func sendSyncSuccessNotification(summary: SyncMergeSummary) {
        guard isSilentSync else { return }
        guard summary != .empty else { return } // 没有变化不通知
        
        let content = UNMutableNotificationContent()
        content.title = "同步完成"
        content.body = buildNotificationBody(summary)
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "sync.success.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func buildNotificationBody(_ summary: SyncMergeSummary) -> String {
        var parts: [String] = []
        if summary.importedProviders > 0 { parts.append("提供商 +\(summary.importedProviders)") }
        if summary.importedSessions > 0 { parts.append("会话 +\(summary.importedSessions)") }
        if summary.importedBackgrounds > 0 { parts.append("背景 +\(summary.importedBackgrounds)") }
        if summary.importedMemories > 0 { parts.append("记忆 +\(summary.importedMemories)") }
        if summary.importedMCPServers > 0 { parts.append("MCP +\(summary.importedMCPServers)") }
        if summary.importedImageFiles > 0 { parts.append("图片 +\(summary.importedImageFiles)") }
        if summary.importedShortcutTools > 0 { parts.append("快捷指令工具 +\(summary.importedShortcutTools)") }
        return parts.isEmpty ? "两端数据已一致" : parts.joined(separator: "，")
    }
    
    // MARK: - Session Handling
    
    private func activateSessionIfNeeded() {
        guard let session else { return }
        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }
    
    private func sendPackage(options: SyncOptions, isResponse: Bool, requestID: String? = nil) {
        guard let session else { return }
        let package = SyncEngine.buildPackage(options: options)
        guard let data = try? JSONEncoder().encode(package) else {
            if !isSilentSync {
                state = .failed("无法编码同步数据。")
            }
            return
        }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            if !isSilentSync {
                state = .failed("写入同步文件失败: \(error.localizedDescription)")
            }
            return
        }
        
        var metadata: [String: Any] = [
            "options": options.rawValue,
            "response": isResponse,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let requestID {
            metadata["requestID"] = requestID
        }
        
        let transfer = session.transferFile(tempURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = options
    }
    
    private func applyPackage(
        from url: URL,
        isResponse: Bool,
        requestID: String?
    ) async {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let package = try decoder.decode(SyncPackage.self, from: data)
            let summary = await SyncEngine.apply(package: package)
            lastSummary = summary
            lastUpdatedAt = Date()
            
            if !isSilentSync {
                state = .success(summary)
            }
            
            // 发送通知（仅静默模式下）
            sendSyncSuccessNotification(summary: summary)
            
            if !isResponse {
                // 主动回传对端最新数据，实现双向同步
                sendPackage(options: package.options, isResponse: true)
            }
            
            if let idString = requestID, let uuid = UUID(uuidString: idString) {
                _ = uuid
            }
        } catch {
            if !isSilentSync {
                state = .failed("解析同步包失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error, !isSilentSync {
            state = .failed("会话激活失败: \(error.localizedDescription)")
        }
    }
    
#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
    
    public func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            let isResponse = (file.metadata?["response"] as? Bool) ?? false
            let requestID = file.metadata?["requestID"] as? String
            await applyPackage(from: file.fileURL, isResponse: isResponse, requestID: requestID)
        }
    }
    
    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            let identifier = ObjectIdentifier(fileTransfer)
            defer { pendingTransfers.removeValue(forKey: identifier) }
            
            if let error {
                if !isSilentSync {
                    state = .failed("发送失败: \(error.localizedDescription)")
                }
            } else if !isSilentSync {
                state = .syncing("等待对端处理…")
            }
        }
    }
    
    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        #if canImport(WatchConnectivity)
        if ShortcutExecutionRelay.shared.handleIncomingMessage(message, replyHandler: replyHandler) {
            return
        }
        #endif
        // 保留消息处理以兼容旧版本
        replyHandler([:])
    }
}
#endif
