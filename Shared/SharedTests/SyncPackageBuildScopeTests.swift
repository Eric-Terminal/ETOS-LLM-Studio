// ============================================================================
// SyncPackageBuildScopeTests.swift
// ============================================================================
// SyncPackageBuildScopeTests 测试文件
// - 覆盖按会话范围导出同步包的行为
// - 防止“单独发送会话”误带出无关会话
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("同步打包范围测试")
struct SyncPackageBuildScopeTests {

    @Test("指定会话 ID 时只导出目标会话")
    func testBuildPackageWithSessionFilterExportsOnlyTargetSession() {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let targetSession = ChatSession(id: UUID(), name: "目标会话", isTemporary: false)
        let otherSession = ChatSession(id: UUID(), name: "其他会话", isTemporary: false)
        let temporarySession = ChatSession(id: UUID(), name: "临时会话", isTemporary: true)

        let targetMessage = ChatMessage(role: .user, content: "目标消息")
        let otherMessage = ChatMessage(role: .assistant, content: "其他消息")

        Persistence.saveChatSessions([targetSession, otherSession, temporarySession])
        Persistence.saveMessages([targetMessage], for: targetSession.id)
        Persistence.saveMessages([otherMessage], for: otherSession.id)
        Persistence.saveMessages([ChatMessage(role: .user, content: "临时消息")], for: temporarySession.id)
        chatService.chatSessionsSubject.send([targetSession, otherSession, temporarySession])

        let package = SyncEngine.buildPackage(
            options: [.sessions],
            chatService: chatService,
            sessionIDs: Set([targetSession.id])
        )

        #expect(package.sessions.count == 1)
        #expect(package.sessions.first?.session.id == targetSession.id)
        #expect(package.sessions.first?.messages == [targetMessage])
    }

    @Test("未指定会话 ID 时保持原有行为（导出全部非临时会话）")
    func testBuildPackageWithoutSessionFilterExportsAllNonTemporarySessions() {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let firstSession = ChatSession(id: UUID(), name: "会话一", isTemporary: false)
        let secondSession = ChatSession(id: UUID(), name: "会话二", isTemporary: false)
        let temporarySession = ChatSession(id: UUID(), name: "临时会话", isTemporary: true)

        Persistence.saveChatSessions([firstSession, secondSession, temporarySession])
        Persistence.saveMessages([ChatMessage(role: .user, content: "A")], for: firstSession.id)
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "B")], for: secondSession.id)
        Persistence.saveMessages([ChatMessage(role: .user, content: "T")], for: temporarySession.id)
        chatService.chatSessionsSubject.send([firstSession, secondSession, temporarySession])

        let package = SyncEngine.buildPackage(options: [.sessions], chatService: chatService)
        let exportedIDs = Set(package.sessions.map(\.session.id))

        #expect(package.sessions.count == 2)
        #expect(exportedIDs == Set([firstSession.id, secondSession.id]))
    }

    private func resetSessions(to snapshots: [SyncedSession]) {
        let existing = Persistence.loadChatSessions()
        Persistence.saveChatSessions([])
        for session in existing {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
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

