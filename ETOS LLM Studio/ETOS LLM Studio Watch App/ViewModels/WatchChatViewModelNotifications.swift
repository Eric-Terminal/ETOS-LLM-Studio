// ============================================================================
// WatchChatViewModelNotifications.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的后台回复通知、自动播报与扩展会话管理。
// ============================================================================

import Foundation
import Combine
import WatchKit
import ETOSCore
#if canImport(UserNotifications)
import UserNotifications
#endif

extension ChatViewModel {
    func refreshCurrentSessionSendingState() {
        let wasSendingMessage = isSendingMessage
        guard let currentSessionID = currentSession?.id else {
            isSendingMessage = false
            if wasSendingMessage {
                finalizeStreamingMarkdownIfNeeded()
            }
            return
        }
        isSendingMessage = runningSessionIDs.contains(currentSessionID)
        if isSendingMessage {
            pendingSendSubmissionSessionIDs.remove(currentSessionID)
        }
        if wasSendingMessage, !isSendingMessage {
            finalizeStreamingMarkdownIfNeeded()
        }
    }

    func prepareBackgroundReplyNotificationContext(for sessionID: UUID, messages: [ChatMessage]) {
        pendingReplyNotificationContextBySessionID[sessionID] = PendingBackgroundReplyNotificationContext(
            baselineMessages: messages,
            sessionName: notificationSessionName(for: sessionID)
        )
    }

    func notifyIfAssistantReplyFinishedInBackground(for sessionID: UUID, messages: [ChatMessage]) {
        scheduleBackgroundReplyNotificationIfNeeded(for: sessionID, messages: messages)
    }

    func notifyIfAssistantReplyFinishedFromOffscreenSession(_ sessionID: UUID, messages: [ChatMessage]) {
        scheduleBackgroundReplyNotificationIfNeeded(for: sessionID, messages: messages)
    }

    private func scheduleBackgroundReplyNotificationIfNeeded(for sessionID: UUID, messages: [ChatMessage]) {
        defer { refreshBackgroundGenerationState() }
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
        let action = replyNotificationAction(for: sessionID)
        guard action != .suppress else { return }
        pendingReplyNotificationDeliveryCount += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                pendingReplyNotificationDeliveryCount -= 1
                refreshBackgroundGenerationState()
            }
            if action == .resolveTransition {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard replyNotificationAction(for: sessionID) == .deliver else { return }
            let baselineMessages = context.baselineMessages
            let (baseline, latestMarker) = await Task.detached(priority: .utility) {
                (Self.latestAssistantReplyMarker(from: baselineMessages), Self.latestAssistantReplyMarker(from: messages))
            }.value
            guard replyNotificationAction(for: sessionID) == .deliver else { return }
            guard let latestMarker, latestMarker != baseline, latestMarker != lastNotifiedAssistantMarker else { return }
            let delivered = await AppLocalNotificationCenter.shared.postChatReplyFinishedNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: notificationSnippet(for: latestMarker),
                messageID: latestMarker.id
            )
            if delivered { lastNotifiedAssistantMarker = latestMarker }
        }
#endif
    }

    private func notificationSessionName(for sessionID: UUID) -> String? {
        if let current = currentSession, current.id == sessionID {
            return current.name
        }
        return chatSessions.first(where: { $0.id == sessionID })?.name
    }

    private var applicationVisibility: BackgroundReplyNotificationPolicy.ApplicationVisibility {
        switch WKApplication.shared().applicationState {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }

    private func replyNotificationAction(for sessionID: UUID) -> BackgroundReplyNotificationPolicy.Action {
        // 会话切换也在异步发布，使用服务的当前会话，避免拿滞后的界面状态抑制通知。
        BackgroundReplyNotificationPolicy.action(
            for: applicationVisibility,
            isCurrentSession: chatService.currentSessionSubject.value?.id == sessionID
        )
    }

    nonisolated static func latestAssistantReplyMarker(from messages: [ChatMessage]) -> AssistantReplyMarker? {
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

    private nonisolated static func normalizedNotificationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncatedText(_ text: String, maxLength: Int) -> String {
        let prefix = String(text.prefix(maxLength + 1))
        guard prefix.count > maxLength else { return text }
        return String(prefix.prefix(maxLength - 1)) + "…"
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

    func refreshBackgroundGenerationState() {
        // 运行集合先释放停止按钮；等通知提交后再结束扩展会话和后台保活。
        let active = !runningSessionIDs.isEmpty || !pendingReplyNotificationContextBySessionID.isEmpty
            || pendingReplyNotificationDeliveryCount > 0
        if active {
            startExtendedSession()
        } else {
            stopExtendedSession()
        }
        WatchBackgroundGenerationKeepAliveManager.shared.setGenerationActive(active)
        BackgroundGenerationAudioKeepAliveManager.shared.setGenerationActive(active)
    }

    func startExtendedSession() {
        if let extendedSession, extendedSession.state != .invalid { return }
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }

    func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }

#if canImport(UserNotifications)
    func enforceBackgroundReplyNotificationEnabled() {
        if !enableBackgroundReplyNotification {
            enableBackgroundReplyNotification = true
        }
    }

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
