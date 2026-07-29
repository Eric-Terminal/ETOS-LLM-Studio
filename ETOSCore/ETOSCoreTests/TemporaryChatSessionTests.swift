// ============================================================================
// TemporaryChatSessionTests.swift
// ============================================================================

import Testing
import Combine
@testable import ETOSCore

@Suite("临时对话会话测试", .serialized)
struct TemporaryChatSessionTests {
    @Test("对话开始后只能关闭已开启的临时对话")
    func toggleAvailabilityRespectsConversationState() {
        #expect(TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: false,
            hasConversationStarted: false
        ))
        #expect(!TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: false,
            hasConversationStarted: true
        ))
        #expect(TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: true,
            hasConversationStarted: true
        ))
    }

    @Test("临时对话关闭前只保留内存快照，关闭后完整落盘")
    func temporaryMessagesPersistOnlyAfterSavingSession() throws {
        let service = ChatService()
        service.enableTemporaryChat()
        let session = try #require(service.currentSessionSubject.value)
        defer {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        let messages = [ChatMessage(role: .user, content: "只存在于内存")]
        service.persistAndPublishMessages(messages, for: session.id)

        #expect(service.isTemporaryChatEnabled(for: session.id))
        #expect(service.messagesForSessionActivation(session.id) == messages)
        #expect(Persistence.loadMessages(for: session.id).isEmpty)

        #expect(service.saveCurrentTemporaryChat())
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        #expect(!service.isTemporaryChatEnabled(for: session.id))
        #expect(Persistence.loadMessages(for: session.id) == messages)
    }

    @Test("两秒内再次轻点切换记忆模式，下一次轻点关闭")
    func rapidTapSwitchesMemoryModeBeforeClosing() throws {
        let service = ChatService()
        let enabledAt = Date(timeIntervalSince1970: 1_000)

        let enabled = service.performTemporaryChatTap(
            preferredMemoryMode: .enabled,
            canEnable: true,
            now: enabledAt
        )
        let session = try #require(service.currentSessionSubject.value)
        defer {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        #expect(enabled == .enabled(.enabled))
        #expect(service.temporaryChatMemoryMode(for: session.id) == .enabled)

        let switched = service.performTemporaryChatTap(
            preferredMemoryMode: .enabled,
            canEnable: true,
            now: enabledAt.addingTimeInterval(1)
        )

        #expect(switched == .memoryModeChanged(.isolated))
        #expect(service.temporaryChatMemoryMode(for: session.id) == .isolated)

        let disabled = service.performTemporaryChatTap(
            preferredMemoryMode: .enabled,
            canEnable: true,
            now: enabledAt.addingTimeInterval(1.5)
        )

        #expect(disabled == .disabled)
        #expect(!service.isTemporaryChatEnabled(for: session.id))
    }

    @Test("超过两秒再次轻点直接关闭临时对话")
    func delayedTapClosesTemporaryChat() throws {
        let service = ChatService()
        let enabledAt = Date(timeIntervalSince1970: 2_000)

        let enabled = service.performTemporaryChatTap(
            preferredMemoryMode: .isolated,
            canEnable: true,
            now: enabledAt
        )
        let session = try #require(service.currentSessionSubject.value)
        defer {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        #expect(enabled == .enabled(.isolated))

        let disabled = service.performTemporaryChatTap(
            preferredMemoryMode: .isolated,
            canEnable: true,
            now: enabledAt.addingTimeInterval(2.01)
        )

        #expect(disabled == .disabled)
        #expect(!service.isTemporaryChatEnabled(for: session.id))
    }

    @Test("记忆隔离偏好可在两秒内切换回允许记忆")
    func rapidTapRestoresMemoryEnabledMode() throws {
        let service = ChatService()
        let enabledAt = Date(timeIntervalSince1970: 3_000)

        _ = service.performTemporaryChatTap(
            preferredMemoryMode: .isolated,
            canEnable: true,
            now: enabledAt
        )
        let session = try #require(service.currentSessionSubject.value)
        defer {
            _ = service.saveCurrentTemporaryChat()
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        let switched = service.performTemporaryChatTap(
            preferredMemoryMode: .isolated,
            canEnable: true,
            now: enabledAt.addingTimeInterval(1)
        )

        #expect(switched == .memoryModeChanged(.enabled))
        #expect(service.temporaryChatMemoryMode(for: session.id) == .enabled)
    }

    @Test("临时对话记忆隔离不影响其他工具")
    func memoryIsolationKeepsNonMemoryToolsAvailable() throws {
        let service = ChatService()
        service.enableTemporaryChat(memoryMode: .isolated)
        let session = try #require(service.currentSessionSubject.value)
        defer {
            _ = service.saveCurrentTemporaryChat()
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }

        let policy = service.auxiliaryContextPolicy(
            for: session,
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true
        )

        #expect(!policy.enableMemory)
        #expect(!policy.enableMemoryWrite)
        #expect(!policy.enableMemoryActiveRetrieval)
        #expect(policy.includeBuiltInAppTools)
        #expect(policy.includeMCPTools)
        #expect(policy.includeShortcutTools)
        #expect(policy.includeSkills)
    }

    @Test("临时对话默认允许记忆")
    func temporaryChatMemoryPreferenceDefaultsToEnabled() {
        #expect(AppConfigKey.temporaryChatMemoryEnabled.defaultValue == .bool(true))
    }
}
