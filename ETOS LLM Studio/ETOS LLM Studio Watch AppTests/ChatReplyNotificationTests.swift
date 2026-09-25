import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 回复通知快照", .serialized)
struct ChatReplyNotificationTests {
    @Test("界面消息滞后时仍以请求事件保存通知基线，并可在后台识别新回复")
    func notificationUsesEventMessagesInsteadOfRenderingCache() async throws {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        let sessionID = UUID()
        let previous = ChatMessage(role: .assistant, content: "上一轮回复")
        let reply = ChatMessage(role: .assistant, content: "新的\n完整回复")
        viewModel.allMessagesForSession = []
        viewModel.prepareBackgroundReplyNotificationContext(for: sessionID, messages: [previous])
        let context = try #require(viewModel.pendingReplyNotificationContextBySessionID[sessionID])
        #expect(context.baselineMessages == [previous])
        let messages = [previous, reply]
        let marker = await Task.detached {
            ChatViewModel.latestAssistantReplyMarker(from: messages)
        }.value
        #expect(marker?.id == reply.id)
        #expect(marker?.normalizedContent == "新的 完整回复")
        #expect(viewModel.allMessagesForSession.isEmpty)
        viewModel.pendingReplyNotificationContextBySessionID.removeAll()
    }

    @Test("仅附件的回复仍可识别且空占位不会覆盖上一条通知标记")
    func identifiesAttachmentReplyAndIgnoresEmptyPlaceholder() {
        let attachment = ChatMessage(role: .assistant, content: "", imageFileNames: ["reply.png"])
        let placeholder = ChatMessage(role: .assistant, content: "")
        let marker = ChatViewModel.latestAssistantReplyMarker(from: [attachment, placeholder])
        #expect(marker?.id == attachment.id)
        #expect(marker?.imageCount == 1)
    }
}
