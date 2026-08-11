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

    private init() {}

    func activate() {
        guard cancellables.isEmpty else { return }
        let service = ChatService.shared
        service.chatSessionsSubject
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        service.sessionRequestStatusSubject
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        service.conversationRuntimeStatesSubject
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        let runningIDs = ChatService.shared.runningSessionIDsSubject.value
        let dailyPulseTitle = DailyPulseManager.shared.todayRun?.headline
        await Task.detached(priority: .utility) {
            let sessions = Array(Persistence.loadChatSessions().prefix(20))
            let runs = sessions.compactMap { session -> ETOSRunSnapshot? in
                guard Persistence.localAgentMode(sessionID: session.id) == .agent,
                      let run = Persistence.loadLatestConversationRun(sessionID: session.id) else {
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
        }.value
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSWatchRecentTaskWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSWatchDailyPulseWidget")
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
                ChatService.shared.setCurrentSession(session)
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
