// ============================================================================
// WatchChatViewModelConversationManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的会话、消息、版本与记忆入口管理。
// ============================================================================

import Foundation
import Combine
import os.log
import ETOSCore

extension ChatViewModel {
    func deleteMessage(at offsets: IndexSet) {
        // 此方法已废弃，因为直接操作 messages 数组不安全
        // 应该通过 message ID 来删除
    }

    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }

    func deleteMessages(withIDs messageIDs: Set<UUID>) {
        chatService.deleteMessages(withIDs: messageIDs)
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

    private func findMessage(by id: UUID) -> ChatMessage? {
        allMessagesForSession.first { $0.id == id }
    }

    private func updateMessage(_ message: ChatMessage) {
        guard let index = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else { return }
        var updatedMessages = allMessagesForSession
        updatedMessages[index] = message
        updateMessages(updatedMessages)
    }

    private func updateMessages(_ updatedMessages: [ChatMessage]) {
        chatService.updateMessages(updatedMessages, for: currentSession?.id ?? UUID())
        saveCurrentSessionDetails()
    }

    private func deleteResponseAttemptVersion(at index: Int, of message: ChatMessage) -> Bool {
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

    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        chatService.deleteSessions(sessionsToDelete)
    }

    func deleteSessions(_ sessions: [ChatSession]) {
        chatService.deleteSessions(sessions)
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
    }

    func applyDailyPulseContinuation(sessionID: UUID, prompt: String) {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            chatService.setCurrentSession(session)
        }
        userInput = prompt
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

    func requestMessageJump(sessionID: UUID, messageOrdinal: Int) {
        pendingSearchJumpTarget = SessionMessageJumpTarget(sessionID: sessionID, messageOrdinal: messageOrdinal)
    }

    func clearPendingMessageJumpTarget() {
        pendingSearchJumpTarget = nil
    }

    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }

    func addMemory(_ request: MemoryWriteRequest) async {
        await MemoryManager.shared.addMemory(request)
    }

    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }

    func archiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.archiveMemory(item)
    }

    func unarchiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.unarchiveMemory(item)
    }

    func deleteMemories(at offsets: IndexSet) async {
        let itemsToDelete = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(itemsToDelete)
    }

    func reembedAllMemories(concurrencyLimit: Int = 1) async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories(concurrencyLimit: concurrencyLimit)
    }

    func reembedAllMemoriesDetailed(
        concurrencyLimit: Int = 1,
        itemProgressHandler: MemoryReembeddingItemProgressHandler? = nil
    ) async throws -> [MemoryReembeddingItemResult] {
        try await MemoryManager.shared.reembedAllMemoriesDetailed(
            concurrencyLimit: concurrencyLimit,
            itemProgressHandler: itemProgressHandler
        )
    }

    func reembedMemories(
        withIDs memoryIDs: Set<UUID>,
        concurrencyLimit: Int = 1,
        itemProgressHandler: MemoryReembeddingItemProgressHandler? = nil
    ) async throws -> [MemoryReembeddingItemResult] {
        try await MemoryManager.shared.reembedMemories(
            withIDs: memoryIDs,
            concurrencyLimit: concurrencyLimit,
            itemProgressHandler: itemProgressHandler
        )
    }

    func reloadConversationMemoryState() {
        conversationSessionSummaries = ConversationMemoryManager.loadAllSessionSummaries()
        conversationUserProfile = ConversationMemoryManager.loadUserProfile()
    }

    func deleteConversationSummary(for sessionID: UUID) {
        ConversationMemoryManager.removeSessionSummary(sessionID: sessionID)
        reloadConversationMemoryState()
    }

    @discardableResult
    func clearAllConversationSummaries() -> Int {
        let removed = ConversationMemoryManager.clearAllSessionSummaries()
        reloadConversationMemoryState()
        return removed
    }

    func saveConversationUserProfile(content: String) throws {
        try ConversationMemoryManager.saveUserProfile(content: content)
        reloadConversationMemoryState()
    }

    func clearConversationUserProfile() throws {
        try ConversationMemoryManager.clearUserProfile()
        reloadConversationMemoryState()
    }
}
