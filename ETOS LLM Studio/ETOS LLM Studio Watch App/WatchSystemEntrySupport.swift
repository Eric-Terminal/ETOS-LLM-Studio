// ============================================================================
// WatchSystemEntrySupport.swift
// ETOS LLM Studio Watch App
// ============================================================================

import Combine
import ETOSCore
import Foundation
import WidgetKit

@MainActor
final class WatchSystemEntrySnapshotPublisher {
    static let shared = WatchSystemEntrySnapshotPublisher()

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var replyRunTracker = ReplyActivityRunTracker()
    private let replySnapshotStore = ReplyActivitySnapshotStore()

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
            .first(where: { $0.id == event.sessionID })?.name
            ?? NSLocalizedString("新的对话", comment: "小组件的默认会话标题")
        replyRunTracker.record(status: event.status, sessionID: event.sessionID, title: title)
        Task { [weak self] in await self?.persistReplyRuns() }
        scheduleRefresh(immediately: true)
    }

    private func persistReplyRuns() async {
        await replySnapshotStore.save(replyRunTracker.recentSnapshots)
    }

    private func scheduleRefresh(immediately: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
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
        let agentSessionIDs = await Task.detached(priority: .utility) {
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
                .sorted {
                    if $0.isTerminal != $1.isTerminal { return !$0.isTerminal }
                    return $0.updatedAt > $1.updatedAt
                }
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
            return agentSessionIDs
        }.value
        if replyRunTracker.remove(sessionIDs: agentSessionIDs) {
            await persistReplyRuns()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSWatchRecentTaskWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSWatchDailyPulseWidget")
        if #available(watchOS 11.0, *) {
            WidgetCenter.shared.invalidateRelevance(ofKind: "ETOSWatchRecentTaskWidget")
        }
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

enum WatchSystemEntryURLRouter {
    @MainActor
    static func handle(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == ETOSSystemEntryConstants.appURLScheme,
              url.host?.lowercased() == "open" else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let destination = components.first else { return true }
        if destination == "session", components.count > 1,
           let sessionID = UUID(uuidString: components[1]) {
            let session = await Task.detached(priority: .userInitiated) {
                Persistence.loadChatSession(id: sessionID)
            }.value
            if let session {
                await ChatService.shared.selectSession(session)
            }
        } else if destination == "new-agent" {
            let session = ChatService.shared.createSavedSession(
                name: NSLocalizedString("新的 Agent 任务", comment: "Watch widget Agent session title")
            )
            _ = await Task.detached(priority: .userInitiated) {
                Persistence.saveLocalAgentMode(.agent, sessionID: session.id)
            }.value
        } else if destination == "daily-pulse" {
            NotificationCenter.default.post(name: .requestOpenDailyPulse, object: nil)
        }
        return true
    }
}
