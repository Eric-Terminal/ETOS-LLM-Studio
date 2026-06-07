// ============================================================================
// ChatServiceLaunchState.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 启动时的持久化会话加载与上次活跃会话恢复。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    struct LaunchPersistenceState {
        let sessionFolders: [SessionFolder]
        let sessionTags: [SessionTag]
        let loadedSessions: [ChatSession]
        let initialSession: ChatSession
        let initialMessages: [ChatMessage]
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func loadLaunchPersistenceState(using temporarySession: ChatSession) -> LaunchPersistenceState {
        let sessionFolders = Persistence.loadSessionFolders()
        let sessionTags = Persistence.loadSessionTags()
        let persistedSessions = Persistence.loadChatSessions()
        var loadedSessions = persistedSessions
        loadedSessions.insert(temporarySession, at: 0)
        let initialSession = ChatService.resolveInitialSession(
            persistedSessions: persistedSessions,
            loadedSessionsWithTemporary: loadedSessions,
            newTemporarySession: temporarySession
        )
        let initialMessages = initialSession.id == temporarySession.id
            ? []
            : Persistence.loadMessages(for: initialSession.id)

        return LaunchPersistenceState(
            sessionFolders: sessionFolders,
            sessionTags: sessionTags,
            loadedSessions: loadedSessions,
            initialSession: initialSession,
            initialMessages: initialMessages
        )
    }

    @discardableResult
    public func loadInitialPersistenceStateIfNeeded(priority: TaskPriority = .userInitiated) -> Task<Void, Never>? {
        startupStateLoadLock.lock()
        if let startupStateLoadTask {
            startupStateLoadLock.unlock()
            return startupStateLoadTask
        }
        let shouldStart = !hasTriggeredStartupStateLoad && !hasCompletedStartupStateLoad
        if shouldStart {
            hasTriggeredStartupStateLoad = true
        }
        guard shouldStart else {
            startupStateLoadLock.unlock()
            return nil
        }

        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            let launchState = Self.loadLaunchPersistenceState(using: self.startupTemporarySession)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.shouldApplyLaunchPersistenceState() {
                    self.sessionFoldersSubject.send(launchState.sessionFolders)
                    self.sessionTagsSubject.send(launchState.sessionTags)
                    self.chatSessionsSubject.send(launchState.loadedSessions)
                    self.currentSessionSubject.send(launchState.initialSession)
                    self.messagesForSessionSubject.send(launchState.initialMessages)
                    self.logger.info("启动持久化状态已异步加载完成。")
                } else {
                    self.logger.info("启动持久化状态已加载，但检测到前台状态已变更，已跳过覆盖。")
                }
                self.markStartupStateLoadCompleted()
            }
        }
        startupStateLoadTask = task
        startupStateLoadLock.unlock()

        return task
    }

    public func waitForInitialPersistenceStateIfNeeded(priority: TaskPriority = .userInitiated) async {
        if let task = loadInitialPersistenceStateIfNeeded(priority: priority) {
            await task.value
        }
    }

    func markStartupStateLoadCompleted() {
        startupStateLoadLock.lock()
        hasCompletedStartupStateLoad = true
        startupStateLoadTask = nil
        startupStateLoadLock.unlock()
    }

    func shouldApplyLaunchPersistenceState() -> Bool {
        let sessions = chatSessionsSubject.value
        guard sessions.count == 1,
              sessions.first?.id == startupTemporarySession.id else {
            return false
        }
        guard currentSessionSubject.value?.id == startupTemporarySession.id else {
            return false
        }
        guard messagesForSessionSubject.value.isEmpty else {
            return false
        }
        return true
    }

    static func resolveInitialSession(
        persistedSessions: [ChatSession],
        loadedSessionsWithTemporary: [ChatSession],
        newTemporarySession: ChatSession
    ) -> ChatSession {
        let shouldRestore = (Persistence.readAppConfigInteger(key: AppConfigKey.restoreLastSessionOnLaunch.rawValue) ?? 0) != 0
        guard shouldRestore else { return newTemporarySession }

        let rawID = AppConfigStore.textValue(
            for: .lastActiveSessionID,
            legacyUserDefaultsKey: lastActiveSessionIDStorageKey
        )
        if !rawID.isEmpty,
           let sessionID = UUID(uuidString: rawID),
           let restored = loadedSessionsWithTemporary.first(where: { $0.id == sessionID }) {
            return restored
        }

        if let mostRecentPersisted = persistedSessions.first {
            return mostRecentPersisted
        }

        return newTemporarySession
    }

    func persistLastActiveSessionIDIfNeeded(_ session: ChatSession?) {
        guard let session, !session.isTemporary else { return }
        AppConfigStore.persistSynchronously(.text(session.id.uuidString), for: .lastActiveSessionID)
    }
}
