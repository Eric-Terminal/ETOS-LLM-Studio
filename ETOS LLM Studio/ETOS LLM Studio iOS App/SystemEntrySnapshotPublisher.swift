// ============================================================================
// SystemEntrySnapshotPublisher.swift
// ETOS LLM Studio iOS App
// ============================================================================

import ActivityKit
import Combine
import ETOSCore
import Foundation
import WidgetKit

@MainActor
final class SystemEntrySnapshotPublisher {
    static let shared = SystemEntrySnapshotPublisher()

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshBackgroundLease: ApplicationBackgroundTaskLease?
    private var replyRunTracker = ReplyActivityRunTracker()
    private let replySnapshotStore = ReplyActivitySnapshotStore()
    // 已 end 的卡片仍可能在锁屏保留，保存句柄以便下一轮开始前立即清理。
    private var knownLiveActivities: [String: Activity<ETOSAgentActivityAttributes>] = [:]
    private var pendingLiveActivityRuns: [ETOSRunSnapshot]?
    private var liveActivityUpdateTask: Task<Void, Never>?

    private init() {}

    func activate() {
        guard cancellables.isEmpty else { return }
        let service = ChatService.shared
        service.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        service.sessionRequestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handleSessionRequestStatus(event) }
            .store(in: &cancellables)
        service.conversationRuntimeStatesSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        Task { [weak self] in
            guard let self else { return }
            let snapshots = await replySnapshotStore.load()
            replyRunTracker.mergePersisted(
                snapshots,
                runningSessionIDs: ChatService.shared.runningSessionIDsSubject.value
            )
            await persistReplyRuns()
            scheduleRefresh()
        }
        scheduleRefresh()
    }

    private func handleSessionRequestStatus(_ event: ChatService.SessionRequestStatusEvent) {
        let title = ChatService.shared.chatSessionsSubject.value
            .first(where: { $0.id == event.sessionID })?
            .name ?? NSLocalizedString("新的对话", comment: "Fallback session title for reply Live Activity")
        replyRunTracker.record(
            status: event.status,
            sessionID: event.sessionID,
            title: title
        )
        Task { [weak self] in
            await self?.persistReplyRuns()
        }
        let isTerminal = event.status != .started
        scheduleRefresh(immediately: true, protectBackgroundWork: isTerminal)
    }

    private func scheduleRefresh(
        immediately: Bool = false,
        protectBackgroundWork: Bool = false
    ) {
        if protectBackgroundWork, refreshBackgroundLease == nil {
            refreshBackgroundLease = ApplicationBackgroundTaskLease(name: "chat.reply.live-activity")
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            defer {
                if !Task.isCancelled {
                    self?.refreshBackgroundLease?.end()
                    self?.refreshBackgroundLease = nil
                }
            }
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        let runningIDs = ChatService.shared.runningSessionIDsSubject.value
        let dailyPulseTitle = DailyPulseManager.shared.todayRun?.headline
        let replyRuns = replyRunTracker.recentSnapshots
        let result = await Task.detached(priority: .utility) {
            let sessions = Array(Persistence.loadChatSessions().prefix(20))
            var agentSessionIDs: Set<UUID> = []
            let agentRuns = sessions.compactMap { session -> ETOSRunSnapshot? in
                guard Persistence.localAgentMode(sessionID: session.id) == .agent else {
                    return nil
                }
                agentSessionIDs.insert(session.id)
                guard let run = Persistence.loadLatestConversationRun(sessionID: session.id) else {
                    return nil
                }
                return ETOSRunSnapshot(
                    id: run.id,
                    sessionID: session.id,
                    title: session.name,
                    status: Self.snapshotStatus(run.status, isRunning: runningIDs.contains(session.id)),
                    startedAt: run.startedAt ?? run.createdAt,
                    updatedAt: run.finishedAt ?? run.startedAt ?? run.createdAt,
                    requiresApp: run.status == .waitingUser || run.status == .pausedByBudget
                )
            }
            let runs = (agentRuns + replyRuns.filter { !agentSessionIDs.contains($0.sessionID) })
            .sorted { $0.updatedAt > $1.updatedAt }
            let snapshot = ETOSWidgetSnapshot(
                recentRuns: Array(runs.prefix(5)),
                recentSessions: sessions.prefix(10).map { ETOSSessionSummary(id: $0.id, name: $0.name) },
                dailyPulseTitle: dailyPulseTitle
            )
            if let layout = ETOSSharedStorageLayout.resolve() {
                try? layout.prepare()
                try? ETOSSharedFileStore.write(
                    snapshot,
                    to: layout.runSnapshots.appendingPathComponent("widget.json"),
                    fileProtection: .completeFileProtectionUntilFirstUserAuthentication
                )
            }
            return (runs: runs, agentSessionIDs: agentSessionIDs)
        }.value
        guard !Task.isCancelled else { return }
        if replyRunTracker.remove(sessionIDs: result.agentSessionIDs) {
            await persistReplyRuns()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSRecentTasksWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSDailyPulseWidget")
        guard !Task.isCancelled else { return }
        await updateLiveActivities(with: result.runs)
    }

    private func persistReplyRuns() async {
        await replySnapshotStore.save(replyRunTracker.recentSnapshots)
    }

    private func updateLiveActivities(with runs: [ETOSRunSnapshot]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        pendingLiveActivityRuns = runs
        if liveActivityUpdateTask == nil {
            // ActivityKit 的异步调用会让出主线程；串行收敛到最新快照，避免两次刷新同时创建卡片。
            liveActivityUpdateTask = Task { [weak self] in
                guard let self else { return }
                while let pending = pendingLiveActivityRuns {
                    pendingLiveActivityRuns = nil
                    await reconcileLiveActivities(with: pending)
                }
                liveActivityUpdateTask = nil
            }
        }
        await liveActivityUpdateTask?.value
    }

    private func reconcileLiveActivities(with runs: [ETOSRunSnapshot]) async {
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        for activity in Activity<ETOSAgentActivityAttributes>.activities {
            knownLiveActivities[activity.id] = activity
        }
        let activities = knownLiveActivities.values.sorted {
            let lhsCanUpdate = $0.activityState == .active || $0.activityState == .stale
            let rhsCanUpdate = $1.activityState == .active || $1.activityState == .stale
            if lhsCanUpdate != rhsCanUpdate { return lhsCanUpdate }
            return $0.id < $1.id
        }
        var retainedSessionIDs: Set<UUID> = []
        for activity in activities {
            if activity.activityState == .dismissed {
                knownLiveActivities.removeValue(forKey: activity.id)
                continue
            }
            guard let snapshot = byID[activity.attributes.runID] else {
                await activity.end(nil, dismissalPolicy: .immediate)
                knownLiveActivities.removeValue(forKey: activity.id)
                continue
            }
            // 只能复用仍可更新的系统活动。已结束卡片先移除，再允许为同一会话创建替代卡片。
            let canUpdate = activity.activityState == .active || activity.activityState == .stale
            if retainedSessionIDs.contains(snapshot.sessionID) || (!snapshot.isTerminal && !canUpdate) {
                await activity.end(nil, dismissalPolicy: .immediate)
                knownLiveActivities.removeValue(forKey: activity.id)
                continue
            }
            let content = ActivityContent(
                state: contentState(snapshot),
                staleDate: Date().addingTimeInterval(15 * 60)
            )
            if isTerminal(snapshot.status) {
                switch ReplyActivityDismissalPolicy.terminalDecision(updatedAt: snapshot.updatedAt) {
                case .immediate:
                    await activity.end(content, dismissalPolicy: .immediate)
                    knownLiveActivities.removeValue(forKey: activity.id)
                case .after(let dismissalDate):
                    if canUpdate {
                        await activity.end(content, dismissalPolicy: .after(dismissalDate))
                    }
                }
            } else {
                await activity.update(content)
            }
            retainedSessionIDs.insert(snapshot.sessionID)
        }

        for snapshot in runs where !isTerminal(snapshot.status) && !retainedSessionIDs.contains(snapshot.sessionID) {
            let attributes = ETOSAgentActivityAttributes(
                runID: snapshot.id,
                sessionID: snapshot.sessionID,
                title: snapshot.title,
                startedAt: snapshot.startedAt
            )
            let content = ActivityContent(
                state: contentState(snapshot),
                staleDate: Date().addingTimeInterval(15 * 60)
            )
            if let activity = try? Activity.request(attributes: attributes, content: content) {
                knownLiveActivities[activity.id] = activity
                retainedSessionIDs.insert(snapshot.sessionID)
            }
        }
    }

    private func contentState(_ snapshot: ETOSRunSnapshot) -> ETOSAgentActivityAttributes.ContentState {
        ETOSAgentActivityAttributes.ContentState(
            status: snapshot.status,
            currentToolDisplayName: snapshot.currentToolDisplayName,
            requiresApp: snapshot.requiresApp
        )
    }

    private func isTerminal(_ status: ETOSTaskSnapshotStatus) -> Bool {
        status == .completed || status == .failed || status == .cancelled
    }

    private nonisolated static func snapshotStatus(
        _ status: ConversationRunStatus,
        isRunning: Bool
    ) -> ETOSTaskSnapshotStatus {
        switch status {
        case .queued: return .queued
        case .running, .waitingTool, .waitingConversation: return isRunning ? .running : .queued
        case .waitingUser, .pausedByBudget: return .waitingForInput
        case .completed: return .completed
        case .failed, .interrupted: return .failed
        case .cancelled: return .cancelled
        }
    }
}
