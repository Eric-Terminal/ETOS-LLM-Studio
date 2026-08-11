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
        let runs = await Task.detached(priority: .utility) {
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
            return runs
        }.value
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSRecentTasksWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "ETOSDailyPulseWidget")
        SystemFileProviderDomainManager.signalChanges()
        await updateLiveActivities(with: runs)
    }

    private func updateLiveActivities(with runs: [ETOSRunSnapshot]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        for activity in Activity<ETOSAgentActivityAttributes>.activities {
            guard let snapshot = byID[activity.attributes.runID] else {
                await activity.end(nil, dismissalPolicy: .default)
                continue
            }
            let content = ActivityContent(
                state: contentState(snapshot),
                staleDate: Date().addingTimeInterval(15 * 60)
            )
            if isTerminal(snapshot.status) {
                await activity.end(content, dismissalPolicy: .default)
            } else {
                await activity.update(content)
            }
        }

        let activeIDs = Set(Activity<ETOSAgentActivityAttributes>.activities.map(\.attributes.runID))
        for snapshot in runs where !isTerminal(snapshot.status) && !activeIDs.contains(snapshot.id) {
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
            _ = try? Activity.request(attributes: attributes, content: content)
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
