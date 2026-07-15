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

public enum LaunchSessionBehavior: String, CaseIterable, Identifiable, Sendable {
    case newSession = "new_session"
    case alwaysRestore = "always_restore"
    case restoreIfRecent = "restore_if_recent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newSession:
            return NSLocalizedString("始终新建", comment: "Launch session behavior: always start a new session")
        case .alwaysRestore:
            return NSLocalizedString("始终恢复", comment: "Launch session behavior: always restore the last session")
        case .restoreIfRecent:
            return NSLocalizedString("短时间内恢复", comment: "Launch session behavior: restore only within a recent time window")
        }
    }
}

public enum LaunchSessionPolicy {
    public static let defaultRestoreWindowMinutes = 15
    public static let minimumRestoreWindowMinutes = 1

    public static func behavior(
        restoreLastSession: Bool,
        onlyIfRecent: Bool
    ) -> LaunchSessionBehavior {
        guard restoreLastSession else { return .newSession }
        return onlyIfRecent ? .restoreIfRecent : .alwaysRestore
    }

    public static func normalizedRestoreWindowMinutes(_ value: Int) -> Int {
        max(value, minimumRestoreWindowMinutes)
    }

    public static func resolvedRestoreWindowMinutes(from draft: String, fallback: Int) -> Int {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmedDraft) else {
            return normalizedRestoreWindowMinutes(fallback)
        }
        return normalizedRestoreWindowMinutes(value)
    }

    public static func shouldRestoreLastSession(
        behavior: LaunchSessionBehavior,
        lastBackgroundedAt: Date?,
        restoreWindowMinutes: Int,
        referenceDate: Date = Date()
    ) -> Bool {
        switch behavior {
        case .newSession:
            return false
        case .alwaysRestore:
            return true
        case .restoreIfRecent:
            guard let lastBackgroundedAt else { return false }
            let restoreWindow = TimeInterval(normalizedRestoreWindowMinutes(restoreWindowMinutes)) * 60
            return referenceDate.timeIntervalSince(lastBackgroundedAt) <= restoreWindow
        }
    }
}

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
        newTemporarySession: ChatSession,
        referenceDate: Date = Date()
    ) -> ChatSession {
        let behavior = storedLaunchSessionBehavior()
        let restoreWindowMinutes = Persistence.readAppConfigInteger(
            key: AppConfigKey.restoreLastSessionWithinMinutes.rawValue
        ) ?? LaunchSessionPolicy.defaultRestoreWindowMinutes
        let lastBackgroundedAt = storedLastBackgroundedAt()
        let shouldRestore = LaunchSessionPolicy.shouldRestoreLastSession(
            behavior: behavior,
            lastBackgroundedAt: lastBackgroundedAt,
            restoreWindowMinutes: restoreWindowMinutes,
            referenceDate: referenceDate
        )
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

    public static func recordAppDidEnterBackground(at date: Date = Date()) {
        AppConfigStore.persistSynchronously(
            .real(date.timeIntervalSince1970),
            for: .lastAppBackgroundedAt,
            quickSync: false
        )
    }

    @discardableResult
    public func openNewSessionIfRestoreWindowExpired(at date: Date = Date()) -> Bool {
        let behavior = Self.storedLaunchSessionBehavior()
        guard behavior == .restoreIfRecent else { return false }

        let restoreWindowMinutes = Persistence.readAppConfigInteger(
            key: AppConfigKey.restoreLastSessionWithinMinutes.rawValue
        ) ?? LaunchSessionPolicy.defaultRestoreWindowMinutes
        let shouldRestore = LaunchSessionPolicy.shouldRestoreLastSession(
            behavior: behavior,
            lastBackgroundedAt: Self.storedLastBackgroundedAt(),
            restoreWindowMinutes: restoreWindowMinutes,
            referenceDate: date
        )
        guard !shouldRestore else { return false }

        createNewSession()
        return true
    }

    private static func storedLaunchSessionBehavior() -> LaunchSessionBehavior {
        LaunchSessionPolicy.behavior(
            restoreLastSession: (Persistence.readAppConfigInteger(
                key: AppConfigKey.restoreLastSessionOnLaunch.rawValue
            ) ?? 0) != 0,
            onlyIfRecent: (Persistence.readAppConfigInteger(
                key: AppConfigKey.restoreLastSessionOnlyIfRecent.rawValue
            ) ?? 0) != 0
        )
    }

    private static func storedLastBackgroundedAt() -> Date? {
        guard let timestamp = Persistence.readAppConfigReal(
            key: AppConfigKey.lastAppBackgroundedAt.rawValue
        ), timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func persistLastActiveSessionIDIfNeeded(_ session: ChatSession?) {
        guard let session, !session.isTemporary else { return }
        let sessionID = session.id.uuidString
        Task.detached(priority: .utility) {
            AppConfigStore.persistSynchronously(.text(sessionID), for: .lastActiveSessionID)
        }
    }
}
