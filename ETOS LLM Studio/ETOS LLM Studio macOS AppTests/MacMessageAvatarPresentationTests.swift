import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacMessageAvatarPresentationTests {
    @Test("工具续写沿用同一头像，删除轮首后正文缓存命中的消息成为新轮首")
    func cachedRowsRefreshTurnPosition() async throws {
        let store = MacMessagePresentationStore()
        let attempt = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: attempt)
        let first = ChatMessage(role: .assistant, content: "准备调用", responseGroupID: user.id, responseAttemptID: attempt)
        let tool = ChatMessage(role: .tool, content: "结果", responseGroupID: user.id, responseAttemptID: attempt)
        let last = ChatMessage(role: .assistant, content: "最终回答", responseGroupID: user.id, responseAttemptID: attempt)
        let original = try await store.prepare([user, first, tool, last], markdown: false, language: "en")
        #expect(original.map { $0.avatarPresentation.showsAvatar } == [true, true, false, false])
        #expect(original[2].avatarPresentation.role == .assistant)

        let reduced = try await store.prepare([user, last], markdown: false, language: "en")
        #expect(reduced[1].avatarPresentation.showsAvatar)
        #expect(reduced[1].content.id == original[3].content.id)

        let restored = try await store.prepare([user, first, tool, last], markdown: false, language: "en")
        #expect(!restored[3].avatarPresentation.showsAvatar)
        #expect(restored[3].content.id == reduced[1].content.id)
    }

    @Test("孤立工具行追加助手续写后，缓存保留正文并建立整轮标题")
    func cachedToolBecomesTurnHead() async throws {
        let store = MacMessagePresentationStore()
        let group = UUID(), attempt = UUID()
        let tool = ChatMessage(role: .tool, content: "导入的工具结果", responseGroupID: group, responseAttemptID: attempt)
        let last = ChatMessage(role: .assistant, content: "回答", responseGroupID: group, responseAttemptID: attempt)
        let original = try await store.prepare([tool], markdown: false, language: "en")
        #expect(!original[0].avatarPresentation.showsAvatar)
        let updated = try await store.prepare([tool, last], markdown: false, language: "en")
        #expect(updated[0].content.id == original[0].content.id)
        #expect(updated[0].avatarPresentation.role == .assistant)
        #expect(updated.map { $0.avatarPresentation.showsAvatar } == [true, false])
    }
}
