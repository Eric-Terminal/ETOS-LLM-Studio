import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("后台删除回复版本包含工具结果，前台即使包含相同消息 ID 也保持不变")
    func versionDeletionRetainsTargetAndCleansWholeAttempt() throws {
        let source = chatService.createSavedSession(name: "删除来源")
        let foreground = chatService.createSavedSession(name: "前台副本")
        let firstID = UUID()
        let secondID = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: secondID)
        let first = ChatMessage(role: .assistant, content: "第一版", responseGroupID: user.id, responseAttemptID: firstID, responseAttemptIndex: 0)
        let firstTool = ChatMessage(role: .tool, content: "第一版工具结果", responseGroupID: user.id, responseAttemptID: firstID, responseAttemptIndex: 0)
        let second = ChatMessage(role: .assistant, content: "第二版", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let tool = ChatMessage(role: .tool, content: "第二版工具结果", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let messages = [user, first, firstTool, second, tool]
        chatService.updateMessages(messages, for: source.id)
        chatService.updateMessages(messages, for: foreground.id)
        chatService.setCurrentSession(foreground)
        #expect(chatService.deleteHistoryMessage(second, sessionID: source.id, kind: .currentVersion))
        #expect(chatService.messagesSnapshot(for: source.id).map(\.id) == [user.id, first.id, firstTool.id])
        #expect(chatService.messagesForSessionSubject.value == messages)
        #expect(chatService.deleteHistoryMessage(first, sessionID: source.id, kind: .allVersions))
        let remaining = chatService.messagesSnapshot(for: source.id)
        #expect(remaining.map(\.id) == [user.id])
        #expect(remaining.first?.selectedResponseAttemptID == nil)
        #expect(chatService.messagesForSessionSubject.value == messages)
    }

    @Test("旧正文版本逐个删除，过期消息或已切换的回复尝试不能用于版本删除")
    func staleDeletionAndLegacyVersions() throws {
        let source = chatService.createSavedSession(name: "旧版删除")
        var message = ChatMessage(role: .assistant, content: "旧正文")
        message.addVersion("新正文")
        chatService.updateMessages([message], for: source.id)
        #expect(chatService.deleteHistoryMessage(message, sessionID: source.id, kind: .currentVersion))
        let kept = try #require(chatService.messagesSnapshot(for: source.id).first)
        #expect(kept.content == "旧正文")
        #expect(!chatService.deleteHistoryMessage(message, sessionID: source.id, kind: .allVersions))
        #expect(chatService.messagesSnapshot(for: source.id) == [kept])

        let firstID = UUID()
        let secondID = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: firstID)
        let old = ChatMessage(role: .assistant, content: "旧菜单引用", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let selected = ChatMessage(role: .assistant, content: "现在显示的版本", responseGroupID: user.id, responseAttemptID: firstID, responseAttemptIndex: 0)
        chatService.updateMessages([user, selected, old], for: source.id)
        #expect(!chatService.deleteHistoryMessage(old, sessionID: source.id, kind: .currentVersion))
        #expect(!chatService.deleteHistoryMessage(old, sessionID: source.id, kind: .allVersions))
        #expect(chatService.messagesSnapshot(for: source.id) == [user, selected, old])
    }

    @Test("消息编辑固定来源，即使前台包含相同消息也不能写入另一会话")
    @MainActor
    func editingRejectsAnotherSessionWithIdenticalMessage() async throws {
        let source = chatService.createSavedSession(name: "编辑来源")
        let foreground = chatService.createSavedSession(name: "编辑前台")
        let original = ChatMessage(role: .assistant, content: "相同原文")
        chatService.updateMessages([original], for: source.id)
        chatService.updateMessages([original], for: foreground.id)
        chatService.setCurrentSession(foreground)
        var changed = original
        changed.content = "不应该写入"
        do {
            try await chatService.updateEditedMessage(changed, original: original, targetSessionID: source.id)
            Issue.record("来源变化后编辑应当失败")
        } catch { #expect(error is MessageToolCallEditingError) }
        #expect(chatService.messagesForSessionSubject.value == [original])
        #expect(chatService.messagesSnapshot(for: source.id) == [original])
    }
}
