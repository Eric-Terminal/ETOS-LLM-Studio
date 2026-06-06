// ============================================================================
// ChatSessionManagementTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的会话与文件夹管理测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import Shared

extension ChatServiceTests {
    @Test("Create New Session")
    func testCreateNewSession() {
        let initialCurrentSession = chatService.currentSessionSubject.value

        chatService.messagesForSessionSubject.send([ChatMessage(role: .user, content: "dummy message")])
        #expect(chatService.messagesForSessionSubject.value.isEmpty == false)

        chatService.createNewSession()

        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newMessages = chatService.messagesForSessionSubject.value

        #expect(newSessions.count == 1)
        #expect(newSessions.filter(\.isTemporary).count == 1)
        #expect(newSessions.first?.id == newCurrentSession?.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.id == initialCurrentSession?.id)
        #expect(newMessages.isEmpty == true)
    }

    @Test("Create New Session when no temporary session exists")
    func testCreateNewSessionWhenNoTemporarySessionExists() {
        guard var onlySession = chatService.chatSessionsSubject.value.first else {
            Issue.record("缺少初始会话")
            return
        }
        onlySession.isTemporary = false
        chatService.chatSessionsSubject.send([onlySession])
        chatService.setCurrentSession(onlySession)
        Persistence.saveChatSessions([onlySession])

        chatService.createNewSession()

        let sessions = chatService.chatSessionsSubject.value
        let temporarySessions = sessions.filter(\.isTemporary)
        #expect(sessions.count == 2)
        #expect(temporarySessions.count == 1)
        #expect(sessions.first?.isTemporary == true)
        #expect(chatService.currentSessionSubject.value?.id == sessions.first?.id)
    }

    @Test("Switch Session")
    func testSwitchSession() {
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        Persistence.saveChatSessions([session1])
        chatService.createNewSession()

        let messageForSession1 = ChatMessage(role: .user, content: "This is a test for session 1")
        Persistence.saveMessages([messageForSession1], for: session1.id)

        chatService.setCurrentSession(session1)

        let currentSession = chatService.currentSessionSubject.value
        let currentMessages = chatService.messagesForSessionSubject.value

        #expect(currentSession?.id == session1.id)
        #expect(currentMessages.count == 1)
        #expect(currentMessages.first?.content == messageForSession1.content)
    }

    @Test("Delete Session")
    func testDeleteSession() {
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        Persistence.saveChatSessions([session1])
        chatService.createNewSession()
        let session2 = chatService.currentSessionSubject.value!
        let initialCount = chatService.chatSessionsSubject.value.count
        #expect(initialCount == 2)

        chatService.deleteSessions([session2])

        let finalSessions = chatService.chatSessionsSubject.value
        let finalCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == initialCount - 1)
        #expect(finalSessions.contains(where: { $0.id == session2.id }) == false)
        #expect(finalCurrentSession?.id == session1.id)
    }

    @Test("删除会话不会移除其他会话仍在引用的附件实体文件")
    func testDeleteSessionKeepsFileAttachmentReferencedByOtherSession() async {
        let fileName = "shared-delete-check-\(UUID().uuidString).txt"
        defer { Persistence.deleteFile(fileName: fileName) }

        _ = Persistence.saveFile(Data("共享附件".utf8), fileName: fileName)
        let session1 = chatService.createSavedSession(name: "引用会话一")
        let session2 = chatService.createSavedSession(name: "引用会话二")
        Persistence.saveMessages([
            ChatMessage(role: .user, content: "[文件]", fileFileNames: [fileName])
        ], for: session1.id)
        Persistence.saveMessages([
            ChatMessage(role: .user, content: "[文件]", fileFileNames: [fileName])
        ], for: session2.id)

        chatService.deleteSessions([session1])

        #expect(Persistence.fileExists(fileName: fileName))

        chatService.deleteSessions([session2])

        #expect(await waitUntilFileAttachmentIsDeleted(fileName))
    }

    @Test("Delete last session creates a new temporary one")
    func testDeleteLastSession_CreatesNewTemporarySession() {
        let initialSessions = chatService.chatSessionsSubject.value
        #expect(initialSessions.count == 1)
        let lastSession = initialSessions.first!

        chatService.deleteSessions([lastSession])

        let finalSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == 1)
        #expect(newCurrentSession?.id != lastSession.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.name == "新的对话")
    }

    @Test("Branch Session With Message Copy")
    func testBranchSession() {
        let sourceSession = chatService.currentSessionSubject.value!
        let message = ChatMessage(role: .user, content: "message to be copied")
        Persistence.saveMessages([message], for: sourceSession.id)
        let initialCount = chatService.chatSessionsSubject.value.count

        chatService.branchSession(from: sourceSession, copyMessages: true)

        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newSessionMessages = chatService.messagesForSessionSubject.value

        #expect(newSessions.count == initialCount + 1)
        #expect(newCurrentSession?.id != sourceSession.id)
        #expect(newCurrentSession?.name.contains("分支:") == true)
        #expect(newSessionMessages.count == 1)
        #expect(newSessionMessages.first?.content == message.content)
    }

    @Test("复制历史创建分支会复用文件附件引用")
    func testBranchSessionReusesFileAttachmentReference() async {
        let fileName = "branch-shared-\(UUID().uuidString).txt"
        defer { Persistence.deleteFile(fileName: fileName) }

        _ = Persistence.saveFile(Data("分支共享附件".utf8), fileName: fileName)
        let sourceSession = chatService.currentSessionSubject.value!
        let message = ChatMessage(role: .user, content: "[文件]", fileFileNames: [fileName])
        Persistence.saveMessages([message], for: sourceSession.id)

        let branch = chatService.branchSession(from: sourceSession, copyMessages: true)
        let branchFileName = Persistence.loadMessages(for: branch.id).first?.fileFileNames?.first

        #expect(branchFileName == fileName)
        #expect(Persistence.getAllFileNames().filter { $0 == fileName }.count == 1)

        chatService.deleteSessions([sourceSession])
        #expect(Persistence.fileExists(fileName: fileName))

        chatService.deleteSessions([branch])
        #expect(await waitUntilFileAttachmentIsDeleted(fileName))
    }

    private func waitUntilFileAttachmentIsDeleted(_ fileName: String) async -> Bool {
        for _ in 0..<20 {
            if !Persistence.fileExists(fileName: fileName) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !Persistence.fileExists(fileName: fileName)
    }

    @Test("删除文件夹时会递归删除子文件夹并将会话回到未分类")
    func testDeleteFolderRecursivelyReassignsSessionsToUncategorized() {
        guard let rootFolder = chatService.createSessionFolder(name: "项目", parentID: nil) else {
            Issue.record("创建根文件夹失败")
            return
        }
        guard let childFolder = chatService.createSessionFolder(name: "子目录", parentID: rootFolder.id) else {
            Issue.record("创建子文件夹失败")
            return
        }

        let savedSession = chatService.createSavedSession(
            name: "分类会话",
            initialMessages: [],
            folderID: childFolder.id
        )
        #expect(savedSession.folderID == childFolder.id)
        #expect(chatService.sessionFoldersSubject.value.count == 2)

        chatService.deleteSessionFolder(folderID: rootFolder.id)

        let folders = chatService.sessionFoldersSubject.value
        #expect(folders.isEmpty)

        let updatedSession = chatService.chatSessionsSubject.value.first(where: { $0.id == savedSession.id })
        #expect(updatedSession != nil)
        #expect(updatedSession?.folderID == nil)
    }

    @Test("移动文件夹时会更新父文件夹")
    func testMoveSessionFolderUpdatesParentFolder() {
        guard let firstRoot = chatService.createSessionFolder(name: "项目一", parentID: nil),
              let secondRoot = chatService.createSessionFolder(name: "项目二", parentID: nil),
              let childFolder = chatService.createSessionFolder(name: "子目录", parentID: firstRoot.id) else {
            Issue.record("创建测试文件夹失败")
            return
        }

        chatService.moveSessionFolder(folderID: childFolder.id, toParentID: secondRoot.id)

        let movedFolder = chatService.sessionFoldersSubject.value.first(where: { $0.id == childFolder.id })
        #expect(movedFolder?.parentID == secondRoot.id)
    }

    @Test("移动文件夹时会拒绝移动到自身或子目录")
    func testMoveSessionFolderRejectsSelfAndDescendantTargets() {
        guard let rootFolder = chatService.createSessionFolder(name: "项目", parentID: nil),
              let childFolder = chatService.createSessionFolder(name: "子目录", parentID: rootFolder.id) else {
            Issue.record("创建测试文件夹失败")
            return
        }

        chatService.moveSessionFolder(folderID: rootFolder.id, toParentID: rootFolder.id)
        chatService.moveSessionFolder(folderID: rootFolder.id, toParentID: childFolder.id)

        let rootAfterMove = chatService.sessionFoldersSubject.value.first(where: { $0.id == rootFolder.id })
        #expect(rootAfterMove?.parentID == nil)
    }
}
