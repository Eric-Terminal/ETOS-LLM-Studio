// ============================================================================
// WatchSyncManager.swift
// ============================================================================
// 利用 WatchConnectivity 在 iPhone 与 Apple Watch 之间同步应用数据
// - 默认通过库级覆盖解决分叉数据；旧双向合并仅作为用户确认后的风险选项
// - 小载荷优先使用 sendMessage，较大载荷继续使用文件传输
// - 支持单个会话发送，方便用户在覆盖前手动保留重要对话
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
    let stagedURL = try SyncTemporaryFileCleaner.makeFileURL(
        prefix: "watch-sync",
        fileExtension: "json",
        temporaryDirectory: fileManager.temporaryDirectory,
        fileManager: fileManager
    )
    try fileManager.copyItem(at: sourceURL, to: stagedURL)
    return stagedURL
}

func stageIncomingSyncExchangeData(
    _ data: Data,
    fileManager: FileManager = .default
) throws -> URL {
    let stagedURL = try SyncTemporaryFileCleaner.makeFileURL(
        prefix: "watch-sync",
        fileExtension: "json",
        temporaryDirectory: fileManager.temporaryDirectory,
        fileManager: fileManager
    )
    try data.write(to: stagedURL, options: [.atomic])
    return stagedURL
}

@MainActor
func isWatchConnectivitySyncEnabled() -> Bool {
    isWatchConnectivitySyncEnabled(appConfig: AppConfigStore.shared)
}

@MainActor
func isWatchConnectivitySyncEnabled(appConfig: AppConfigStore) -> Bool {
    !watchConnectivitySyncOptions(appConfig: appConfig).isEmpty
}

@MainActor
func watchConnectivitySyncOptions() -> SyncOptions {
    watchConnectivitySyncOptions(appConfig: AppConfigStore.shared)
}

@MainActor
func watchConnectivitySyncOptions(appConfig: AppConfigStore) -> SyncOptions {
    appConfig.syncAutoSyncEnabled ? .fullSync : []
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
    private static let databaseMetadataRequestKind = "com.ETOS.watchSync.database.metadata.request.v1"
    private static let databaseArchiveRequestKind = "com.ETOS.watchSync.database.archive.request.v1"
    private static let databaseArchiveKind = "com.ETOS.watchSync.database.archive.v1"
    private static let databaseArchiveResultKind = "com.ETOS.watchSync.database.archive.result.v1"
    private static let senderSyncEnabledKey = "senderSyncEnabled"
    private static let inlineExchangePayloadLimit = 60 * 1024
    
    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var isCompanionAvailable: Bool = false
    
    /// 自动同步开关的配置键
    public static let autoSyncEnabledKey = "sync.autoSyncEnabled"
    
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
    
    private enum PendingTransferKind {
        case syncExchange
        case databaseArchive
    }

    private struct PendingTransferContext {
        let expectsResponse: Bool
        let operationID: UUID?
        let isSilent: Bool
        let marksSuccessWhenFinished: Bool
        let fileURL: URL?
        let transferKind: PendingTransferKind
    }

    private struct ActiveSyncOperation {
        let id: UUID
        var isSilent: Bool
    }

    private struct ActiveDatabaseSyncOperation {
        let id: UUID
        var pendingOutboundKinds: Set<WatchSyncDatabaseKind>
        var waitingForOutboundArchive: Bool
        var waitingForIncomingArchive: Bool
        var summary: SyncMergeSummary
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
    private var activeDatabaseSyncOperation: ActiveDatabaseSyncOperation?
    private static var shouldSkipUserNotificationsForCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    
    private override init() {
        super.init()
        activateSessionIfNeeded()
        Task { @MainActor [weak self] in
            self?.refreshCompanionAvailability()
        }
        requestNotificationPermission()
    }
    
    // MARK: - Public API
    
    /// 旧双向合并同步：仅在用户明确确认风险后调用。
    public func performSync(options: SyncOptions, silent: Bool = false) {
        guard validateSessionBeforeTransfer(options: options, silent: silent) != nil else { return }

        guard let operationID = beginSyncOperation(
            silent: silent,
            allowReuseExisting: true,
            stateMessage: NSLocalizedString("正在同步数据…", comment: "")
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
                        message: NSLocalizedString("无法编码同步数据。", comment: "")
                    )
                }
                return
            }
            let tempURL: URL
            do {
                tempURL = try SyncTemporaryFileCleaner.makeFileURL(prefix: "sync", fileExtension: "json")
                try data.write(to: tempURL, options: [.atomic])
            } catch {
                await MainActor.run { [weak self] in
                    self?.failSyncOperation(
                        operationID: operationID,
                        fallbackSilent: silent,
                        message: String(
                            format: NSLocalizedString("写入同步文件失败：%@", comment: ""),
                            error.localizedDescription
                        )
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

    /// 读取双方三处分库的更新时间，用于让用户选择保留哪一端。
    public func fetchDatabaseSyncPlan() async throws -> WatchSyncDatabasePlan {
        guard let session = validateSessionBeforeTransfer(options: .fullSync, silent: false) else {
            throw makeWatchSyncError(NSLocalizedString("无法连接到配对设备。", comment: ""))
        }
        guard session.isReachable else {
            let message = NSLocalizedString("请保持 iPhone 与 Apple Watch 当前在线后再选择库级覆盖。", comment: "")
            state = .failed(message)
            throw makeWatchSyncError(message)
        }

        let remoteReply = try await sendReachableMessage([
            "kind": Self.databaseMetadataRequestKind,
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
            "timestamp": Date().timeIntervalSince1970
        ])
        guard let accepted = remoteReply["accepted"] as? Bool, accepted,
              let metadataData = remoteReply["metadata"] as? Data else {
            let message = NSLocalizedString("对端未返回数据库同步信息。", comment: "")
            state = .failed(message)
            throw makeWatchSyncError(message)
        }

        let remotePacket = try JSONDecoder().decode(WatchSyncDatabaseMetadataPacket.self, from: metadataData)
        let localPacket = await Task.detached(priority: .userInitiated) {
            WatchDatabaseSyncService.localMetadataPacket()
        }.value
        return WatchSyncDatabasePlan(local: localPacket, remote: remotePacket)
    }

    /// 按用户选择的库级策略覆盖对端或本机数据库。
    public func performDatabaseOverwriteSync(resolutions: [WatchSyncDatabaseResolution]) {
        guard let session = validateSessionBeforeTransfer(options: .fullSync, silent: false) else { return }
        guard session.isReachable else {
            state = .failed(NSLocalizedString("请保持 iPhone 与 Apple Watch 当前在线后再开始库级覆盖。", comment: ""))
            return
        }
        guard activeDatabaseSyncOperation == nil else { return }

        guard let operationID = beginSyncOperation(
            silent: false,
            allowReuseExisting: false,
            stateMessage: NSLocalizedString("正在准备库级覆盖…", comment: "")
        ) else { return }

        let localPlatform = SyncEngine.currentPlatformName
        let localKinds = Set(resolutions.compactMap { resolution in
            resolution.sourcePlatform == localPlatform ? resolution.kind : nil
        })
        let remoteKinds = Set(resolutions.compactMap { resolution in
            resolution.sourcePlatform == localPlatform ? nil : resolution.kind
        })

        activeDatabaseSyncOperation = ActiveDatabaseSyncOperation(
            id: operationID,
            pendingOutboundKinds: localKinds,
            waitingForOutboundArchive: !localKinds.isEmpty,
            waitingForIncomingArchive: !remoteKinds.isEmpty,
            summary: WatchDatabaseSyncService.summary(for: localKinds)
        )

        if localKinds.isEmpty && remoteKinds.isEmpty {
            finishDatabaseSyncStep(operationID: operationID, incomingSummary: .empty)
            return
        }

        if !remoteKinds.isEmpty {
            requestRemoteDatabaseArchive(replacing: remoteKinds, requestID: operationID.uuidString, silent: false)
        } else {
            startPendingDatabaseArchiveSend(operationID: operationID)
        }
    }

    /// 发送单个会话到对端设备（单向）
    public func sendSessionToCompanion(sessionID: UUID) {
        guard validateSessionBeforeTransfer(options: [.sessions], silent: false) != nil else { return }

        guard let selectedSession = ChatService.shared.chatSessionsSubject.value.first(where: {
            $0.id == sessionID && !$0.isTemporary
        }) else {
            state = .failed(NSLocalizedString("未找到可发送的会话。", comment: ""))
            return
        }

        guard let operationID = beginSyncOperation(
            silent: false,
            allowReuseExisting: false,
            stateMessage: String(
                format: NSLocalizedString("正在发送“%@”…", comment: ""),
                selectedSession.name
            )
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
                    self?.state = .failed(NSLocalizedString("无法编码同步数据。", comment: ""))
                }
                return
            }
            let tempURL: URL
            do {
                tempURL = try SyncTemporaryFileCleaner.makeFileURL(prefix: "sync", fileExtension: "json")
                try data.write(to: tempURL, options: [.atomic])
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .failed(
                        String(
                            format: NSLocalizedString("写入同步文件失败：%@", comment: ""),
                            error.localizedDescription
                        )
                    )
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
    
    /// 旧版启动静默全量合并已停用，避免在无确认时复活对端已删除的数据。
    public func performAutoSyncIfEnabled() {
        activateSessionIfNeeded()
        refreshCompanionAvailability()
    }

    /// 通过近场在线通道广播单个 AppConfig 键；不可达时跳过，避免无确认触发旧合并。
    public func performQuickSync(key: String, value: Any) {
        guard watchConnectivitySyncOptions().contains(.appStorage) else { return }
        guard SyncEngine.isPropertyListEncodableValue(value) else { return }
        guard let session = validateSessionBeforeTransfer(options: [.appStorage], silent: true) else { return }
        guard session.isReachable else { return }

        let message: [String: Any] = [
            "kind": Self.quickAppConfigKind,
            "key": key,
            "value": value,
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
            "timestamp": Date().timeIntervalSince1970
        ]
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
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

    private func sendReachableMessage(_ message: [String: Any]) async throws -> [String: Any] {
        guard let session else {
            throw makeWatchSyncError(NSLocalizedString("此设备不支持 WatchConnectivity。", comment: ""))
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            session.sendMessage(message, replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
    }

    private func startPendingDatabaseArchiveSend(operationID: UUID) {
        guard var databaseOperation = activeDatabaseSyncOperation,
              databaseOperation.id == operationID,
              !databaseOperation.pendingOutboundKinds.isEmpty else {
            return
        }

        let kinds = databaseOperation.pendingOutboundKinds
        databaseOperation.pendingOutboundKinds = []
        activeDatabaseSyncOperation = databaseOperation

        Task.detached(priority: .userInitiated) {
            do {
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
                let archiveURL = try WatchDatabaseSyncService.buildArchive(for: kinds)
                await MainActor.run { [weak self] in
                    self?.sendDatabaseArchive(
                        archiveURL,
                        replacing: kinds,
                        requestID: operationID.uuidString,
                        silent: false
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failSyncOperation(
                        operationID: operationID,
                        fallbackSilent: false,
                        message: String(
                            format: NSLocalizedString("准备库级覆盖失败：%@", comment: ""),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func requestRemoteDatabaseArchive(
        replacing kinds: Set<WatchSyncDatabaseKind>,
        requestID: String,
        silent: Bool
    ) {
        guard let session else { return }
        let message: [String: Any] = [
            "kind": Self.databaseArchiveRequestKind,
            "databaseKinds": kinds.map(\.rawValue),
            "requestID": requestID,
            "silent": silent,
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
            "timestamp": Date().timeIntervalSince1970
        ]
        session.sendMessage(message, replyHandler: { [weak self] reply in
            guard (reply["accepted"] as? Bool) != false else {
                Task { @MainActor [weak self] in
                    self?.failSyncOperation(
                        operationID: UUID(uuidString: requestID),
                        fallbackSilent: silent,
                        message: NSLocalizedString("对端已拒绝发送数据库归档。", comment: "")
                    )
                }
                return
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor [weak self] in
                self?.failSyncOperation(
                    operationID: UUID(uuidString: requestID),
                    fallbackSilent: silent,
                    message: String(
                        format: NSLocalizedString("请求对端数据库失败：%@", comment: ""),
                        error.localizedDescription
                    )
                )
            }
        })
    }

    private func sendDatabaseArchive(
        _ archiveURL: URL,
        replacing kinds: Set<WatchSyncDatabaseKind>,
        requestID: String?,
        silent: Bool
    ) {
        guard let session else { return }
        let metadata: [String: Any] = [
            "kind": Self.databaseArchiveKind,
            "databaseKinds": kinds.map(\.rawValue),
            "requestID": requestID ?? "",
            "silent": silent,
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
            "timestamp": Date().timeIntervalSince1970
        ]
        let transfer = session.transferFile(archiveURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = PendingTransferContext(
            expectsResponse: false,
            operationID: requestID.flatMap(UUID.init(uuidString:)),
            isSilent: silent,
            marksSuccessWhenFinished: false,
            fileURL: archiveURL,
            transferKind: .databaseArchive
        )
    }

    private func sendDatabaseArchiveResult(
        requestID: String?,
        success: Bool,
        message: String?,
        silent: Bool
    ) {
        guard let requestID, let session else { return }
        var result: [String: Any] = [
            "kind": Self.databaseArchiveResultKind,
            "requestID": requestID,
            "success": success,
            "silent": silent,
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
            "timestamp": Date().timeIntervalSince1970
        ]
        if let message {
            result["message"] = message
        }

        if session.isReachable {
            session.sendMessage(result, replyHandler: nil) { _ in
                session.transferUserInfo(result)
            }
        } else {
            session.transferUserInfo(result)
        }
    }

    private func validateSessionBeforeTransfer(options: SyncOptions, silent: Bool) -> WCSession? {
        guard let session else {
            if !silent {
                state = .failed(NSLocalizedString("此设备不支持 WatchConnectivity。", comment: ""))
            }
            return nil
        }

        guard isWatchConnectivitySyncEnabled() else {
            if !silent {
                state = .failed(NSLocalizedString("同步已关闭，已阻止向对端传输数据。", comment: ""))
            }
            return nil
        }

        guard !options.isEmpty else {
            if !silent {
                state = .failed(NSLocalizedString("同步范围为空，无法开始同步。", comment: ""))
            }
            return nil
        }

#if os(iOS)
        guard session.isPaired else {
            if !silent {
                state = .failed(NSLocalizedString("未检测到已配对的对端设备。", comment: ""))
            }
            return nil
        }
#elseif os(watchOS)
        guard session.isCompanionAppInstalled else {
            if !silent {
                state = .failed(NSLocalizedString("未检测到配套的 iPhone 应用。", comment: ""))
            }
            return nil
        }
#endif

        return session
    }

    private func makeWatchSyncError(_ message: String) -> NSError {
        NSError(domain: "WatchSyncManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
        content.title = NSLocalizedString("同步完成", comment: "")
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
        if summary.importedProviders > 0 { parts.append(String(format: NSLocalizedString("提供商 +%d", comment: ""), summary.importedProviders)) }
        if summary.importedSessions > 0 { parts.append(String(format: NSLocalizedString("会话 +%d", comment: ""), summary.importedSessions)) }
        if summary.importedBackgrounds > 0 { parts.append(String(format: NSLocalizedString("背景 +%d", comment: ""), summary.importedBackgrounds)) }
        if summary.importedMemories > 0 { parts.append(String(format: NSLocalizedString("记忆 +%d", comment: ""), summary.importedMemories)) }
        if summary.importedMCPServers > 0 { parts.append(String(format: NSLocalizedString("MCP +%d", comment: ""), summary.importedMCPServers)) }
        if summary.importedAudioFiles > 0 { parts.append(String(format: NSLocalizedString("音频 +%d", comment: ""), summary.importedAudioFiles)) }
        if summary.importedImageFiles > 0 { parts.append(String(format: NSLocalizedString("图片 +%d", comment: ""), summary.importedImageFiles)) }
        if summary.importedSkills > 0 { parts.append(String(format: NSLocalizedString("Skills +%d", comment: ""), summary.importedSkills)) }
        if summary.importedShortcutTools > 0 { parts.append(String(format: NSLocalizedString("快捷指令工具 +%d", comment: ""), summary.importedShortcutTools)) }
        if summary.importedWorldbooks > 0 { parts.append(String(format: NSLocalizedString("世界书 +%d", comment: ""), summary.importedWorldbooks)) }
        if summary.importedFeedbackTickets > 0 { parts.append(String(format: NSLocalizedString("工单 +%d", comment: ""), summary.importedFeedbackTickets)) }
        if summary.importedDailyPulseRuns > 0 { parts.append(String(format: NSLocalizedString("每日脉冲 +%d", comment: ""), summary.importedDailyPulseRuns)) }
        if summary.importedUsageEvents > 0 { parts.append(String(format: NSLocalizedString("用量事件 +%d", comment: ""), summary.importedUsageEvents)) }
        if summary.importedAppStorageValues > 0 { parts.append(String(format: NSLocalizedString("软件设置 +%d", comment: ""), summary.importedAppStorageValues)) }
        return parts.isEmpty
            ? NSLocalizedString("两端数据已一致", comment: "")
            : parts.joined(separator: NSLocalizedString("，", comment: ""))
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

    private func refreshCompanionAvailability() {
        let isAvailable: Bool
        guard let session else {
            updateCompanionAvailability(false)
            return
        }
#if os(iOS)
        isAvailable = session.isPaired && session.isWatchAppInstalled
#elseif os(watchOS)
        isAvailable = session.isCompanionAppInstalled
#else
        isAvailable = false
#endif
        updateCompanionAvailability(isAvailable)
    }

    private func updateCompanionAvailability(_ isAvailable: Bool) {
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in
                self?.updateCompanionAvailability(isAvailable)
            }
            return
        }
        if isCompanionAvailable != isAvailable {
            isCompanionAvailable = isAvailable
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
            fileURL: payload.fileURL,
            transferKind: .syncExchange
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
            Self.senderSyncEnabledKey: isWatchConnectivitySyncEnabled(),
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

        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor [weak self] in
                if (reply["accepted"] as? Bool) == false {
                    self?.failSyncOperation(
                        operationID: context.operationID,
                        fallbackSilent: context.isSilent,
                        message: NSLocalizedString("同步已关闭，已拒绝接收对端数据。", comment: "")
                    )
                    if let fileURL = context.fileURL {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                    return
                }
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
        if context?.transferKind == .databaseArchive {
            handleDatabaseArchiveOutboundFinished(context: context, error: error, removeFile: removeFile)
            return
        }

        defer {
            if removeFile, let fileURL = context?.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        if let error {
            failSyncOperation(
                operationID: context?.operationID,
                fallbackSilent: context?.isSilent ?? false,
                message: String(
                    format: NSLocalizedString("发送失败：%@", comment: ""),
                    error.localizedDescription
                )
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
                state = .syncing(NSLocalizedString("等待对端处理…", comment: ""))
            }

            if context.expectsResponse == false {
                completeSyncOperationIfNeeded(operationID: context.operationID)
            }
        }
    }

    private func handleDatabaseArchiveOutboundFinished(
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
                message: String(
                    format: NSLocalizedString("发送数据库归档失败：%@", comment: ""),
                    error.localizedDescription
                )
            )
            return
        }

        guard let context else { return }
        markDatabaseArchiveTransferFinished(
            operationID: context.operationID,
            fallbackSilent: context.isSilent
        )
    }

    private func markDatabaseArchiveTransferFinished(operationID: UUID?, fallbackSilent: Bool) {
        guard let operationID,
              activeDatabaseSyncOperation?.id == operationID else {
            return
        }
        if !isSyncSilent(operationID: operationID, fallback: fallbackSilent) {
            state = .syncing(NSLocalizedString("等待对端处理…", comment: ""))
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
        if let operationID, activeDatabaseSyncOperation?.id == operationID {
            activeDatabaseSyncOperation = nil
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

    private func finishDatabaseSyncStep(
        operationID: UUID?,
        outboundAcknowledged: Bool = false,
        incomingSummary: SyncMergeSummary?
    ) {
        guard let operationID,
              var databaseOperation = activeDatabaseSyncOperation,
              databaseOperation.id == operationID else {
            return
        }

        if outboundAcknowledged {
            databaseOperation.waitingForOutboundArchive = false
        }
        if let incomingSummary {
            databaseOperation.waitingForIncomingArchive = false
            databaseOperation.summary = combinedSummary(databaseOperation.summary, incomingSummary)
        }
        activeDatabaseSyncOperation = databaseOperation

        if !databaseOperation.waitingForIncomingArchive,
           !databaseOperation.pendingOutboundKinds.isEmpty {
            startPendingDatabaseArchiveSend(operationID: operationID)
            return
        }

        guard databaseOperation.pendingOutboundKinds.isEmpty,
              !databaseOperation.waitingForOutboundArchive,
              !databaseOperation.waitingForIncomingArchive else {
            return
        }

        lastSummary = databaseOperation.summary
        lastUpdatedAt = Date()
        state = .success(databaseOperation.summary)
        activeDatabaseSyncOperation = nil
        completeSyncOperationIfNeeded(operationID: operationID)
    }

    private func combinedSummary(_ lhs: SyncMergeSummary, _ rhs: SyncMergeSummary) -> SyncMergeSummary {
        SyncMergeSummary(
            importedProviders: lhs.importedProviders + rhs.importedProviders,
            skippedProviders: lhs.skippedProviders + rhs.skippedProviders,
            importedSessions: lhs.importedSessions + rhs.importedSessions,
            skippedSessions: lhs.skippedSessions + rhs.skippedSessions,
            importedBackgrounds: lhs.importedBackgrounds + rhs.importedBackgrounds,
            skippedBackgrounds: lhs.skippedBackgrounds + rhs.skippedBackgrounds,
            importedMemories: lhs.importedMemories + rhs.importedMemories,
            skippedMemories: lhs.skippedMemories + rhs.skippedMemories,
            importedMCPServers: lhs.importedMCPServers + rhs.importedMCPServers,
            skippedMCPServers: lhs.skippedMCPServers + rhs.skippedMCPServers,
            importedAudioFiles: lhs.importedAudioFiles + rhs.importedAudioFiles,
            skippedAudioFiles: lhs.skippedAudioFiles + rhs.skippedAudioFiles,
            importedImageFiles: lhs.importedImageFiles + rhs.importedImageFiles,
            skippedImageFiles: lhs.skippedImageFiles + rhs.skippedImageFiles,
            importedSkills: lhs.importedSkills + rhs.importedSkills,
            skippedSkills: lhs.skippedSkills + rhs.skippedSkills,
            importedShortcutTools: lhs.importedShortcutTools + rhs.importedShortcutTools,
            skippedShortcutTools: lhs.skippedShortcutTools + rhs.skippedShortcutTools,
            importedWorldbooks: lhs.importedWorldbooks + rhs.importedWorldbooks,
            skippedWorldbooks: lhs.skippedWorldbooks + rhs.skippedWorldbooks,
            importedFeedbackTickets: lhs.importedFeedbackTickets + rhs.importedFeedbackTickets,
            skippedFeedbackTickets: lhs.skippedFeedbackTickets + rhs.skippedFeedbackTickets,
            importedDailyPulseRuns: lhs.importedDailyPulseRuns + rhs.importedDailyPulseRuns,
            skippedDailyPulseRuns: lhs.skippedDailyPulseRuns + rhs.skippedDailyPulseRuns,
            importedUsageEvents: lhs.importedUsageEvents + rhs.importedUsageEvents,
            skippedUsageEvents: lhs.skippedUsageEvents + rhs.skippedUsageEvents,
            importedFontFiles: lhs.importedFontFiles + rhs.importedFontFiles,
            skippedFontFiles: lhs.skippedFontFiles + rhs.skippedFontFiles,
            importedFontRouteConfigurations: lhs.importedFontRouteConfigurations + rhs.importedFontRouteConfigurations,
            skippedFontRouteConfigurations: lhs.skippedFontRouteConfigurations + rhs.skippedFontRouteConfigurations,
            importedAppStorageValues: lhs.importedAppStorageValues + rhs.importedAppStorageValues,
            skippedAppStorageValues: lhs.skippedAppStorageValues + rhs.skippedAppStorageValues
        )
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
                                message: NSLocalizedString("无法编码同步数据。", comment: "")
                            )
                        }
                        return
                    }
                    let tempURL: URL
                    do {
                        tempURL = try SyncTemporaryFileCleaner.makeFileURL(prefix: "sync", fileExtension: "json")
                        try data.write(to: tempURL, options: [.atomic])
                    } catch {
                        await MainActor.run { [weak self] in
                            self?.failSyncOperation(
                                operationID: operationID,
                                fallbackSilent: effectiveSilent,
                                message: String(
                                    format: NSLocalizedString("写入同步文件失败：%@", comment: ""),
                                    error.localizedDescription
                                )
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
                            self.state = .syncing(NSLocalizedString("正在回传差异…", comment: ""))
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
                message: String(
                    format: NSLocalizedString("解析同步包失败：%@", comment: ""),
                    error.localizedDescription
                )
            )
        }
    }

    private func applyDatabaseArchive(
        from url: URL,
        replacing kinds: Set<WatchSyncDatabaseKind>,
        requestID: String?,
        silent: Bool
    ) async {
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let effectiveSilent = isSyncSilent(operationID: operationID, fallback: silent)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try WatchDatabaseSyncService.installArchive(at: url, replacing: kinds)
            }.value

            lastSummary = summary
            lastUpdatedAt = Date()
            sendDatabaseArchiveResult(
                requestID: requestID,
                success: true,
                message: nil,
                silent: effectiveSilent
            )

            if let operationID, activeDatabaseSyncOperation?.id == operationID {
                finishDatabaseSyncStep(
                    operationID: operationID,
                    incomingSummary: summary
                )
            } else if !effectiveSilent {
                state = .success(summary)
            }
            sendSyncSuccessNotification(summary: summary, silent: effectiveSilent)
        } catch {
            sendDatabaseArchiveResult(
                requestID: requestID,
                success: false,
                message: error.localizedDescription,
                silent: effectiveSilent
            )
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: effectiveSilent,
                message: String(
                    format: NSLocalizedString("应用数据库覆盖失败：%@", comment: ""),
                    error.localizedDescription
                )
            )
        }
    }

    private func handleIncomingDatabaseMetadataRequest(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        guard message["kind"] as? String == Self.databaseMetadataRequestKind else { return false }
        guard isWatchConnectivitySyncEnabled(),
              message[Self.senderSyncEnabledKey] as? Bool == true else {
            replyHandler(["accepted": false, "reason": "syncDisabled"])
            return true
        }

        Task.detached(priority: .userInitiated) {
            let packet = WatchDatabaseSyncService.localMetadataPacket()
            let data = try? JSONEncoder().encode(packet)
            await MainActor.run {
                if let data {
                    replyHandler(["accepted": true, "metadata": data])
                } else {
                    replyHandler(["accepted": false])
                }
            }
        }
        return true
    }

    private func handleIncomingDatabaseArchiveRequest(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        guard message["kind"] as? String == Self.databaseArchiveRequestKind else { return false }
        let requestID = message["requestID"] as? String
        let silent = (message["silent"] as? Bool) ?? false
        guard isWatchConnectivitySyncEnabled(),
              message[Self.senderSyncEnabledKey] as? Bool == true else {
            replyHandler(["accepted": false, "reason": "syncDisabled"])
            return true
        }
        let rawKinds = message["databaseKinds"] as? [String] ?? []
        let kinds = Set(rawKinds.compactMap(WatchSyncDatabaseKind.init(rawValue:)))
        guard !kinds.isEmpty else {
            replyHandler(["accepted": false])
            return true
        }

        replyHandler(["accepted": true])
        Task.detached(priority: .userInitiated) {
            do {
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
                let archiveURL = try WatchDatabaseSyncService.buildArchive(for: kinds)
                await MainActor.run { [weak self] in
                    self?.sendDatabaseArchive(
                        archiveURL,
                        replacing: kinds,
                        requestID: requestID,
                        silent: silent
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    let message = String(
                        format: NSLocalizedString("准备对端数据库归档失败：%@", comment: ""),
                        error.localizedDescription
                    )
                    self?.sendDatabaseArchiveResult(
                        requestID: requestID,
                        success: false,
                        message: message,
                        silent: silent
                    )
                    self?.failSyncOperation(
                        operationID: requestID.flatMap(UUID.init(uuidString:)),
                        fallbackSilent: silent,
                        message: message
                    )
                }
            }
        }
        return true
    }

    private func handleIncomingDatabaseArchiveResult(_ message: [String: Any]) -> Bool {
        guard message["kind"] as? String == Self.databaseArchiveResultKind else { return false }
        let requestID = message["requestID"] as? String
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let silent = (message["silent"] as? Bool) ?? false
        let success = (message["success"] as? Bool) ?? false

        guard success else {
            let remoteMessage = (message["message"] as? String)
                ?? NSLocalizedString("对端已拒绝发送数据库归档。", comment: "")
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: String(
                    format: NSLocalizedString("应用数据库覆盖失败：%@", comment: ""),
                    remoteMessage
                )
            )
            return true
        }

        finishDatabaseSyncStep(
            operationID: operationID,
            outboundAcknowledged: true,
            incomingSummary: nil
        )
        return true
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
                message: NSLocalizedString("同步已关闭，已拒绝接收对端数据。", comment: "")
            )
            return true
        }

        guard message[Self.senderSyncEnabledKey] as? Bool == true else {
            replyHandler(["accepted": false, "reason": "remoteSyncDisabled"])
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: NSLocalizedString("同步已关闭，已拒绝接收对端数据。", comment: "")
            )
            return true
        }

        guard let data = message["payload"] as? Data else {
            replyHandler(["accepted": false])
            failSyncOperation(
                operationID: operationID,
                fallbackSilent: silent,
                message: NSLocalizedString("接收同步消息失败：载荷为空。", comment: "")
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
                message: String(
                    format: NSLocalizedString("接收同步消息失败：%@", comment: ""),
                    error.localizedDescription
                )
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
        guard message[Self.senderSyncEnabledKey] as? Bool == true else {
            replyHandler(["accepted": false, "reason": "remoteSyncDisabled"])
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshCompanionAvailability()
            if let error, self.activeSyncOperation?.isSilent != true {
                self.state = .failed(
                    String(
                        format: NSLocalizedString("会话激活失败：%@", comment: ""),
                        error.localizedDescription
                    )
                )
            }
        }
    }
    
#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    public func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshCompanionAvailability()
        }
    }
#endif
    
    public func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        let transferKind = file.metadata?["kind"] as? String
        let isResponse = (file.metadata?["response"] as? Bool) ?? false
        let requestID = file.metadata?["requestID"] as? String
        let expectsResponse = (file.metadata?["expectsResponse"] as? Bool) ?? true
        let operationID = requestID.flatMap(UUID.init(uuidString:))
        let silent = (file.metadata?["silent"] as? Bool) ?? false
        let senderSyncEnabled = file.metadata?[Self.senderSyncEnabledKey] as? Bool == true

        let stagedFileURL: URL
        do {
            stagedFileURL = try stageIncomingSyncExchangeFile(from: file.fileURL)
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failSyncOperation(
                    operationID: operationID,
                    fallbackSilent: silent,
                    message: String(
                        format: NSLocalizedString("接收同步文件失败：%@", comment: ""),
                        error.localizedDescription
                    )
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard isWatchConnectivitySyncEnabled() else {
                self.failSyncOperation(
                    operationID: operationID,
                    fallbackSilent: silent,
                    message: NSLocalizedString("同步已关闭，已拒绝接收对端数据。", comment: "")
                )
                try? FileManager.default.removeItem(at: stagedFileURL)
                return
            }
            guard senderSyncEnabled else {
                self.failSyncOperation(
                    operationID: operationID,
                    fallbackSilent: silent,
                    message: NSLocalizedString("同步已关闭，已拒绝接收对端数据。", comment: "")
                )
                try? FileManager.default.removeItem(at: stagedFileURL)
                return
            }
            let effectiveSilent = self.isSyncSilent(operationID: operationID, fallback: silent)
            if transferKind == Self.databaseArchiveKind {
                let rawKinds = file.metadata?["databaseKinds"] as? [String] ?? []
                let kinds = Set(rawKinds.compactMap(WatchSyncDatabaseKind.init(rawValue:)))
                guard !kinds.isEmpty else {
                    self.failSyncOperation(
                        operationID: operationID,
                        fallbackSilent: effectiveSilent,
                        message: NSLocalizedString("数据库覆盖文件缺少库选择。", comment: "")
                    )
                    try? FileManager.default.removeItem(at: stagedFileURL)
                    return
                }
                await self.applyDatabaseArchive(
                    from: stagedFileURL,
                    replacing: kinds,
                    requestID: requestID,
                    silent: effectiveSilent
                )
                return
            }
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
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([:])
                return
            }
            if self.handleIncomingCloudSyncSignal(message) {
                replyHandler(["accepted": true])
                return
            }
            if self.handleIncomingDatabaseArchiveResult(message) {
                replyHandler(["accepted": true])
                return
            }
            if self.handleIncomingDatabaseMetadataRequest(message, replyHandler: replyHandler) {
                return
            }
            if self.handleIncomingDatabaseArchiveRequest(message, replyHandler: replyHandler) {
                return
            }
            if self.handleIncomingInlineExchangeMessage(message, replyHandler: replyHandler) {
                return
            }
            if self.handleIncomingQuickAppConfigMessage(message, replyHandler: replyHandler) {
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
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            if self?.handleIncomingDatabaseArchiveResult(userInfo) == true {
                return
            }
            _ = self?.handleIncomingCloudSyncSignal(userInfo)
        }
    }
}
#endif
