import Foundation
import Testing
@testable import ETOSCore

struct OpenAIAdapterPrefillTests {
    @Test("预填充始终回传原推理，历史消息仍遵循回传设置", arguments: [ReasoningContentEchoMode.never, .toolCallsOnly, .always])
    func prefillPreservesReasoning(mode: ReasoningContentEchoMode) throws {
        let adapter = OpenAIAdapter()
        let model = RunnableModel(
            provider: Provider(name: "测试", baseURL: "https://example.com/v1", apiKeys: ["test"], apiFormat: "openai-compatible"),
            model: Model(modelName: "test-model")
        )
        let history = ChatMessage(role: .assistant, content: "历史正文", reasoningContent: "历史推理")
        let prefix = ChatMessage(role: .assistant, content: "  未完成正文 ", reasoningContent: "  原始推理\n")
        let request = try #require(adapter.buildChatRequest(
            for: model,
            commonPayload: [
                ReasoningContentEchoPayload.key: mode.rawValue,
                OpenAIAdapter.assistantPrefillMessageIDControlKey: prefix.id.uuidString,
                OpenAIAdapter.responsesForceFullInputControlKey: true
            ],
            messages: [history, ChatMessage(role: .user, content: "继续"), prefix],
            tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]
        ))
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == prefix.content)
        #expect(messages.last?["reasoning_content"] as? String == prefix.reasoningContent)
        #expect(messages[0]["reasoning_content"] as? String == (mode == .always ? history.reasoningContent : nil))
        #expect(payload[OpenAIAdapter.assistantPrefillMessageIDControlKey] == nil)
        #expect(payload[OpenAIAdapter.responsesForceFullInputControlKey] == nil)
        #expect(payload[ReasoningContentEchoPayload.key] == nil)
    }
}
