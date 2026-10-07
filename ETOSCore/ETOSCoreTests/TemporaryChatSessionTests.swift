// ============================================================================
// TemporaryChatSessionTests.swift
// ============================================================================

import Testing
import Combine
import Foundation
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

    @Test("临时会话编辑只更新运行期配置，显式保存才持久化标题和消息")
    func editingTemporaryMetadataDoesNotPromoteSession() throws {
        let service = ChatService()
        service.enableTemporaryChat(memoryMode: .isolated)
        var draft = try #require(service.currentSessionSubject.value)
        defer { Persistence.deleteSessionArtifacts(sessionID: draft.id) }
        let messages = [ChatMessage(role: .user, content: "仍在临时模式")]
        service.updateMessages(messages, for: draft.id)
        draft.name = "临时草稿标题"
        draft.systemPrompt = "仅本次会话使用"
        // 即使旧调用方试图提升元数据，也不能绕过核心的临时模式边界。
        draft.isTemporary = false
        service.updateSession(draft)
        #expect(service.currentSessionSubject.value?.isTemporary == true)
        #expect(service.currentSessionSubject.value?.systemPrompt == draft.systemPrompt)
        #expect(service.temporaryChatMemoryMode(for: draft.id) == .isolated)
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        #expect(Persistence.loadChatSessions().contains(where: { $0.id == draft.id }) == false)
        #expect(Persistence.loadMessages(for: draft.id).isEmpty)
        #expect(service.saveCurrentTemporaryChat())
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        #expect(Persistence.loadChatSessions().first(where: { $0.id == draft.id })?.name == draft.name)
        #expect(Persistence.loadMessages(for: draft.id) == messages)
    }

    @Test("明确切换临时记忆模式保留同一会话的运行期消息")
    func explicitMemoryModeChangeKeepsTemporaryHistory() throws {
        let service = ChatService()
        service.enableTemporaryChat(memoryMode: .enabled)
        let session = try #require(service.currentSessionSubject.value)
        defer { Persistence.deleteSessionArtifacts(sessionID: session.id) }
        let messages = [ChatMessage(role: .user, content: "切换模式前的内容")]
        service.updateMessages(messages, for: session.id)
        service.enableTemporaryChat(memoryMode: .isolated)
        #expect(service.currentSessionSubject.value?.id == session.id)
        #expect(service.temporaryChatMemoryMode(for: session.id) == .isolated)
        #expect(service.messagesSnapshot(for: session.id) == messages)
        #expect(Persistence.loadMessages(for: session.id).isEmpty)
    }
}
