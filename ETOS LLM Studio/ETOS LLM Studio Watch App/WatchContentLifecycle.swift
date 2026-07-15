// ============================================================================
// WatchContentLifecycle.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 主视图的字体刷新、通知路由和启动期任务管理。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

extension ContentView {
    func refreshRootBodyFont() {
        rootBodyFont = AppFontAdapter.adaptedFont(
            from: .body,
            sampleText: "The quick brown fox 你好こんにちは"
        )
    }

    func refreshAttachmentSourceHistory() {
        importSourceHistory = WatchImportSourceHistory.values(
            from: appConfig.watchAttachmentSourceHistory,
            fallback: appConfig.watchAttachmentLastSource
        )
    }

    func openDailyPulse() {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .dailyPulse
        }
    }

    func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    func openChatSessionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.consumePendingChatSessionID() else { return }
        openChatSession(sessionID: sessionID)
    }

    func openContextCompressionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.pendingContextCompressionSessionID,
              let session = viewModel.chatSessions.first(where: { $0.id == sessionID }),
              !session.isTemporary else {
            return
        }
        openChatSession(sessionID: sessionID)
        contextCompressionReminderSourceSession = session
        _ = notificationCenter.consumePendingContextCompressionSessionID()
    }

    func openAchievementJournalFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openAchievementJournal()
    }

    func openUpdateTimelineFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openUpdateTimeline()
    }

    func openChatSession(sessionID: UUID) {
        guard viewModel.setCurrentSessionIfExists(sessionID: sessionID) else { return }
        isSettingsPresented = false
        settingsDestination = nil
    }

    func openFeedback(issueNumber: Int?) {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            if let issueNumber,
               FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
                settingsDestination = .feedbackIssue(issueNumber: issueNumber)
            } else {
                settingsDestination = .feedbackCenter
            }
        }
    }

    func openAchievementJournal() {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .achievementJournal
        }
    }

    func openUpdateTimeline() {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .updateTimeline
        }
    }

    @discardableResult
    func applyDailyPulseContinuationIfNeeded() -> Bool {
        guard let continuation = notificationCenter.consumePendingDailyPulseContinuation() else {
            return false
        }
        viewModel.applyDailyPulseContinuation(
            sessionID: continuation.sessionID,
            prompt: continuation.prompt
        )
        isSettingsPresented = false
        settingsDestination = nil
        return true
    }

    var inputPlaceholderText: String {
        NSLocalizedString("输入...", comment: "Default input placeholder on watch")
    }

    func scheduleDailyPulsePreparation(after delayNanoseconds: UInt64) {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = Task(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let isSceneActive = await MainActor.run { scenePhase == .active }
            guard isSceneActive else { return }
            await viewModel.prepareDailyPulseIfNeeded()
            guard !Task.isCancelled else { return }
            await viewModel.prepareMorningDailyPulseDeliveryIfNeeded()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dailyPulsePreparationTask = nil
            }
        }
    }

    func cancelDailyPulsePreparation() {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = nil
    }
}
