// ============================================================================
// WatchSyncManager.swift
// ============================================================================
// 利用 WatchConnectivity 在 iPhone 与 Apple Watch 之间同步应用数据
// - 支持双向同步：双方比较差异后合并
// - 小载荷优先使用 sendMessage，较大载荷继续使用文件传输
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

func stageIncomingSyncExchangeData(
    _ data: Data,
    fileManager: FileManager = .default
) throws -> URL {
    let stagedURL = fileManager.temporaryDirectory
        .appendingPathComponent("watch-sync-\(UUID().uuidString).json", isDirectory: false)
    try data.write(to: stagedURL, options: [.atomic])
    return stagedURL
}

@MainActor
func isWatchConnectivitySyncEnabled(appConfig: AppConfigStore = .shared) -> Bool {
    appConfig.syncAutoSyncEnabled || !watchConnectivitySyncOptions(appConfig: appConfig).isEmpty
}

@MainActor
func watchConnectivitySyncOptions(appConfig: AppConfigStore = .shared) -> SyncOptions {
    var options: SyncOptions = []
    if appConfig.syncProviders { options.insert(.providers) }
    if appConfig.syncSessions { options.insert(.sessions) }
    if appConfig.syncBackgrounds { options.insert(.backgrounds) }
    if appConfig.syncMemories { options.insert(.memories) }
    if appConfig.syncMCPServers { options.insert(.mcpServers) }
    if appConfig.syncImageFiles { options.insert(.imageFiles) }
    if appConfig.syncSkills { options.insert(.skills) }
    if appConfig.syncShortcutTools { options.insert(.shortcutTools) }
    if appConfig.syncWorldbooks { options.insert(.worldbooks) }
    if appConfig.syncFeedbackTickets { options.insert(.feedbackTickets) }
    if appConfig.syncDailyPulse { options.insert(.dailyPulse) }
    if appConfig.syncUsageStats { options.insert(.usageStats) }
    if appConfig.syncFontFiles { options.insert(.fontFiles) }
    if appConfig.syncAppStorage { options.insert(.appStorage) }
    return options
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
    private static let inlineExchangeKind = "com.ETOS.watchSync.exchange.inline.v1"
    private static let quickAppConfigKind = "com.ETOS.watchSync.appConfig.quick.v1"
    private static let cloudSyncRemoteChangeKind = "com.ETOS.watchSync.cloudSync.remoteChange.v1"
    private static let inlineExchangePayloadLimit = 60 * 1024
    
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
        let appConfig = AppConfigStore.shared
        guard appConfig.syncAutoSyncEnabled else { return }
        
        // 构建同步选项
        let options = buildSyncOptionsFromSettings()
        guard !options.isEmpty else { return }
        
        // 延迟一小段时间确保 WCSession 已激活
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            performSync(options: options, silent: true)
        }
    }

    /// 通过近场在线通道广播单个 AppConfig 键，失败时回退到静默设置同步。
    public func performQuickSync(key: String, value: Any) {
        guard SyncEngine.isPropertyListEncodableValue(value) else { return }
        guard let session = validateSessionBeforeTransfer(options: [.appStorage], silent: true) else { return }
        guard session.isReachable else {
            performSync(options: [.appStorage], silent: true)
            return
        }

        let message: [String: Any] = [
            "kind": Self.quickAppConfigKind,
            "key": key,
            "value": value,
            "timestamp": Date().timeIntervalSince1970
        ]
        session.sendMessage(message, replyHandler: nil, errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performSync(options: [.appStorage], silent: true)
            }
        })
    }

    /// 将 iCloud 远端变化信号转发给配对端，让 watchOS 在无 APNs 入口时也能拉取云端变更。
    public func relayCloudSyncSignalToCompanion() {
        guard let session else { return }
        let message: [String: Any] = [
            "kind": Self.cloudSyncRemoteChangeKind,
            "timestamp": Date().timeIntervalSince1970
        ]
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(message)
        }
    }
    
    /// 从用户设置构建同步选项
    private func buildSyncOptionsFromSettings() -> SyncOptions {
        watchConnectivitySyncOptions()
    }

    private func validateSessionBeforeTransfer(options: SyncOptions, silent: Bool) -> WCSession? {
        guard let session else {
            if !silent {
                state = .failed("此设备不支持 WatchConnectivity。")
            }
            return nil
        }

        guard isWatchConnectivitySyncEnabled() else {
            if !silent {
                state = .failed("同步已关闭，已阻止向对端传输数据。")
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
        let metadata = makeExchangeMetadata(payload: payload)
        let context = PendingTransferContext(
            expectsResponse: payload.expectsResponse,
            operationID: payload.requestID.flatMap(UUID.init(uuidString:)),
            isSilent: payload.isSilent,
            marksSuccessWhenFinished: payload.marksSuccessWhenFinished,
            fileURL: payload.fileURL
        )

        if session.isReachable,
           let data = try? Data(contentsOf: payload.fileURL),
           data.count <= Self.inlineExchangePayloadLimit {
            sendInlineExchange(data: data, metadata: metadata, context: context)
            return
        }

        transferExchangeFile(metadata: metadata, context: context)
    }

    private func makeExchangeMetadata(payload: SyncExchangePayload) -> [String: Any] {
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
        return metadata
    }

    private func sendInlineExchange(
        data: Data,
        metadata: [String: Any],
        context: PendingTransferContext
    ) {
        guard let session else { return }
        var message = metadata
        message["kind"] = Self.inlineExchangeKind
        message["payload"] = data

        session.sendMessage(message, replyHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutboundExchangeFinished(context: context, error: nil, removeFile: true)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transferExchangeFile(metadata: metadata, context: context)
            }
        })
    }

    private func transferExchangeFile(
        metadata: [String: Any],
        context: PendingTransferContext
    ) {
        guard let session, let fileURL = context.fileURL else { return }
        let transfer = session.transferFile(fileURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = context
    }

    private func handleOutboundExchangeFinished(
        context: PendingTransferContext?,
        error: Error?,
        removeFile: Bool
    ) {
        defer {
            if removeFile, let fileURL = context?.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        if let error {
            failSyncOperation(
                operationID: context?.operationID,
                fallbackSilent: context?.isSilent ?? false,
                message: "发送失败: \(error.localizedDescription)"
            )
        } else if let context {
            let isSilent = isSyncSilent(
                operationID: context.operationID,
                fallback: context.isSilent
            )
            if !isSilent, context.expectsResponse == false {
                if context.marksSuccessWhenFinished {
                    lastSummary = .empty
                }
                lastUpdatedAt = Date()
                state = .success(lastSummary)
            } else if !isSilent {
                state = .syncing("等待对端处理…")
            }

            if context.expectsResponse == false {
                completeSyncOperationIfNeeded(operationID: context.operationID)
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

    private func handleIncomingInlineExchangeMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        guard message["kind"] as? String == Self.inlineExchangeKind else { return false }
        let requestID = message["requestID"] as? String
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let silent = (message["silent"] as? Bool) ?? false

        guard isWatchConnectivitySyncEnabled() else {
            replyHandler(["accepted": false, "reason": "syncDisabled"])
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: "同步已关闭，已拒绝接收对端数据。"
            )
            return true
        }

        guard let data = message["payload"] as? Data else {
            replyHandler(["accepted": false])
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: "接收同步消息失败：载荷为空。"
            )
            return true
        }

        let stagedFileURL: URL
        do {
            stagedFileURL = try stageIncomingSyncExchangeData(data)
        } catch {
            replyHandler(["accepted": false])
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: "接收同步消息失败: \(error.localizedDescription)"
            )
            return true
        }

        let isResponse = (message["response"] as? Bool) ?? false
        let expectsResponse = (message["expectsResponse"] as? Bool) ?? true
        let effectiveSilent = isSyncSilent(operationID: operationID, fallback: silent)
        replyHandler(["accepted": true])
        Task { @MainActor [weak self] in
            await self?.applyExchange(
                from: stagedFileURL,
                isResponse: isResponse,
                requestID: requestID,
                expectsResponse: expectsResponse,
                silent: effectiveSilent
            )
        }
        return true
    }

    private func handleIncomingQuickAppConfigMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        guard message["kind"] as? String == Self.quickAppConfigKind else { return false }
        guard isWatchConnectivitySyncEnabled() else {
            replyHandler(["accepted": false, "reason": "syncDisabled"])
            return true
        }
        guard let key = message["key"] as? String,
              let value = message["value"],
              SyncEngine.isPropertyListEncodableValue(value),
              let snapshotData = SyncEngine.encodeAppStorageSnapshot([key: value]) else {
            replyHandler(["accepted": false])
            return true
        }

        replyHandler(["accepted": true])
        let package = SyncPackage(options: [.appStorage], appStorageSnapshot: snapshotData)
        Task { @MainActor [weak self] in
            let summary = await SyncEngine.apply(package: package)
            self?.lastSummary = summary
            self?.lastUpdatedAt = Date()
        }
        return true
    }

    private func handleIncomingCloudSyncSignal(_ message: [String: Any]) -> Bool {
        guard message["kind"] as? String == Self.cloudSyncRemoteChangeKind else { return false }
        Task { @MainActor in
            await CloudSyncManager.shared.performAutoSyncNowIfEnabled()
        }
        return true
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
        let isResponse = (file.metadata?["response"] as? Bool) ?? false
        let requestID = file.metadata?["requestID"] as? String
        let expectsResponse = (file.metadata?["expectsResponse"] as? Bool) ?? true
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let silent = (file.metadata?["silent"] as? Bool) ?? false

        guard isWatchConnectivitySyncEnabled() else {
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: "同步已关闭，已拒绝接收对端数据。"
            )
            return
        }

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
            handleOutboundExchangeFinished(context: transferContext, error: error, removeFile: true)
        }
    }
    
    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        if handleIncomingCloudSyncSignal(message) {
            replyHandler(["accepted": true])
            return
        }
        if handleIncomingInlineExchangeMessage(message, replyHandler: replyHandler) {
            return
        }
        if handleIncomingQuickAppConfigMessage(message, replyHandler: replyHandler) {
            return
        }
        #if canImport(WatchConnectivity)
        if ShortcutExecutionRelay.shared.handleIncomingMessage(message, replyHandler: replyHandler) {
            return
        }
        #endif
        // 保留消息处理以兼容旧版本
        replyHandler([:])
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        _ = handleIncomingCloudSyncSignal(userInfo)
    }
}
#endif
