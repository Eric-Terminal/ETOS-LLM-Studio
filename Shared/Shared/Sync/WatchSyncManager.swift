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

func stageIncomingSyncExchangeFile(
    from sourceURL: URL,
    fileManager: FileManager = .default
) throws -> URL {
    let stagedURL = fileManager.temporaryDirectory
        .appendingPathComponent("watch-sync-\(UUID().uuidString).json", isDirectory: false)
    try fileManager.copyItem(at: sourceURL, to: stagedURL)
    return stagedURL
}

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
        let operationID: UUID?
        let isSilent: Bool
        let marksSuccessWhenFinished: Bool
        let fileURL: URL?
    }

    private struct ActiveSyncOperation {
        let id: UUID
        var isSilent: Bool
    }

    private struct SyncExchangePacket: Codable {
        var manifest: SyncManifest
        var delta: SyncDeltaPackage?
    }

    private struct SyncExchangePayload: Sendable {
        let fileURL: URL
        let optionsRawValue: Int
        let isResponse: Bool
        let requestID: String?
        let expectsResponse: Bool
        let isSilent: Bool
        let marksSuccessWhenFinished: Bool
    }

    private var pendingTransfers: [ObjectIdentifier: PendingTransferContext] = [:]
    private let syncChannel = "watch.connectivity"
    private var activeSyncOperation: ActiveSyncOperation?
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
        guard validateSessionBeforeTransfer(options: options, silent: silent) != nil else { return }

        guard let operationID = beginSyncOperation(
            silent: silent,
            allowReuseExisting: true,
            stateMessage: "正在同步数据…"
        ) else { return }

        let syncChannel = self.syncChannel
        let optionsRawValue = options.rawValue

        Task.detached(priority: .userInitiated) {
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
            let syncOptions = SyncOptions(rawValue: optionsRawValue)
            let snapshot = SyncDeltaEngine.buildLocalSnapshot(
                options: syncOptions,
                channel: syncChannel
            )
            let emptyManifest = SyncManifest(options: syncOptions, records: [])
            let initialDelta = SyncDeltaEngine.buildDelta(
                localSnapshot: snapshot,
                remoteManifest: emptyManifest,
                channel: syncChannel
            )
            let packet = SyncExchangePacket(manifest: snapshot.manifest, delta: initialDelta)
            guard let data = try? JSONEncoder().encode(packet) else {
                await MainActor.run { [weak self] in
                    self?.failSyncOperation(
                        operationID: operationID,
                        fallbackSilent: silent,
                        message: "无法编码同步数据。"
                    )
                }
                return
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-\(UUID().uuidString).json")
            do {
                try data.write(to: tempURL, options: [.atomic])
            } catch {
                await MainActor.run { [weak self] in
                    self?.failSyncOperation(
                        operationID: operationID,
                        fallbackSilent: silent,
                        message: "写入同步文件失败: \(error.localizedDescription)"
                    )
                }
                return
            }
            let payload = SyncExchangePayload(
                fileURL: tempURL,
                optionsRawValue: syncOptions.rawValue,
                isResponse: false,
                requestID: operationID.uuidString,
                expectsResponse: true,
                isSilent: silent,
                marksSuccessWhenFinished: false
            )
            await MainActor.run { [weak self] in
                self?.sendExchange(payload: payload)
            }
        }
    }

    /// 发送单个会话到对端设备（单向）
    public func sendSessionToCompanion(sessionID: UUID) {
        guard validateSessionBeforeTransfer(options: [.sessions], silent: false) != nil else { return }

        guard let selectedSession = ChatService.shared.chatSessionsSubject.value.first(where: {
            $0.id == sessionID && !$0.isTemporary
        }) else {
            state = .failed("未找到可发送的会话。")
            return
        }

        guard let operationID = beginSyncOperation(
            silent: false,
            allowReuseExisting: false,
            stateMessage: "正在发送“\(selectedSession.name)”…"
        ) else { return }

        let syncChannel = self.syncChannel
        let sessionIDValue = sessionID

        Task.detached(priority: .userInitiated) {
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
            let snapshot = SyncDeltaEngine.buildLocalSnapshot(
                options: [.sessions],
                channel: "\(syncChannel).single-session",
                sessionIDs: Set([sessionIDValue])
            )
            let emptyManifest = SyncManifest(options: [.sessions], records: [])
            let delta = SyncDeltaEngine.buildDelta(
                localSnapshot: snapshot,
                remoteManifest: emptyManifest,
                channel: "\(syncChannel).single-session"
            )
            let packet = SyncExchangePacket(manifest: snapshot.manifest, delta: delta)
            guard let data = try? JSONEncoder().encode(packet) else {
                await MainActor.run { [weak self] in
                    self?.state = .failed("无法编码同步数据。")
                }
                return
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-\(UUID().uuidString).json")
            do {
                try data.write(to: tempURL, options: [.atomic])
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .failed("写入同步文件失败: \(error.localizedDescription)")
                }
                return
            }
            let payload = SyncExchangePayload(
                fileURL: tempURL,
                optionsRawValue: SyncOptions.sessions.rawValue,
                isResponse: false,
                requestID: operationID.uuidString,
                expectsResponse: false,
                isSilent: false,
                marksSuccessWhenFinished: true
            )
            await MainActor.run { [weak self] in
                self?.sendExchange(payload: payload)
            }
        }
    }
    
    /// 启动时自动同步（静默模式）
    public func performAutoSyncIfEnabled() {
        guard AppConfigStore.shared.syncAutoSyncEnabled else { return }
        
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
        let c = AppConfigStore.shared
        if c.syncProviders         { options.insert(.providers) }
        if c.syncSessions          { options.insert(.sessions) }
        if c.syncBackgrounds       { options.insert(.backgrounds) }
        if c.syncMemories          { options.insert(.memories) }
        if c.syncMCPServers        { options.insert(.mcpServers) }
        if c.syncImageFiles        { options.insert(.imageFiles) }
        if c.syncSkills            { options.insert(.skills) }
        if c.syncShortcutTools     { options.insert(.shortcutTools) }
        if c.syncWorldbooks        { options.insert(.worldbooks) }
        if c.syncFeedbackTickets   { options.insert(.feedbackTickets) }
        if c.syncDailyPulse        { options.insert(.dailyPulse) }
        if c.syncUsageStats        { options.insert(.usageStats) }
        if c.syncFontFiles         { options.insert(.fontFiles) }
        if c.syncAppStorage        { options.insert(.appStorage) }
        return options
    }

    /// 判断同步是否已完全关闭（自动同步关闭且所有同步项均未勾选）。
    /// 用于 E1 入站文件物理隔离。
    private func isSyncCompletelyDisabled() -> Bool {
        let c = AppConfigStore.shared
        guard !c.syncAutoSyncEnabled else { return false }
        return buildSyncOptionsFromSettings().isEmpty
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
    
    private func sendSyncSuccessNotification(summary: SyncMergeSummary, silent: Bool) {
        guard !Self.shouldSkipUserNotificationsForCurrentProcess else { return }
        guard silent else { return }
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
    
    private func sendExchange(payload: SyncExchangePayload) {
        guard let session else { return }

        // 快速通道：对端可达且载荷 < 60KB 时使用 sendMessage
        if session.isReachable,
           let fileData = try? Data(contentsOf: payload.fileURL),
           fileData.count < 60 * 1024 {
            sendExchangeViaMessage(session: session, fileData: fileData, payload: payload)
            try? FileManager.default.removeItem(at: payload.fileURL)
            return
        }

        // 大载荷或对端不可达：走 transferFile
        var metadata: [String: Any] = [
            "options": payload.optionsRawValue,
            "response": payload.isResponse,
            "expectsResponse": payload.expectsResponse,
            "silent": payload.isSilent,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let requestID = payload.requestID {
            metadata["requestID"] = requestID
        }
        
        let transfer = session.transferFile(payload.fileURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = PendingTransferContext(
            expectsResponse: payload.expectsResponse,
            operationID: payload.requestID.flatMap(UUID.init(uuidString:)),
            isSilent: payload.isSilent,
            marksSuccessWhenFinished: payload.marksSuccessWhenFinished,
            fileURL: payload.fileURL
        )
    }

    private func sendExchangeViaMessage(session: WCSession, fileData: Data, payload: SyncExchangePayload) {
        var message: [String: Any] = [
            "syncPacket": fileData,
            "options": payload.optionsRawValue,
            "response": payload.isResponse,
            "expectsResponse": payload.expectsResponse,
            "silent": payload.isSilent,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let requestID = payload.requestID {
            message["requestID"] = requestID
        }

        let operationID = payload.requestID.flatMap(UUID.init(uuidString:))
        let isSilent = payload.isSilent
        let marksSuccessWhenFinished = payload.marksSuccessWhenFinished
        let expectsResponse = payload.expectsResponse

        session.sendMessage(message, replyHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isSyncSilent(operationID: operationID, fallback: isSilent) {
                    if !expectsResponse && marksSuccessWhenFinished {
                        self.lastSummary = .empty
                        self.lastUpdatedAt = Date()
                        self.state = .success(self.lastSummary)
                    } else if expectsResponse {
                        self.state = .syncing("等待对端处理…")
                    }
                }
                if !expectsResponse {
                    self.completeSyncOperationIfNeeded(operationID: operationID)
                }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor [weak self] in
                self?.failSyncOperation(
                    operationID: operationID,
                    fallbackSilent: isSilent,
                    message: "快速通道发送失败: \(error.localizedDescription)"
                )
            }
        })
    }

    /// 单键配置变更实时广播给对端（仅 appStorage 通道）
    public func performQuickSync(key: String, value: Any) {
        guard let session, session.isReachable else { return }
        guard AppConfigStore.shared.syncAutoSyncEnabled,
              AppConfigStore.shared.syncAppStorage else { return }

        let syncOptions: SyncOptions = [.appStorage]
        let channel = syncChannel

        Task.detached(priority: .background) {
            let localSnapshot = SyncDeltaEngine.buildLocalSnapshot(
                options: syncOptions,
                channel: channel
            )
            let emptyManifest = SyncManifest(options: syncOptions, records: [])
            let delta = SyncDeltaEngine.buildDelta(
                localSnapshot: localSnapshot,
                remoteManifest: emptyManifest,
                channel: channel
            )
            let packet = SyncExchangePacket(manifest: localSnapshot.manifest, delta: delta)
            guard let data = try? JSONEncoder().encode(packet), data.count < 60 * 1024 else { return }

            let message: [String: Any] = [
                "syncPacket": data,
                "options": syncOptions.rawValue,
                "response": false,
                "expectsResponse": false,
                "silent": true,
                "timestamp": Date().timeIntervalSince1970
            ]
            await MainActor.run {
                guard WCSession.isSupported(), WCSession.default.isReachable else { return }
                WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    private func isSyncSilent(operationID: UUID?, fallback: Bool) -> Bool {
        guard let operationID,
              let activeSyncOperation,
              activeSyncOperation.id == operationID else {
            return fallback
        }
        return activeSyncOperation.isSilent
    }

    private func failSyncOperation(operationID: UUID?, fallbackSilent: Bool, message: String) {
        if !isSyncSilent(operationID: operationID, fallback: fallbackSilent) {
            state = .failed(message)
        }
        completeSyncOperationIfNeeded(operationID: operationID)
    }

    private func beginSyncOperation(
        silent: Bool,
        allowReuseExisting: Bool,
        stateMessage: String
    ) -> UUID? {
        if activeSyncOperation != nil {
            guard allowReuseExisting else { return nil }
            if !silent {
                self.activeSyncOperation?.isSilent = false
                state = .syncing(stateMessage)
            }
            return nil
        }

        let operationID = UUID()
        activeSyncOperation = ActiveSyncOperation(id: operationID, isSilent: silent)
        if !silent {
            state = .syncing(stateMessage)
        }
        lastSummary = .empty
        return operationID
    }

    private func completeSyncOperationIfNeeded(operationID: UUID?) {
        guard let operationID, activeSyncOperation?.id == operationID else { return }
        activeSyncOperation = nil
    }
    
    private func applyExchange(
        from url: URL,
        isResponse: Bool,
        requestID: String?,
        expectsResponse: Bool,
        silent: Bool
    ) async {
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let effectiveSilent = isSyncSilent(operationID: operationID, fallback: silent)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let packet = try decoder.decode(SyncExchangePacket.self, from: data)

            var summary = SyncMergeSummary.empty
            if let delta = packet.delta {
                summary = await SyncDeltaEngine.apply(
                    delta: delta,
                    channel: syncChannel,
                    remoteManifest: packet.manifest
                )
            }
            lastSummary = summary
            lastUpdatedAt = Date()
            
            if !effectiveSilent {
                state = .success(summary)
            }
            
            // 发送通知（仅静默模式下）
            sendSyncSuccessNotification(summary: summary, silent: effectiveSilent)
            
            if expectsResponse {
                let responseChannel = syncChannel
                let responseOptionsRawValue = packet.manifest.optionsRawValue
                let responseManifest = packet.manifest

                Task.detached(priority: .userInitiated) {
                    await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                    let responseOptions = SyncOptions(rawValue: responseOptionsRawValue)
                    let localSnapshot = SyncDeltaEngine.buildLocalSnapshot(
                        options: responseOptions,
                        channel: responseChannel
                    )
                    let responseDelta = SyncDeltaEngine.buildDelta(
                        localSnapshot: localSnapshot,
                        remoteManifest: responseManifest,
                        channel: responseChannel
                    )
                    let packet = SyncExchangePacket(manifest: localSnapshot.manifest, delta: responseDelta)
                    guard let data = try? JSONEncoder().encode(packet) else {
                        await MainActor.run { [weak self] in
                            self?.failSyncOperation(
                                operationID: operationID,
                                fallbackSilent: effectiveSilent,
                                message: "无法编码同步数据。"
                            )
                        }
                        return
                    }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("sync-\(UUID().uuidString).json")
                    do {
                        try data.write(to: tempURL, options: [.atomic])
                    } catch {
                        await MainActor.run { [weak self] in
                            self?.failSyncOperation(
                                operationID: operationID,
                                fallbackSilent: effectiveSilent,
                                message: "写入同步文件失败: \(error.localizedDescription)"
                            )
                        }
                        return
                    }
                    let payload = SyncExchangePayload(
                        fileURL: tempURL,
                        optionsRawValue: responseOptions.rawValue,
                        isResponse: true,
                        requestID: requestID,
                        expectsResponse: !isResponse,
                        isSilent: effectiveSilent,
                        marksSuccessWhenFinished: false
                    )
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if !self.isSyncSilent(operationID: operationID, fallback: effectiveSilent) {
                            self.state = .syncing("正在回传差异…")
                        }
                        self.sendExchange(payload: payload)
                    }
                }
            } else {
                completeSyncOperationIfNeeded(operationID: operationID)
            }
            
            if let idString = requestID, let uuid = UUID(uuidString: idString) {
                _ = uuid
            }
        } catch {
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: effectiveSilent,
                message: "解析同步包失败: \(error.localizedDescription)"
            )
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
        if let error, activeSyncOperation?.isSilent != true {
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
        // E1 物理隔离：同步全关时拒绝所有入站文件传输
        guard !isSyncCompletelyDisabled() else {
            logger.info("同步已全部关闭，忽略入站文件传输。")
            return
        }

        let isResponse = (file.metadata?["response"] as? Bool) ?? false
        let requestID = file.metadata?["requestID"] as? String
        let expectsResponse = (file.metadata?["expectsResponse"] as? Bool) ?? true
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let silent = (file.metadata?["silent"] as? Bool) ?? false

        let stagedFileURL: URL
        do {
            stagedFileURL = try stageIncomingSyncExchangeFile(from: file.fileURL)
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failSyncOperation(
                    operationID: operationID,
                    fallbackSilent: silent,
                    message: "接收同步文件失败: \(error.localizedDescription)"
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let effectiveSilent = self.isSyncSilent(operationID: operationID, fallback: silent)
            await self.applyExchange(
                from: stagedFileURL,
                isResponse: isResponse,
                requestID: requestID,
                expectsResponse: expectsResponse,
                silent: effectiveSilent
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
            defer {
                if let fileURL = transferContext?.fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            
            if let error {
                failSyncOperation(
                    operationID: transferContext?.operationID,
                    fallbackSilent: transferContext?.isSilent ?? false,
                    message: "发送失败: \(error.localizedDescription)"
                )
            } else if let transferContext {
                let isSilent = isSyncSilent(
                    operationID: transferContext.operationID,
                    fallback: transferContext.isSilent
                )
                if !isSilent, transferContext.expectsResponse == false {
                    if transferContext.marksSuccessWhenFinished {
                        lastSummary = .empty
                    }
                    lastUpdatedAt = Date()
                    state = .success(lastSummary)
                } else if !isSilent {
                    state = .syncing("等待对端处理…")
                }

                if transferContext.expectsResponse == false {
                    completeSyncOperationIfNeeded(operationID: transferContext.operationID)
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

        // 快速通道：接收小载荷同步包
        if let packetData = message["syncPacket"] as? Data {
            let isResponse = (message["response"] as? Bool) ?? false
            let requestID = message["requestID"] as? String
            let expectsResponse = (message["expectsResponse"] as? Bool) ?? true
            let silent = (message["silent"] as? Bool) ?? false

            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("watch-sync-msg-\(UUID().uuidString).json")
                try packetData.write(to: tempURL, options: [.atomic])

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let operationID = requestID.flatMap(UUID.init(uuidString:))
                    let effectiveSilent = self.isSyncSilent(operationID: operationID, fallback: silent)
                    await self.applyExchange(
                        from: tempURL,
                        isResponse: isResponse,
                        requestID: requestID,
                        expectsResponse: expectsResponse,
                        silent: effectiveSilent
                    )
                }
            } catch {
                // 写入临时文件失败，忽略此包
            }
            replyHandler(["ack": true])
            return
        }

        // 保留消息处理以兼容旧版本
        replyHandler([:])
    }
}
#endif
