// ============================================================================
// MCPManagerNotifications.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP 管理器的通知委托、服务器日志回调，
// 以及连接失败的本地通知聚合发送。
// ============================================================================

import Foundation
import os.log
#if canImport(UserNotifications)
import UserNotifications
#endif

extension MCPManager: MCPNotificationDelegate {
    public nonisolated func didReceiveNotification(_ notification: MCPNotification) {
        Task { @MainActor in
            self.handleNotification(notification, sourceServerID: nil)
        }
    }

    public nonisolated func didReceiveLogMessage(_ entry: MCPLogEntry) {
        Task { @MainActor in
            self.handleLogMessage(entry, sourceServerID: nil)
        }
    }

    public nonisolated func didReceiveProgress(_ progress: MCPProgressParams) {
        Task { @MainActor in
            self.handleProgress(progress, sourceServerID: nil)
        }
    }
}

extension MCPManager {
    func handleNotification(_ notification: MCPNotification, sourceServerID: UUID?) {
        switch notification.method {
        case MCPNotificationType.toolsListChanged.rawValue,
             MCPNotificationType.resourcesListChanged.rawValue,
             MCPNotificationType.promptsListChanged.rawValue,
             MCPNotificationType.resourceUpdated.rawValue,
             MCPNotificationType.rootsListChanged.rawValue:
            appendGovernanceLog(
                level: .info,
                category: .notification,
                serverID: sourceServerID,
                message: String(format: NSLocalizedString("收到能力变更通知：%@", comment: "MCP governance capability change notification"), notification.method)
            )
            if let sourceServerID {
                invalidateMetadataCache(for: sourceServerID, reason: String(format: NSLocalizedString("收到 %@ 通知", comment: "MCP metadata invalidation notification reason"), notification.method))
            } else {
                invalidateAllMetadataCaches(reason: String(format: NSLocalizedString("收到全局能力变更通知：%@", comment: "MCP metadata invalidation global notification reason"), notification.method))
            }
        case MCPNotificationType.cancelled.rawValue:
            if let params = notification.params,
               let cancelled = try? decodeCancelled(from: params) {
                mcpManagerLogger.info("收到 MCP 取消通知：requestId=\(cancelled.requestId.canonicalValue, privacy: .public)，reason=\(cancelled.reason ?? "unknown", privacy: .public)")
                appendGovernanceLog(
                    level: .warning,
                    category: .notification,
                    serverID: sourceServerID,
                    message: String(format: NSLocalizedString("收到取消通知 requestId=%@", comment: "MCP governance cancelled notification"), cancelled.requestId.canonicalValue)
                )
                if let reason = cancelled.reason, !reason.isEmpty {
                    lastOperationError = reason
                }
            }
        default:
            appendGovernanceLog(
                level: .debug,
                category: .notification,
                serverID: sourceServerID,
                message: String(format: NSLocalizedString("收到通知：%@", comment: "MCP governance generic notification"), notification.method)
            )
        }
    }

    func handleLogMessage(_ entry: MCPLogEntry, sourceServerID: UUID?) {
        logEntries.append(entry)
        if logEntries.count > 500 {
            logEntries.removeFirst(logEntries.count - 500)
        }
        appendGovernanceLog(
            level: entry.level,
            category: .serverLog,
            serverID: sourceServerID,
            message: entry.logger ?? NSLocalizedString("服务器日志", comment: "MCP server log fallback title"),
            payload: entry.data
        )
    }

    func handleProgress(_ progress: MCPProgressParams, sourceServerID: UUID?) {
        let tokenKey = progress.progressToken.canonicalValue
        progressByToken[tokenKey] = progress
        progressTimestampsByToken[tokenKey] = Date()

        let matchingCallIDs = trackedToolCallTokenKeys
            .filter { $0.value == tokenKey }
            .map(\.key)
        for callID in matchingCallIDs {
            if var call = activeToolCalls[callID] {
                call.latestProgress = progress.progress
                call.latestTotal = progress.total
                call.lastProgressAt = Date()
                activeToolCalls[callID] = call
            }
            trackedToolCallObservers[callID]?(progress)
        }

        if let total = progress.total,
           total > 0,
           progress.progress >= total {
            progressByToken.removeValue(forKey: tokenKey)
            progressTimestampsByToken.removeValue(forKey: tokenKey)
        }
        appendGovernanceLog(
            level: .info,
            category: .progress,
            serverID: sourceServerID,
            message: String(format: NSLocalizedString("进度更新 token=%@, progress=%.2f, total=%.2f", comment: "MCP governance progress update"), tokenKey, progress.progress, progress.total ?? 0)
        )
    }
}

final class MCPServerNotificationRelay: MCPNotificationDelegate {
    let serverID: UUID
    weak var manager: MCPManager?

    init(serverID: UUID, manager: MCPManager) {
        self.serverID = serverID
        self.manager = manager
    }

    func didReceiveNotification(_ notification: MCPNotification) {
        Task { @MainActor [weak manager] in
            manager?.handleNotification(notification, sourceServerID: self.serverID)
        }
    }

    func didReceiveLogMessage(_ entry: MCPLogEntry) {
        Task { @MainActor [weak manager] in
            manager?.handleLogMessage(entry, sourceServerID: self.serverID)
        }
    }

    func didReceiveProgress(_ progress: MCPProgressParams) {
        Task { @MainActor [weak manager] in
            manager?.handleProgress(progress, sourceServerID: self.serverID)
        }
    }
}

struct MCPConnectionFailureNotificationEvent: Equatable {
    let serverDisplayName: String
    let reason: String
    let isTimeout: Bool
}

struct MCPConnectionFailureNotificationBatch: Equatable {
    static let notificationIdentifier = "mcp.connection.failed.batch"
    static let aggregationDelay: TimeInterval = 1.0

    let failures: [MCPConnectionFailureNotificationEvent]

    init(failures: [MCPConnectionFailureNotificationEvent]) {
        var seenNames: Set<String> = []
        var uniqueFailures: [MCPConnectionFailureNotificationEvent] = []
        for failure in failures {
            let normalizedName = failure.serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }
            if seenNames.insert(normalizedName).inserted {
                uniqueFailures.append(failure)
            }
        }
        self.failures = uniqueFailures
    }

    var body: String {
        guard failures.count != 1 else {
            return singleFailureBody(for: failures[0])
        }
        return String(
            format: NSLocalizedString("%d 个 MCP 服务器连接异常：%@。请检查网络或服务器状态后再重试。", comment: "Aggregated MCP connection failure notification body"),
            failures.count,
            serverListSummary
        )
    }

    private var serverListSummary: String {
        let names = failures.prefix(3).map(\.serverDisplayName).joined(separator: "、")
        guard failures.count > 3 else { return names }
        return String(
            format: NSLocalizedString("%@ 等", comment: "List summary with more items"),
            names
        )
    }

    private func singleFailureBody(for failure: MCPConnectionFailureNotificationEvent) -> String {
        if failure.isTimeout {
            return String(
                format: NSLocalizedString("服务器“%@”握手超时，请检查网络或服务器状态。", comment: "MCP handshake timeout notification body"),
                failure.serverDisplayName
            )
        }
        let trimmedReason = failure.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReason.isEmpty {
            return String(
                format: NSLocalizedString("服务器“%@”握手失败，请稍后重试。", comment: "MCP handshake failure notification body"),
                failure.serverDisplayName
            )
        }
        return String(
            format: NSLocalizedString("服务器“%@”握手失败：%@", comment: "MCP handshake failure notification body with reason"),
            failure.serverDisplayName,
            trimmedReason
        )
    }
}

#if canImport(UserNotifications)
@MainActor
final class MCPFailureNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MCPFailureNotificationCenter()

    private var didConfigure = false
    private var pendingFailures: [MCPConnectionFailureNotificationEvent] = []
    private var pendingNotificationTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func notifyMCPConnectionFailure(serverDisplayName: String, reason: String, isTimeout: Bool) {
        configureIfNeeded()
        pendingFailures.append(
            MCPConnectionFailureNotificationEvent(
                serverDisplayName: serverDisplayName,
                reason: reason,
                isTimeout: isTimeout
            )
        )
        guard pendingNotificationTask == nil else { return }
        pendingNotificationTask = Task { [weak self] in
            let delay = UInt64(MCPConnectionFailureNotificationBatch.aggregationDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            self?.flushPendingConnectionFailures()
        }
    }

    private func flushPendingConnectionFailures() {
        let failures = pendingFailures
        pendingFailures = []
        pendingNotificationTask = nil
        let batch = MCPConnectionFailureNotificationBatch(failures: failures)
        guard !batch.failures.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("MCP 连接异常", comment: "MCP connection failure notification title")
        content.body = batch.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: MCPConnectionFailureNotificationBatch.notificationIdentifier,
            content: content,
            trigger: nil
        )
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [MCPConnectionFailureNotificationBatch.notificationIdentifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [MCPConnectionFailureNotificationBatch.notificationIdentifier])
        notificationCenter.add(request)
    }

    private func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        let center = UNUserNotificationCenter.current()
        AppLocalNotificationCenter.shared.configureIfNeeded()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
#if os(iOS)
        completionHandler([.banner, .list, .sound])
#elseif os(watchOS)
        completionHandler([.sound])
#else
        completionHandler([.sound])
#endif
    }
}
#endif
