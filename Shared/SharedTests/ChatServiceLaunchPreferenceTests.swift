import Testing
import Foundation
import Combine
@testable import Shared

@Suite("聊天服务启动会话偏好测试")
struct ChatServiceLaunchPreferenceTests {
    private let restoreKey = ChatService.restoreLastSessionOnLaunchEnabledStorageKey
    private let lastSessionKey = "launch.lastActiveSessionID"

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

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: restoreKey)
        defaults.set(persisted.id.uuidString, forKey: lastSessionKey)

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

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: restoreKey)
        defaults.set(sessionB.id.uuidString, forKey: lastSessionKey)

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

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: restoreKey)
        defaults.removeObject(forKey: lastSessionKey)

        let service = ChatService()
        service.setCurrentSession(sessionB)

        #expect(defaults.string(forKey: lastSessionKey) == sessionB.id.uuidString)
    }

    private func prepareIsolatedState() -> (snapshot: [SessionSnapshot], restoreDefaults: () -> Void) {
        let snapshot = captureCurrentSessions()
        clearAllSessions()

        let defaults = UserDefaults.standard
        let previousRestoreValue = defaults.object(forKey: restoreKey)
        let previousLastSessionValue = defaults.object(forKey: lastSessionKey)
        let restoreDefaults = {
            if let previousRestoreValue {
                defaults.set(previousRestoreValue, forKey: restoreKey)
            } else {
                defaults.removeObject(forKey: restoreKey)
            }

            if let previousLastSessionValue {
                defaults.set(previousLastSessionValue, forKey: lastSessionKey)
            } else {
                defaults.removeObject(forKey: lastSessionKey)
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
