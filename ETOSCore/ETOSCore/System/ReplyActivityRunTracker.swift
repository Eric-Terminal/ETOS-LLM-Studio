// ============================================================================
// ReplyActivityRunTracker.swift
// ============================================================================

import Foundation

/// 普通 Chat 没有 Agent Run，使用轻量快照补齐实时活动所需的稳定运行身份。
public struct ReplyActivityRunTracker {
    public private(set) var snapshotsBySessionID: [UUID: ETOSRunSnapshot] = [:]

    public init() {}

    public var recentSnapshots: [ETOSRunSnapshot] {
        snapshotsBySessionID.values
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public mutating func record(
        status: ChatService.SessionRequestStatus,
        sessionID: UUID,
        title: String,
        now: Date = Date(),
        newRunID: UUID = UUID()
    ) -> ETOSRunSnapshot {
        let previous = snapshotsBySessionID[sessionID]
        // 同一会话持续复用展示身份；系统 Activity 是否可更新由发布器单独判断。
        let snapshot = ETOSRunSnapshot(
            id: previous?.id ?? newRunID,
            sessionID: sessionID,
            title: title,
            status: Self.snapshotStatus(status),
            startedAt: status == .started ? now : (previous?.startedAt ?? now),
            updatedAt: now
        )
        snapshotsBySessionID[sessionID] = snapshot
        trimHistory()
        return snapshot
    }

    public mutating func mergePersisted(
        _ snapshots: [ETOSRunSnapshot],
        runningSessionIDs: Set<UUID>,
        now: Date = Date()
    ) {
        for snapshot in snapshots where snapshotsBySessionID[snapshot.sessionID] == nil {
            if Self.isTerminal(snapshot.status) || runningSessionIDs.contains(snapshot.sessionID) {
                snapshotsBySessionID[snapshot.sessionID] = snapshot
            } else {
                snapshotsBySessionID[snapshot.sessionID] = ETOSRunSnapshot(
                    id: snapshot.id,
                    sessionID: snapshot.sessionID,
                    title: snapshot.title,
                    status: .failed,
                    startedAt: snapshot.startedAt,
                    updatedAt: now
                )
            }
        }
        trimHistory()
    }

    @discardableResult
    public mutating func remove(sessionIDs: Set<UUID>) -> Bool {
        let originalCount = snapshotsBySessionID.count
        for sessionID in sessionIDs {
            snapshotsBySessionID.removeValue(forKey: sessionID)
        }
        return snapshotsBySessionID.count != originalCount
    }

    private mutating func trimHistory() {
        let retainedSessionIDs = Set(recentSnapshots.prefix(20).map(\.sessionID))
        snapshotsBySessionID = snapshotsBySessionID.filter { retainedSessionIDs.contains($0.key) }
    }

    private static func snapshotStatus(
        _ status: ChatService.SessionRequestStatus
    ) -> ETOSTaskSnapshotStatus {
        switch status {
        case .started: return .running
        case .finished: return .completed
        case .error: return .failed
        case .cancelled: return .cancelled
        }
    }

    private static func isTerminal(_ status: ETOSTaskSnapshotStatus) -> Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}

public enum BackgroundReplyNotificationPolicy {
    public enum ApplicationVisibility {
        case active
        case inactive
        case background
    }

    public enum Action: Equatable {
        case suppress
        case resolveTransition
        case deliver
    }

    public static func action(for visibility: ApplicationVisibility, isCurrentSession: Bool) -> Action {
        switch visibility {
        case .active: return isCurrentSession ? .suppress : .deliver
        case .inactive: return isCurrentSession ? .resolveTransition : .deliver
        case .background: return .deliver
        }
    }
}

public enum ReplyActivityDismissalDecision: Equatable {
    case immediate
    case after(Date)
}

public enum ReplyActivityDismissalPolicy {
    // 终态只承担即时反馈；后台完成另有本地通知，避免系统默认策略长期堆积卡片。
    public static let terminalVisibilityDuration: TimeInterval = 30

    public static func terminalDecision(
        updatedAt: Date,
        now: Date = Date()
    ) -> ReplyActivityDismissalDecision {
        let dismissalDate = updatedAt.addingTimeInterval(terminalVisibilityDuration)
        return dismissalDate > now ? .after(dismissalDate) : .immediate
    }
}

public actor ReplyActivitySnapshotStore {
    private let fileName = "chat-replies.json"

    public init() {}

    public func load() -> [ETOSRunSnapshot] {
        guard let layout = ETOSSharedStorageLayout.resolve() else { return [] }
        return (try? ETOSSharedFileStore.read(
            [ETOSRunSnapshot].self,
            from: layout.runSnapshots.appendingPathComponent(fileName),
            maximumBytes: 256 * 1_024
        )) ?? []
    }

    public func save(_ snapshots: [ETOSRunSnapshot]) {
        guard let layout = ETOSSharedStorageLayout.resolve() else { return }
        try? layout.prepare()
        try? ETOSSharedFileStore.write(
            Array(snapshots.prefix(20)),
            to: layout.runSnapshots.appendingPathComponent(fileName),
            fileProtection: .completeFileProtectionUntilFirstUserAuthentication
        )
    }
}
