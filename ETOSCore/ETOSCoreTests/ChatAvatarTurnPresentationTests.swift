import Foundation
import Testing
@testable import ETOSCore

struct ChatAvatarTurnPresentationTests {
    @Test("多轮工具调用只在整轮顶部显示头像，工具结果与续写共享助手留白")
    func toolRound() {
        let group = UUID(), attempt = UUID()
        let messages = [MessageRole.assistant, .tool, .assistant, .tool, .system, .assistant].map {
            ChatMessage(role: $0, content: "", responseGroupID: group, responseAttemptID: attempt)
        }
        let rows = presentations(messages)
        #expect(rows.map(\.showsAvatar) == [true, false, false, false, false, false])
        #expect(rows.allSatisfy { $0.role == .assistant })
        var configuration = ChatAvatarConfiguration()
        configuration.showAssistant = true
        #expect(rows.allSatisfy { configuration.isVisible(role: $0.role) })
        configuration.showAssistant = false
        configuration.showUser = true
        #expect(rows.allSatisfy { !configuration.isVisible(role: $0.role) })
    }

    @Test("流式追加工具与续写不会把已有头像移动到最后一条消息")
    func streamingAppend() {
        let group = UUID(), attempt = UUID()
        let messages = [MessageRole.assistant, .tool, .assistant, .tool, .assistant].map {
            ChatMessage(role: $0, content: "", responseGroupID: group, responseAttemptID: attempt)
        }
        for count in 1...messages.count {
            let visible = Array(messages.prefix(count))
            let avatarIDs = zip(visible, presentations(visible)).filter { $0.1.showsAvatar }.map { $0.0.id }
            #expect(avatarIDs == [messages[0].id])
        }
    }

    @Test("新用户消息、不同回复组和不同重试版本都重新显示头像")
    func turnBoundaries() {
        let group = UUID(), firstAttempt = UUID(), secondAttempt = UUID()
        let first = ChatMessage(role: .assistant, content: "", responseGroupID: group, responseAttemptID: firstAttempt)
        let otherAttempt = ChatMessage(role: .assistant, content: "", responseGroupID: group, responseAttemptID: secondAttempt)
        let otherGroup = ChatMessage(role: .assistant, content: "", responseGroupID: UUID(), responseAttemptID: secondAttempt)
        let user = ChatMessage(role: .user, content: "新的问题")
        #expect(presentations([first, otherAttempt, otherGroup, user, first]).allSatisfy { $0.showsAvatar })
    }

    @Test("旧历史沿用连续回复分组，孤立工具、系统与错误消息不添加头像")
    func legacyAndStandaloneMessages() {
        let first = ChatMessage(role: .assistant, content: "调用工具")
        let tool = ChatMessage(role: .tool, content: "工具结果")
        let last = ChatMessage(role: .assistant, content: "回答")
        #expect(presentations([first, tool, last]).map(\.showsAvatar) == [true, false, false])
        for role in [MessageRole.tool, .system, .error] {
            let row = presentations([ChatMessage(role: role, content: "")])[0]
            #expect(!row.showsAvatar)
            #expect(row.role == role)
        }
        // 分页或仅导出后半轮时，首条可见工具消息承担这一组的标题。
        #expect(presentations([tool, last]).map(\.showsAvatar) == [true, false])
    }

    @Test("切换重试版本后，只在选中版本的首条回复显示头像")
    func selectedAttempt() {
        let firstID = UUID(), secondID = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: firstID)
        let first = ChatMessage(role: .assistant, content: "初次调用", responseGroupID: user.id, responseAttemptID: firstID)
        let firstResult = ChatMessage(role: .assistant, content: "初次结果", responseGroupID: user.id, responseAttemptID: firstID)
        let second = ChatMessage(role: .assistant, content: "再次调用", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let secondResult = ChatMessage(role: .assistant, content: "再次结果", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let messages = [user, first, firstResult, second, secondResult]
        for (attempt, head) in [(firstID, first.id), (secondID, second.id)] {
            let selected = ChatResponseAttemptSupport.selectAttempt(attemptID: attempt, groupID: user.id, in: messages)
            let visible = ChatResponseAttemptSupport.visibleMessages(from: selected)
            let headers = zip(visible, presentations(visible)).filter { $0.1.showsAvatar }.map { $0.0.id }
            #expect(headers == [user.id, head])
        }
    }

    private func presentations(_ messages: [ChatMessage]) -> [ChatAvatarTurnPresentation] {
        messages.enumerated().map { index, message in
            ChatAvatarTurnPresentation(
                role: message.role,
                mergesWithPrevious: index > 0 && ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(messages[index - 1], message),
                mergesWithNext: index + 1 < messages.count && ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, messages[index + 1])
            )
        }
    }
}
