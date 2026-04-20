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
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 WatchConnectivity 同步状态不会稳定自动刷新到双端设置页。
    
    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?
    
    /// 自动同步开关的 UserDefaults key
    public static let autoSyncEnabledKey = "sync.autoSyncEnabled"
    
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
    
    private struct PendingTransferContext {
        let expectsResponse: Bool
    }

    private struct SyncExchangePacket: Codable {
        var manifest: SyncManifest
        var delta: SyncDeltaPackage?
    }

    private var pendingTransfers: [ObjectIdentifier: PendingTransferContext] = [:]
    private let syncChannel = "watch.connectivity"
    /// 标记是否为静默同步（启动时自动同步）
    private var isSilentSync = false
    private static var shouldSkipUserNotificationsForCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    
    private override init() {
        super.init()
        activateSessionIfNeeded()
        requestNotificationPermission()
    }
    
    // MARK: - Public API
    
    /// 执行双向同步：发送本地数据并接收对端数据
    public func performSync(options: SyncOptions, silent: Bool = false) {
        isSilentSync = silent
        guard validateSessionBeforeTransfer(options: options, silent: silent) != nil else { return }
        
        if !silent {
            state = .syncing("正在同步数据…")
        }
        lastSummary = .empty

        let snapshot = SyncDeltaEngine.buildLocalSnapshot(
            options: options,
            channel: syncChannel
        )
        let emptyManifest = SyncManifest(options: options, records: [])
        let initialDelta = SyncDeltaEngine.buildDelta(
            localSnapshot: snapshot,
            remoteManifest: emptyManifest,
            channel: syncChannel
        )
        sendExchange(
            manifest: snapshot.manifest,
            delta: initialDelta,
            isResponse: false,
            expectsResponse: true
        )
    }

    /// 发送单个会话到对端设备（单向）
    public func sendSessionToCompanion(sessionID: UUID) {
        isSilentSync = false
        guard validateSessionBeforeTransfer(options: [.sessions], silent: false) != nil else { return }

        guard let selectedSession = ChatService.shared.chatSessionsSubject.value.first(where: {
            $0.id == sessionID && !$0.isTemporary
        }) else {
            state = .failed("未找到可发送的会话。")
            return
        }

        state = .syncing("正在发送“\(selectedSession.name)”…")
        lastSummary = .empty

        let snapshot = SyncDeltaEngine.buildLocalSnapshot(
            options: [.sessions],
            channel: "\(syncChannel).single-session",
            sessionIDs: Set([sessionID])
        )
        let emptyManifest = SyncManifest(options: [.sessions], records: [])
        let delta = SyncDeltaEngine.buildDelta(
            localSnapshot: snapshot,
            remoteManifest: emptyManifest,
            channel: "\(syncChannel).single-session"
        )
        sendExchange(
            manifest: snapshot.manifest,
            delta: delta,
            isResponse: false,
            expectsResponse: false
        )
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
        if isSyncOptionEnabled(key: "sync.options.providers", defaultValue: true) { options.insert(.providers) }
        if isSyncOptionEnabled(key: "sync.options.sessions", defaultValue: true) { options.insert(.sessions) }
        if isSyncOptionEnabled(key: "sync.options.backgrounds", defaultValue: true) { options.insert(.backgrounds) }
        if isSyncOptionEnabled(key: "sync.options.memories", defaultValue: false) { options.insert(.memories) }
        if isSyncOptionEnabled(key: "sync.options.mcpServers", defaultValue: true) { options.insert(.mcpServers) }
        if isSyncOptionEnabled(key: "sync.options.imageFiles", defaultValue: true) { options.insert(.imageFiles) }
        if isSyncOptionEnabled(key: "sync.options.skills", defaultValue: true) { options.insert(.skills) }
        if isSyncOptionEnabled(key: "sync.options.shortcutTools", defaultValue: true) { options.insert(.shortcutTools) }
        if isSyncOptionEnabled(key: "sync.options.worldbooks", defaultValue: true) { options.insert(.worldbooks) }
        if isSyncOptionEnabled(key: "sync.options.feedbackTickets", defaultValue: true) { options.insert(.feedbackTickets) }
        if isSyncOptionEnabled(key: "sync.options.dailyPulse", defaultValue: true) { options.insert(.dailyPulse) }
        if isSyncOptionEnabled(key: "sync.options.usageStats", defaultValue: true) { options.insert(.usageStats) }
        if isSyncOptionEnabled(key: "sync.options.fontFiles", defaultValue: true) { options.insert(.fontFiles) }
        let legacyAppStorageDefault = isSyncOptionEnabled(key: "sync.options.globalPrompt", defaultValue: true)
        if isSyncOptionEnabled(key: "sync.options.appStorage", defaultValue: legacyAppStorageDefault) { options.insert(.appStorage) }
        return options
    }

    private func isSyncOptionEnabled(key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func validateSessionBeforeTransfer(options: SyncOptions, silent: Bool) -> WCSession? {
        guard let session else {
            if !silent {
                state = .failed("此设备不支持 WatchConnectivity。")
            }
            return nil
        }

        guard !options.isEmpty else {
            if !silent {
                state = .failed("请至少勾选一项同步内容。")
            }
            return nil
        }

#if os(iOS)
        guard session.isPaired else {
            if !silent {
                state = .failed("未检测到已配对的对端设备。")
            }
            return nil
        }
#elseif os(watchOS)
        guard session.isCompanionAppInstalled else {
            if !silent {
                state = .failed("未检测到配套的 iPhone 应用。")
            }
            return nil
        }
#endif

        return session
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        guard !Self.shouldSkipUserNotificationsForCurrentProcess else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func sendSyncSuccessNotification(summary: SyncMergeSummary) {
        guard !Self.shouldSkipUserNotificationsForCurrentProcess else { return }
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
        if summary.importedSkills > 0 { parts.append("Skills +\(summary.importedSkills)") }
        if summary.importedShortcutTools > 0 { parts.append("快捷指令工具 +\(summary.importedShortcutTools)") }
        if summary.importedWorldbooks > 0 { parts.append("世界书 +\(summary.importedWorldbooks)") }
        if summary.importedFeedbackTickets > 0 { parts.append("工单 +\(summary.importedFeedbackTickets)") }
        if summary.importedDailyPulseRuns > 0 { parts.append("每日脉冲 +\(summary.importedDailyPulseRuns)") }
        if summary.importedUsageEvents > 0 { parts.append("用量事件 +\(summary.importedUsageEvents)") }
        if summary.importedAppStorageValues > 0 { parts.append("软件设置 +\(summary.importedAppStorageValues)") }
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
    
    private func sendExchange(
        manifest: SyncManifest,
        delta: SyncDeltaPackage?,
        isResponse: Bool,
        requestID: String? = nil,
        expectsResponse: Bool = true
    ) {
        guard let session else { return }
        let payload = SyncExchangePacket(manifest: manifest, delta: delta)
        guard let data = try? JSONEncoder().encode(payload) else {
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
            "options": manifest.options.rawValue,
            "response": isResponse,
            "expectsResponse": expectsResponse,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let requestID {
            metadata["requestID"] = requestID
        }
        
        let transfer = session.transferFile(tempURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = PendingTransferContext(
            expectsResponse: expectsResponse
        )
    }
    
    private func applyExchange(
        from url: URL,
        isResponse: Bool,
        requestID: String?,
        expectsResponse: Bool
    ) async {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let packet = try decoder.decode(SyncExchangePacket.self, from: data)

            var summary = SyncMergeSummary.empty
            if let delta = packet.delta {
                summary = await SyncDeltaEngine.apply(delta: delta)
            }
            lastSummary = summary
            lastUpdatedAt = Date()
            
            if !isSilentSync {
                state = .success(summary)
            }
            
            // 发送通知（仅静默模式下）
            sendSyncSuccessNotification(summary: summary)
            
            if expectsResponse {
                let localSnapshot = SyncDeltaEngine.buildLocalSnapshot(
                    options: packet.manifest.options,
                    channel: syncChannel
                )
                let responseDelta = SyncDeltaEngine.buildDelta(
                    localSnapshot: localSnapshot,
                    remoteManifest: packet.manifest,
                    channel: syncChannel
                )
                if !isSilentSync {
                    state = .syncing("正在回传差异…")
                }
                sendExchange(
                    manifest: localSnapshot.manifest,
                    delta: responseDelta,
                    isResponse: true,
                    requestID: requestID,
                    expectsResponse: !isResponse
                )
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
            let expectsResponse = (file.metadata?["expectsResponse"] as? Bool) ?? true
            await applyExchange(
                from: file.fileURL,
                isResponse: isResponse,
                requestID: requestID,
                expectsResponse: expectsResponse
            )
        }
    }
    
    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            let identifier = ObjectIdentifier(fileTransfer)
            let transferContext = pendingTransfers[identifier]
            defer { pendingTransfers.removeValue(forKey: identifier) }
            
            if let error {
                if !isSilentSync {
                    state = .failed("发送失败: \(error.localizedDescription)")
                }
            } else if !isSilentSync {
                if transferContext?.expectsResponse == false {
                    lastSummary = .empty
                    lastUpdatedAt = Date()
                    state = .success(.empty)
                } else {
                    state = .syncing("等待对端处理…")
                }
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
