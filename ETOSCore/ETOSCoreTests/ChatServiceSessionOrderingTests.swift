import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @MainActor
    @Test("后台目标收到文本后提升内存与持久化排序，不切换正在浏览的会话")
    func sendingPromotesExistingSessionWithoutChangingSelection() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "排序测试回复")
        let target = chatService.createSavedSession(name: "文本排序目标")
        let browsing = chatService.createSavedSession(name: "正在浏览")
        defer { chatService.deleteSessions([target, browsing]) }
        try #require(chatService.chatSessionsSubject.value.first?.id == browsing.id)
        var prepared: ChatSendPresentation?

        await chatService.sendAndProcessMessage(
            content: "发送到已有会话",
            aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5,
            enableStreaming: false, enhancedPrompt: nil,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false,
            targetSessionID: target.id,
            onMessagesPrepared: { prepared = $0 }
        )

        #expect(prepared?.sessionID == target.id)
        #expect(prepared?.messageIDsBySource[.text] == prepared?.responseGroupID)
        #expect(chatService.currentSessionSubject.value?.id == browsing.id)
        #expect(chatService.chatSessionsSubject.value.first?.id == target.id)
        #expect(Persistence.loadChatSessions().first?.id == target.id)
        #expect(Persistence.loadMessages(for: browsing.id).isEmpty)
        #expect(Persistence.loadMessages(for: target.id).contains { $0.content == "排序测试回复" })
    }
}
