// ============================================================================
// ChatViewModelBackgroundNotifications.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责后台回复通知、后台任务续期和自动朗读最新助手回复。
// ============================================================================

import Foundation
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

extension ChatViewModel {
    func requestBackgroundReplyNotificationPermission() {
#if canImport(UserNotifications)
        Task {
            _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
        }
#endif
    }

    func openSystemNotificationSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    func enforceBackgroundReplyNotificationEnabled() {
        if !enableBackgroundReplyNotification {
            enableBackgroundReplyNotification = true
        }
    }

    func prepareBackgroundReplyNotificationContext(for sessionID: UUID) {
        let messages = sessionID == currentSession?.id
            ? allMessagesForSession
            : Persistence.loadMessages(for: sessionID)
        let baseline = latestAssistantReplyMarker(from: messages)
        pendingReplyNotificationContextBySessionID[sessionID] = PendingBackgroundReplyNotificationContext(
            baselineMarker: baseline,
            sessionName: notificationSessionName(for: sessionID)
        )
    }

    func notifyIfAssistantReplyFinishedInBackground(for sessionID: UUID) {
        scheduleBackgroundReplyNotificationIfNeeded(for: sessionID)
    }

    func notifyIfAssistantReplyFinishedFromOffscreenSession(_ sessionID: UUID) {
        scheduleBackgroundReplyNotificationIfNeeded(for: sessionID)
    }

    private func scheduleBackgroundReplyNotificationIfNeeded(for sessionID: UUID) {
        enforceBackgroundReplyNotificationEnabled()
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }
#if canImport(UserNotifications)
        let action = BackgroundReplyNotificationPolicy.action(for: applicationVisibility)
        guard action != .suppress else { return }
        let backgroundTaskLease = ApplicationBackgroundTaskLease(name: "chat.reply.notification")
        Task { @MainActor [weak self, backgroundTaskLease] in
            defer { backgroundTaskLease.end() }
            guard let self else { return }
            if action == .resolveTransition {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard BackgroundReplyNotificationPolicy.action(for: applicationVisibility) == .deliver else {
                return
            }

            let messages: [ChatMessage]
            if sessionID == currentSession?.id {
                messages = allMessagesForSession
            } else {
                messages = await Task.detached(priority: .utility) {
                    Persistence.loadMessages(for: sessionID)
                }.value
            }
            guard BackgroundReplyNotificationPolicy.action(for: applicationVisibility) == .deliver else {
                return
            }
            guard let latestMarker = latestAssistantReplyMarker(from: messages) else { return }
            guard latestMarker != context.baselineMarker else { return }
            guard latestMarker != lastNotifiedAssistantMarker else { return }
            lastNotifiedAssistantMarker = latestMarker

            _ = await AppLocalNotificationCenter.shared.postChatReplyFinishedNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: notificationSnippet(for: latestMarker),
                messageID: latestMarker.id
            )
        }
#endif
    }

    func notificationSessionName(for sessionID: UUID) -> String? {
        if let current = currentSession, current.id == sessionID {
            return current.name
        }
        return chatSessions.first(where: { $0.id == sessionID })?.name
    }

    func autoPlayLatestAssistantMessageIfNeeded() {
        let settings = TTSSettingsStore.shared.snapshot
        let latest = allMessagesForSession.last(where: { $0.role == .assistant })
        guard Self.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: settings.autoPlayAfterAssistantResponse,
            latestAssistantMessage: latest,
            lastAutoPlayedAssistantMessageID: lastAutoPlayedAssistantMessageID,
            currentSpeakingMessageID: ttsManager.currentSpeakingMessageID,
            isCurrentlySpeaking: ttsManager.isSpeaking
        ), let latest else { return }
        lastAutoPlayedAssistantMessageID = latest.id
        ttsManager.speak(latest.content, messageID: latest.id, flush: true)
    }

    nonisolated static func shouldAutoPlayAssistantMessage(
        autoPlayEnabled: Bool,
        latestAssistantMessage: ChatMessage?,
        lastAutoPlayedAssistantMessageID: UUID?,
        currentSpeakingMessageID: UUID?,
        isCurrentlySpeaking: Bool
    ) -> Bool {
        guard autoPlayEnabled else { return false }
        guard let latestAssistantMessage else { return false }
        guard !latestAssistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard latestAssistantMessage.id != lastAutoPlayedAssistantMessageID else { return false }
        if currentSpeakingMessageID == latestAssistantMessage.id, isCurrentlySpeaking {
            return false
        }
        return true
    }

    private var applicationVisibility: BackgroundReplyNotificationPolicy.ApplicationVisibility {
#if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
#else
        return .active
#endif
    }

    func latestAssistantReplyMarker(from messages: [ChatMessage]) -> AssistantReplyMarker? {
        for message in ChatResponseAttemptSupport.visibleMessages(from: messages).reversed() where message.role == .assistant {
            let normalizedText = normalizedNotificationText(message.content)
            let imageCount = message.imageFileNames?.count ?? 0
            let hasAudio = message.audioFileName != nil
            let fileCount = message.fileFileNames?.count ?? 0
            if normalizedText.isEmpty && imageCount == 0 && !hasAudio && fileCount == 0 {
                continue
            }
            return AssistantReplyMarker(
                id: message.id,
                versionIndex: message.getCurrentVersionIndex(),
                normalizedContent: normalizedText,
                imageCount: imageCount,
                hasAudio: hasAudio,
                fileCount: fileCount
            )
        }
        return nil
    }

    func notificationSnippet(for marker: AssistantReplyMarker) -> String {
        if !marker.normalizedContent.isEmpty {
            return truncatedText(marker.normalizedContent, maxLength: 80)
        }
        if marker.imageCount > 0 {
            return NSLocalizedString("你收到了新的图片回复。", comment: "Background reply notification fallback for image response")
        }
        if marker.hasAudio {
            return NSLocalizedString("你收到了新的语音回复。", comment: "Background reply notification fallback for audio response")
        }
        if marker.fileCount > 0 {
            return NSLocalizedString("你收到了新的文件回复。", comment: "Background reply notification fallback for file response")
        }
        return NSLocalizedString("你收到了新的回复。", comment: "Background reply notification fallback for generic response")
    }

    func normalizedNotificationText(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    func truncatedText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

#if canImport(UIKit)
    func beginBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier == .invalid else { return }
        activeBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "chat.reply.background") { [weak self] in
            guard let self else { return }
            self.endBackgroundTaskIfNeeded()
        }
    }

    func endBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(activeBackgroundTaskIdentifier)
        activeBackgroundTaskIdentifier = .invalid
    }
#else
    func beginBackgroundTaskIfNeeded() {}
    func endBackgroundTaskIfNeeded() {}
#endif

#if canImport(UserNotifications)
    func requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded() {
        Task {
            await Task.yield()
            enforceBackgroundReplyNotificationEnabled()
            guard !hasRequestedBackgroundReplyNotificationPermission else { return }
            hasRequestedBackgroundReplyNotificationPermission = true
            _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
        }
    }

    func requestBackgroundReplyNotificationAuthorizationIfNeeded() async -> Bool {
        await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded()
    }
#endif
}
