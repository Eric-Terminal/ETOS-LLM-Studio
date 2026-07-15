import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("聊天服务启动会话偏好测试")
struct ChatServiceLaunchPreferenceTests {
    private let restoreKey = AppConfigKey.restoreLastSessionOnLaunch.rawValue
    private let recentOnlyKey = AppConfigKey.restoreLastSessionOnlyIfRecent.rawValue
    private let restoreWindowKey = AppConfigKey.restoreLastSessionWithinMinutes.rawValue
    private let lastSessionKey = AppConfigKey.lastActiveSessionID.rawValue
    private let lastBackgroundedAtKey = AppConfigKey.lastAppBackgroundedAt.rawValue

    @MainActor
    @Test("默认关闭时启动仍进入新对话")
    func launchUsesNewTemporarySessionByDefault() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let persisted = ChatSession(id: UUID(), name: "历史会话", isTemporary: false)
        Persistence.saveChatSessions([persisted])
        Persistence.saveMessages([ChatMessage(role: .user, content: "历史消息")], for: persisted.id)

        Persistence.writeAppConfig(key: restoreKey, integer: 0, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 0, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.writeAppConfig(key: lastSessionKey, text: persisted.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)

        let service = ChatService()

        #expect(service.currentSessionSubject.value?.isTemporary == true)
        #expect(service.messagesForSessionSubject.value.isEmpty == true)
    }

    @MainActor
    @Test("开启后启动恢复退出前会话")
    func launchRestoresLastActiveSessionWhenEnabled() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let sessionA = ChatSession(id: UUID(), name: "会话A", isTemporary: false)
        let sessionB = ChatSession(id: UUID(), name: "会话B", isTemporary: false)
        Persistence.saveChatSessions([sessionA, sessionB])
        let expectedMessages = [ChatMessage(role: .assistant, content: "恢复成功")]
        Persistence.saveMessages(expectedMessages, for: sessionB.id)

        Persistence.writeAppConfig(key: restoreKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 0, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.writeAppConfig(key: lastSessionKey, text: sessionB.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)

        let service = ChatService()

        #expect(service.currentSessionSubject.value?.id == sessionB.id)
        #expect(service.currentSessionSubject.value?.isTemporary == false)
        #expect(service.messagesForSessionSubject.value == expectedMessages)
    }

    @MainActor
    @Test("短时间内重新启动会恢复上次会话")
    func launchRestoresRecentSessionWithinWindow() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let session = ChatSession(id: UUID(), name: "最近会话", isTemporary: false)
        Persistence.saveChatSessions([session])
        Persistence.writeAppConfig(key: restoreKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.writeAppConfig(key: restoreWindowKey, integer: 15, typeHint: AppConfigKey.restoreLastSessionWithinMinutes.typeHint)
        Persistence.writeAppConfig(key: lastSessionKey, text: session.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)
        Persistence.writeAppConfig(
            key: lastBackgroundedAtKey,
            real: Date().addingTimeInterval(-5 * 60).timeIntervalSince1970,
            typeHint: AppConfigKey.lastAppBackgroundedAt.typeHint
        )

        let service = ChatService()

        #expect(service.currentSessionSubject.value?.id == session.id)
    }

    @MainActor
    @Test("离开超过恢复期限后启动新对话")
    func launchUsesNewSessionAfterRestoreWindowExpires() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let session = ChatSession(id: UUID(), name: "过期会话", isTemporary: false)
        Persistence.saveChatSessions([session])
        Persistence.writeAppConfig(key: restoreKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.writeAppConfig(key: restoreWindowKey, integer: 15, typeHint: AppConfigKey.restoreLastSessionWithinMinutes.typeHint)
        Persistence.writeAppConfig(key: lastSessionKey, text: session.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)
        Persistence.writeAppConfig(
            key: lastBackgroundedAtKey,
            real: Date().addingTimeInterval(-16 * 60).timeIntervalSince1970,
            typeHint: AppConfigKey.lastAppBackgroundedAt.typeHint
        )

        let service = ChatService()

        #expect(service.currentSessionSubject.value?.isTemporary == true)
    }

    @MainActor
    @Test("应用在后台超过期限后回到前台会切换到新对话")
    func foregroundUsesNewSessionAfterRestoreWindowExpires() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let session = ChatSession(id: UUID(), name: "前台恢复会话", isTemporary: false)
        Persistence.saveChatSessions([session])
        Persistence.writeAppConfig(key: restoreKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 1, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.writeAppConfig(key: restoreWindowKey, integer: 15, typeHint: AppConfigKey.restoreLastSessionWithinMinutes.typeHint)
        Persistence.writeAppConfig(key: lastSessionKey, text: session.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)
        Persistence.writeAppConfig(
            key: lastBackgroundedAtKey,
            real: Date().addingTimeInterval(-5 * 60).timeIntervalSince1970,
            typeHint: AppConfigKey.lastAppBackgroundedAt.typeHint
        )
        let service = ChatService()
        Persistence.writeAppConfig(
            key: lastBackgroundedAtKey,
            real: Date().addingTimeInterval(-16 * 60).timeIntervalSince1970,
            typeHint: AppConfigKey.lastAppBackgroundedAt.typeHint
        )

        let didOpenNewSession = service.openNewSessionIfRestoreWindowExpired()

        #expect(didOpenNewSession)
        #expect(service.currentSessionSubject.value?.isTemporary == true)
    }

    @Test("恢复期限输入会归一化为正整数")
    func restoreWindowDraftIsNormalized() {
        #expect(LaunchSessionPolicy.resolvedRestoreWindowMinutes(from: "30", fallback: 15) == 30)
        #expect(LaunchSessionPolicy.resolvedRestoreWindowMinutes(from: "0", fallback: 15) == 1)
        #expect(LaunchSessionPolicy.resolvedRestoreWindowMinutes(from: "20000", fallback: 15) == 20_000)
        #expect(LaunchSessionPolicy.resolvedRestoreWindowMinutes(from: "abc", fallback: 15) == 15)
    }

    @MainActor
    @Test("切换到历史会话时会记住最后活跃会话ID")
    func switchingSessionPersistsLastActiveSessionID() {
        let (snapshot, restoreDefaults) = prepareIsolatedState()
        defer {
            restoreDefaults()
            restoreSessions(snapshot)
        }

        let sessionA = ChatSession(id: UUID(), name: "会话A", isTemporary: false)
        let sessionB = ChatSession(id: UUID(), name: "会话B", isTemporary: false)
        Persistence.saveChatSessions([sessionA, sessionB])

        Persistence.writeAppConfig(key: restoreKey, integer: 0, typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint)
        Persistence.writeAppConfig(key: recentOnlyKey, integer: 0, typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint)
        Persistence.deleteAppConfig(key: lastSessionKey)

        let service = ChatService()
        service.setCurrentSession(sessionB)

        #expect(Persistence.readAppConfigText(key: lastSessionKey) == sessionB.id.uuidString)
    }

    private func prepareIsolatedState() -> (snapshot: [SessionSnapshot], restoreDefaults: () -> Void) {
        let snapshot = captureCurrentSessions()
        clearAllSessions()

        let previousRestoreValue = Persistence.readAppConfigInteger(key: restoreKey)
        let previousRecentOnlyValue = Persistence.readAppConfigInteger(key: recentOnlyKey)
        let previousRestoreWindowValue = Persistence.readAppConfigInteger(key: restoreWindowKey)
        let previousLastSessionValue = Persistence.readAppConfigText(key: lastSessionKey)
        let previousLastBackgroundedAtValue = Persistence.readAppConfigReal(key: lastBackgroundedAtKey)
        let restoreDefaults = {
            if let previousRestoreValue {
                Persistence.writeAppConfig(
                    key: restoreKey,
                    integer: previousRestoreValue,
                    typeHint: AppConfigKey.restoreLastSessionOnLaunch.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: restoreKey)
            }

            if let previousRecentOnlyValue {
                Persistence.writeAppConfig(
                    key: recentOnlyKey,
                    integer: previousRecentOnlyValue,
                    typeHint: AppConfigKey.restoreLastSessionOnlyIfRecent.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: recentOnlyKey)
            }

            if let previousRestoreWindowValue {
                Persistence.writeAppConfig(
                    key: restoreWindowKey,
                    integer: previousRestoreWindowValue,
                    typeHint: AppConfigKey.restoreLastSessionWithinMinutes.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: restoreWindowKey)
            }

            if let previousLastSessionValue {
                Persistence.writeAppConfig(
                    key: lastSessionKey,
                    text: previousLastSessionValue,
                    typeHint: AppConfigKey.lastActiveSessionID.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: lastSessionKey)
            }

            if let previousLastBackgroundedAtValue {
                Persistence.writeAppConfig(
                    key: lastBackgroundedAtKey,
                    real: previousLastBackgroundedAtValue,
                    typeHint: AppConfigKey.lastAppBackgroundedAt.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: lastBackgroundedAtKey)
            }
        }
        return (snapshot, restoreDefaults)
    }

    private struct SessionSnapshot {
        let session: ChatSession
        let messages: [ChatMessage]
    }

    private func captureCurrentSessions() -> [SessionSnapshot] {
        Persistence.loadChatSessions().map { session in
            SessionSnapshot(session: session, messages: Persistence.loadMessages(for: session.id))
        }
    }

    private func clearAllSessions() {
        let existing = Persistence.loadChatSessions()
        Persistence.saveChatSessions([])
        for session in existing {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
    }

    private func restoreSessions(_ snapshots: [SessionSnapshot]) {
        clearAllSessions()
        for snapshot in snapshots {
            Persistence.deleteSessionArtifacts(sessionID: snapshot.session.id)
        }
        let sessions = snapshots.map(\.session)
        Persistence.saveChatSessions(sessions)
        for snapshot in snapshots {
            Persistence.saveMessages(snapshot.messages, for: snapshot.session.id)
        }
    }
}
