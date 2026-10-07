import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacMessageVersionPresentationTests {
    @Test("会话提示词存在时，发送与重试仍单独保留全局提示词")
    @MainActor
    func requestConfigurationPreservesGlobalPrompt() {
        let configuration = AppConfigStore.shared
        let previous = configuration.systemPrompt
        defer { configuration.systemPrompt = previous }
        configuration.systemPrompt = "全局提示词"
        let session = ChatSession(id: UUID(), name: "会话", systemPrompt: "会话提示词")
        let snapshot = MacChatRequestConfiguration(configuration, session: session)
        #expect(snapshot.systemPrompt == "全局提示词")
    }

    @Test("回复组增加版本时，未改变正文的用户行也刷新版本选项")
    func versionCountInvalidatesCachedRows() async throws {
        let store = MacMessagePresentationStore()
        let firstID = UUID()
        let secondID = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: firstID)
        let first = ChatMessage(role: .assistant, content: "第一版", responseGroupID: user.id, responseAttemptID: firstID, responseAttemptIndex: 0)
        let original = try await store.prepare([user, first], markdown: false, language: "en")
        #expect(original.first?.versionOptions.isEmpty == true)
        let second = ChatMessage(role: .assistant, content: "第二版", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let updated = try await store.prepare([user, first, second], markdown: false, language: "en")
        #expect(updated.map(\.id) == [user.id, first.id])
        #expect(updated.first?.versionOptions.count == 2)
        #expect(updated.first?.versionIndex == 0)
        let switched = ChatResponseAttemptSupport.selectAttempt(attemptID: secondID, groupID: user.id, in: [user, first, second])
        let selected = try await store.prepare(switched, markdown: false, language: "en")
        #expect(selected.map(\.id) == [user.id, second.id])
        #expect(selected.first?.versionIndex == 1)
    }
}
