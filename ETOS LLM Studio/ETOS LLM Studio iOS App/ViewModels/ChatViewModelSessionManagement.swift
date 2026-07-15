// ============================================================================
// ChatViewModelSessionManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatViewModel 中会话、文件夹、消息编辑、重试与消息版本管理。
// ============================================================================

import Foundation
import Combine
import ETOSCore
import os.log

extension ChatViewModel {
    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }

    func deleteMessages(withIDs messageIDs: Set<UUID>) {
        chatService.deleteMessages(withIDs: messageIDs)
    }

    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        chatService.deleteSessions(sessionsToDelete)
    }

    func deleteSessions(_ sessions: [ChatSession]) {
        chatService.deleteSessions(sessions)
    }

    func messageCount(for session: ChatSession) -> Int {
        if session.id == currentSession?.id {
            return allMessagesForSession.count
        }
        if let temporaryCount = chatService.temporaryChatMessageCount(for: session.id) {
            return temporaryCount
        }
        return Persistence.loadMessageCount(for: session.id)
    }

    @discardableResult
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
    }

    @discardableResult
    func branchSessionFromMessage(upToMessage: ChatMessage, copyPrompts: Bool) -> ChatSession {
        guard let session = currentSession else {
            logger.error("无法创建分支会话：当前会话为空，将创建新会话作为回退。")
            chatService.createNewSession()
            if let fallbackSession = chatService.currentSessionSubject.value {
                return fallbackSession
            }
            logger.error("创建新会话失败，返回临时会话实例作为回退。")
            return ChatSession(id: UUID(), name: NSLocalizedString("新的对话", comment: ""), isTemporary: true)
        }
        return chatService.branchSessionFromMessage(from: session, upToMessage: upToMessage, copyPrompts: copyPrompts)
    }

    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }

    func createNewSession() {
        chatService.createNewSession()
    }

    func isTemporaryChatEnabled(for sessionID: UUID?) -> Bool {
        chatService.isTemporaryChatEnabled(for: sessionID)
    }

    func enableTemporaryChat() {
        chatService.enableTemporaryChat()
    }

    @discardableResult
    func saveCurrentTemporarySession() -> Bool {
        chatService.saveCurrentTemporaryChat()
    }

    func reloadPersistedDataAfterLegacyJSONMigration() {
        chatService.reloadSessionStateFromPersistenceAfterMigration()
    }

    func prepareDailyPulseIfNeeded() async {
        await DailyPulseManager.shared.generateIfNeeded()
    }

    func prepareMorningDailyPulseDeliveryIfNeeded(referenceDate: Date = Date()) async {
        let coordinator = DailyPulseDeliveryCoordinator.shared
        await DailyPulseManager.shared.generateForScheduledDeliveryIfNeeded(
            reminderEnabled: coordinator.reminderEnabled,
            reminderHour: coordinator.reminderHour,
            reminderMinute: coordinator.reminderMinute,
            referenceDate: referenceDate
        )
    }

    @discardableResult
    func saveDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) -> ChatSession? {
        if let savedSessionID = card.savedSessionID,
           let existing = chatSessions.first(where: { $0.id == savedSessionID }) {
            chatService.setCurrentSession(existing)
            return existing
        }
        return DailyPulseManager.shared.saveCardAsSession(cardID: card.id, runID: runID)
    }

    func continueDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) {
        guard let session = saveDailyPulseCard(card, from: runID) else { return }
        chatService.setCurrentSession(session)
        userInput = DailyPulseManager.defaultContinuationPrompt(for: card)
        NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
    }

    func applyDailyPulseContinuation(sessionID: UUID, prompt: String) {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            chatService.setCurrentSession(session)
        }
        userInput = prompt
    }

    func setSelectedModel(_ model: RunnableModel) {
        chatService.setSelectedModel(model)
    }

    func setCurrentSession(_ session: ChatSession) {
        chatService.setCurrentSession(session)
    }

    func requestMessageJump(sessionID: UUID, messageOrdinal: Int) {
        pendingSearchJumpTarget = SessionMessageJumpTarget(sessionID: sessionID, messageOrdinal: messageOrdinal)
    }

    func clearPendingMessageJumpTarget() {
        pendingSearchJumpTarget = nil
    }

    @discardableResult
    func setCurrentSessionIfExists(sessionID: UUID) -> Bool {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            chatService.setCurrentSession(session)
            return true
        }
        return false
    }

    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }

    func updateSessionName(_ session: ChatSession, newName: String) {
        var updated = session
        updated.name = newName
        chatService.updateSession(updated)
    }

    @discardableResult
    func createSessionFolder(name: String, parentID: UUID? = nil) -> SessionFolder? {
        chatService.createSessionFolder(name: name, parentID: parentID)
    }

    func renameSessionFolder(_ folder: SessionFolder, newName: String) {
        chatService.renameSessionFolder(folderID: folder.id, newName: newName)
    }

    func deleteSessionFolder(_ folder: SessionFolder) {
        chatService.deleteSessionFolder(folderID: folder.id)
    }

    func moveSessionFolder(_ folder: SessionFolder, toParentID parentID: UUID?) {
        chatService.moveSessionFolder(folder, toParentID: parentID)
    }

    func moveSession(_ session: ChatSession, toFolderID folderID: UUID?) {
        chatService.moveSession(session, toFolderID: folderID)
    }

    @discardableResult
    func createSessionTag(name: String, color: SessionTagColor?) -> SessionTag? {
        chatService.createSessionTag(name: name, color: color)
    }

    func updateSessionTag(_ tag: SessionTag, name: String, color: SessionTagColor?) {
        chatService.updateSessionTag(tag, name: name, color: color)
    }

    func deleteSessionTag(_ tag: SessionTag) {
        chatService.deleteSessionTag(tag)
    }

    func setSessionTags(for session: ChatSession, tagIDs: [UUID]) {
        chatService.setSessionTags(sessionID: session.id, tagIDs: tagIDs)
    }

    func commitEditedMessage(_ updatedMessage: ChatMessage) {
        chatService.updateMessage(updatedMessage)
        messageToEdit = nil
    }

    func retryMessage(_ message: ChatMessage) {
        Task {
            await chatService.retryMessage(
                message,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }

    func rewriteMessage(
        _ message: ChatMessage,
        instruction: String,
        referenceVersions: [MessageRewriteReferenceVersion] = [],
        selectionTarget: MessageRewriteSelectionTarget? = nil
    ) {
        let sessionID = currentSession?.id
        Task {
            do {
                try await chatService.rewriteMessage(
                    message,
                    instruction: instruction,
                    aiTemperature: aiTemperature,
                    sessionID: sessionID,
                    referenceVersions: referenceVersions,
                    selectionTarget: selectionTarget
                )
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    messageRewriteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func canRetry(message: ChatMessage) -> Bool {
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            guard message.role == .user else { return false }
            return allMessagesForSession.last(where: { $0.role == .user })?.id == message.id
        }

        return message.role == .user || message.role == .assistant || message.role == .error
    }

    func canRewrite(message: ChatMessage) -> Bool {
        guard !isSendingMessage else { return false }
        guard message.role == .assistant else { return false }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveCurrentSessionDetails() {
        guard let session = currentSession else { return }
        chatService.updateSession(session)
    }

    func responseAttemptVersionInfo(for message: ChatMessage) -> ChatResponseAttemptVersionInfo? {
        ChatResponseAttemptSupport.versionInfo(for: message, in: allMessagesForSession)
    }

    func hasDisplayVersions(for message: ChatMessage) -> Bool {
        responseAttemptVersionInfo(for: message) != nil || message.hasMultipleVersions
    }

    func displayVersionCount(for message: ChatMessage) -> Int {
        responseAttemptVersionInfo(for: message)?.totalCount ?? message.getAllVersions().count
    }

    func displayCurrentVersionIndex(for message: ChatMessage) -> Int {
        responseAttemptVersionInfo(for: message)?.currentIndex ?? message.getCurrentVersionIndex()
    }

    func switchToPreviousVersion(of message: ChatMessage) {
        if let updatedMessages = ChatResponseAttemptSupport.selectPreviousAttempt(for: message, in: allMessagesForSession) {
            updateMessages(updatedMessages)
            return
        }
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }

        let newIndex = max(0, updatedMessage.getCurrentVersionIndex() - 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }

    func switchToNextVersion(of message: ChatMessage) {
        if let updatedMessages = ChatResponseAttemptSupport.selectNextAttempt(for: message, in: allMessagesForSession) {
            updateMessages(updatedMessages)
            return
        }
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }

        let newIndex = min(updatedMessage.getAllVersions().count - 1, updatedMessage.getCurrentVersionIndex() + 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }

    func switchToVersion(_ index: Int, of message: ChatMessage) {
        if let info = responseAttemptVersionInfo(for: message) {
            let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: info.responseGroupID, in: allMessagesForSession)
            guard attempts.indices.contains(index) else { return }
            updateMessages(ChatResponseAttemptSupport.selectAttempt(attemptID: attempts[index], groupID: info.responseGroupID, in: allMessagesForSession))
            return
        }
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.switchToVersion(index)
        updateMessage(updatedMessage)
    }

    func deleteCurrentVersion(of message: ChatMessage) {
        deleteVersion(at: displayCurrentVersionIndex(for: message), of: message)
    }

    func deleteVersion(at index: Int, of message: ChatMessage) {
        if responseAttemptVersionInfo(for: message) != nil {
            if deleteResponseAttemptVersion(at: index, of: message) {
                return
            }
        }

        guard var updatedMessage = findMessage(by: message.id) else { return }

        if updatedMessage.getAllVersions().count <= 1 {
            deleteMessage(updatedMessage)
            return
        }

        guard updatedMessage.removeVersionAndReturnCurrentIndex(at: index) != nil else { return }
        updateMessage(updatedMessage)
    }

    func deleteAllVersions(of message: ChatMessage) {
        chatService.deleteAllVersions(of: message)
    }

    func addVersionToMessage(_ message: ChatMessage, newContent: String) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.addVersion(newContent)
        updateMessage(updatedMessage)
    }

    func findMessage(by id: UUID) -> ChatMessage? {
        allMessagesForSession.first { $0.id == id }
    }

    func updateMessage(_ message: ChatMessage) {
        guard let index = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else { return }
        var updatedMessages = allMessagesForSession
        updatedMessages[index] = message
        updateMessages(updatedMessages)
    }

    func updateMessages(_ updatedMessages: [ChatMessage]) {
        chatService.updateMessages(updatedMessages, for: currentSession?.id ?? UUID())
        saveCurrentSessionDetails()
    }

    func deleteResponseAttemptVersion(at index: Int, of message: ChatMessage) -> Bool {
        guard let groupID = message.responseGroupID,
              message.responseAttemptID != nil else {
            return false
        }

        guard let updatedMessages = ChatResponseAttemptSupport.deleteAttempt(
            at: index,
            groupID: groupID,
            in: allMessagesForSession
        ) else { return false }

        updateMessages(updatedMessages)
        return true
    }
}
