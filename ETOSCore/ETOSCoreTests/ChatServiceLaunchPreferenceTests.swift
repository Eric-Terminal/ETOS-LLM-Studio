import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("聊天服务启动会话偏好测试")
struct ChatServiceLaunchPreferenceTests {
    private let restoreKey = AppConfigKey.restoreLastSessionOnLaunch.rawValue
    private let lastSessionKey = AppConfigKey.lastActiveSessionID.rawValue

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
        Persistence.writeAppConfig(key: lastSessionKey, text: sessionB.id.uuidString, typeHint: AppConfigKey.lastActiveSessionID.typeHint)

        let service = ChatService()

        #expect(service.currentSessionSubject.value?.id == sessionB.id)
        #expect(service.currentSessionSubject.value?.isTemporary == false)
        #expect(service.messagesForSessionSubject.value == expectedMessages)
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
        Persistence.deleteAppConfig(key: lastSessionKey)

        let service = ChatService()
        service.setCurrentSession(sessionB)

        #expect(Persistence.readAppConfigText(key: lastSessionKey) == sessionB.id.uuidString)
    }

    private func prepareIsolatedState() -> (snapshot: [SessionSnapshot], restoreDefaults: () -> Void) {
        let snapshot = captureCurrentSessions()
        clearAllSessions()

        let previousRestoreValue = Persistence.readAppConfigInteger(key: restoreKey)
        let previousLastSessionValue = Persistence.readAppConfigText(key: lastSessionKey)
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

            if let previousLastSessionValue {
                Persistence.writeAppConfig(
                    key: lastSessionKey,
                    text: previousLastSessionValue,
                    typeHint: AppConfigKey.lastActiveSessionID.typeHint
                )
            } else {
                Persistence.deleteAppConfig(key: lastSessionKey)
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
