// ============================================================================
// WatchChatViewModelNotifications.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的后台回复通知、自动播报与扩展会话管理。
// ============================================================================

import Foundation
import WatchKit
import Shared
#if canImport(UserNotifications)
import UserNotifications
#endif

extension ChatViewModel {
    private func refreshCurrentSessionSendingState() {
        guard let currentSessionID = currentSession?.id else {
            isSendingMessage = false
            return
        }
        isSendingMessage = runningSessionIDs.contains(currentSessionID)
    }

    private func prepareBackgroundReplyNotificationContext(for sessionID: UUID) {
        let messages = sessionID == currentSession?.id
            ? allMessagesForSession
            : Persistence.loadMessages(for: sessionID)
        let baseline = latestAssistantReplyMarker(from: messages)
        pendingReplyNotificationContextBySessionID[sessionID] = PendingBackgroundReplyNotificationContext(
            baselineMarker: baseline,
            sessionName: notificationSessionName(for: sessionID)
        )
    }

    private func notifyIfAssistantReplyFinishedInBackground(for sessionID: UUID) {
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
#else
        return
#endif
        guard isApplicationInBackground else {
            pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID)
            return
        }
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }

        let messages = sessionID == currentSession?.id
            ? allMessagesForSession
            : Persistence.loadMessages(for: sessionID)
        guard let latestMarker = latestAssistantReplyMarker(from: messages) else { return }
        guard latestMarker != context.baselineMarker else { return }
        guard latestMarker != lastNotifiedAssistantMarker else { return }
        lastNotifiedAssistantMarker = latestMarker

        let snippet = notificationSnippet(for: latestMarker)
#if canImport(UserNotifications)
        Task {
            guard await requestBackgroundReplyNotificationAuthorizationIfNeeded() else { return }
            await postBackgroundReplyLocalNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: snippet,
                messageID: latestMarker.id
            )
        }
#endif
    }

    private func notifyIfAssistantReplyFinishedFromOffscreenSession(_ sessionID: UUID) {
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
#else
        return
#endif
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }
        let messages = Persistence.loadMessages(for: sessionID)
        guard let latestMarker = latestAssistantReplyMarker(from: messages) else { return }
        guard latestMarker != context.baselineMarker else { return }
        guard latestMarker != lastNotifiedAssistantMarker else { return }
        lastNotifiedAssistantMarker = latestMarker

        let snippet = notificationSnippet(for: latestMarker)
#if canImport(UserNotifications)
        Task {
            guard await requestBackgroundReplyNotificationAuthorizationIfNeeded() else { return }
            await postBackgroundReplyLocalNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: snippet,
                messageID: latestMarker.id
            )
        }
#endif
    }

    private func notificationSessionName(for sessionID: UUID) -> String? {
        if let current = currentSession, current.id == sessionID {
            return current.name
        }
        return chatSessions.first(where: { $0.id == sessionID })?.name
    }

    private var isApplicationInBackground: Bool {
        WKExtension.shared().applicationState != .active
    }

    private func latestAssistantReplyMarker(from messages: [ChatMessage]) -> AssistantReplyMarker? {
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

    private func notificationSnippet(for marker: AssistantReplyMarker) -> String {
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

    private func normalizedNotificationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncatedText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    private func autoPlayLatestAssistantMessageIfNeeded() {
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
        ttsManager.updateSelectedModel(selectedTTSModel)
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

    nonisolated static func inputByAppendingCodeBlockContent(_ rawCodeBlockContent: String, to currentInput: String) -> String? {
        let normalizedCodeBlockContent = rawCodeBlockContent.trimmingCharacters(in: .newlines)
        guard !normalizedCodeBlockContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return nil }

        if currentInput.isEmpty {
            return normalizedCodeBlockContent
        }
        if currentInput.hasSuffix("\n") || currentInput.last?.isWhitespace == true {
            return currentInput + normalizedCodeBlockContent
        }
        return currentInput + "\n" + normalizedCodeBlockContent
    }

#if canImport(UserNotifications)
    private func postBackgroundReplyLocalNotification(sessionID: UUID, sessionName: String?, snippet: String, messageID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("AI 回复已完成", comment: "Background reply notification title")
        if let sessionName, !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = String(
                format: NSLocalizedString("会话“%@”已收到新回复：%@", comment: "Background reply notification body with session name"),
                sessionName,
                snippet
            )
        } else {
            content.body = String(
                format: NSLocalizedString("已收到新回复：%@", comment: "Background reply notification body without session name"),
                snippet
            )
        }
        content.sound = .default
        content.threadIdentifier = "chat.reply.finished"
        content.userInfo = [
            "route": AppLocalNotificationRoute.chatSession.rawValue,
            "session_id": sessionID.uuidString
        ]
        if #available(watchOS 8.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        let request = UNNotificationRequest(
            identifier: "chat.reply.finished.\(messageID.uuidString)",
            content: content,
            trigger: nil
        )

        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { _ in
                continuation.resume(returning: ())
            }
        }
    }
#endif

    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }

    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }

#if canImport(UserNotifications)
    private func enforceBackgroundReplyNotificationEnabled() {
        if !enableBackgroundReplyNotification {
            enableBackgroundReplyNotification = true
        }
    }

    private func requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded() {
        enforceBackgroundReplyNotificationEnabled()
        guard !hasRequestedBackgroundReplyNotificationPermission else { return }
        hasRequestedBackgroundReplyNotificationPermission = true
        Task {
            _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
        }
    }

    private func requestBackgroundReplyNotificationAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
#endif
}
