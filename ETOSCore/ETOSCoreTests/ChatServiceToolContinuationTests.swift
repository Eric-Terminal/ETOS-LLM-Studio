// ============================================================================
// ChatServiceToolContinuationTests.swift
// ============================================================================
// 覆盖工具结果写回位置、混合调用收敛与多步请求的实际上下文。
// ============================================================================

import Foundation
import Combine
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("迟到工具结果紧随原调用，保留同版本后续工具链", arguments: [false, true])
    func delayedToolResultStaysWithOriginalCall(hasAttemptMetadata: Bool) async throws {
        await cleanup()
        let session = createPermanentTestSession(name: "迟到工具结果回归")
        defer { chatService.deleteSessions([session]) }
        let sessionID = session.id
        let user = ChatMessage(role: .user, content: "检索并整理结果")
        let attempt = hasAttemptMetadata
            ? ChatService.ResponseAttemptMetadata(groupID: user.id, attemptID: UUID(), attemptIndex: 0)
            : nil
        let firstCall = InternalToolCall(id: "first-search", toolName: "search_memory", arguments: "{}")
        let delayedCall = InternalToolCall(id: "background-save", toolName: "save_memory", arguments: "{}")
        let nextCall = InternalToolCall(id: "next-search", toolName: "search_memory", arguments: "{}")
        var source = ChatMessage(role: .assistant, content: "检索中", toolCalls: [firstCall, delayedCall])
        var firstResult = ChatMessage(role: .tool, content: "第一轮检索结果", toolCalls: [firstCall])
        var nextSource = ChatMessage(role: .assistant, content: "", toolCalls: [nextCall])
        var nextResult = ChatMessage(role: .tool, content: "第二轮检索结果", toolCalls: [nextCall])
        var loading = ChatMessage(role: .assistant, content: "")
        var delayedResult = ChatMessage(role: .tool, content: "后台保存完成", toolCalls: [delayedCall])
        chatService.applyResponseAttemptMetadata(attempt, to: &source)
        chatService.applyResponseAttemptMetadata(attempt, to: &firstResult)
        chatService.applyResponseAttemptMetadata(attempt, to: &nextSource)
        chatService.applyResponseAttemptMetadata(attempt, to: &nextResult)
        chatService.applyResponseAttemptMetadata(attempt, to: &loading)
        chatService.applyResponseAttemptMetadata(attempt, to: &delayedResult)
        chatService.updateMessages([user, source, firstResult, nextSource, nextResult, loading], for: sessionID)

        let updated = try await chatService.insertConversationResponseAttemptMessagesAtomically(
            [delayedResult], afterAttemptOf: source.id, in: sessionID
        )
        let expectedIDs = [user.id, source.id, firstResult.id, delayedResult.id, nextSource.id, nextResult.id, loading.id]
        #expect(updated.map(\.id) == expectedIDs)
        #expect(Persistence.loadMessages(for: sessionID).map(\.id) == expectedIDs)

        let prepared = chatService.preparedMessagesForRequest(
            from: updated, loadingMessageID: loading.id, session: chatService.currentSessionSubject.value
        )
        #expect(prepared.map(\.id) == Array(expectedIDs.dropLast()))
        #expect(prepared.filter { $0.role == .tool }.map(\.content) == [
            "第一轮检索结果", "后台保存完成", "第二轮检索结果"
        ])
        await cleanup()
    }

    @Test("混合阻塞与非阻塞工具的续写请求包含本轮全部结果")
    func mixedToolFollowUpIncludesEveryResult() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        let session = createPermanentTestSession(name: "混合工具结果回归")
        defer { chatService.deleteSessions([session]) }
        let sessionID = session.id
        let user = ChatMessage(role: .user, content: "检索并记住结果")
        var loading = ChatMessage(role: .assistant, content: "")
        chatService.applyResponseAttemptMetadata(
            .init(groupID: user.id, attemptID: UUID(), attemptIndex: 0), to: &loading
        )
        chatService.updateMessages([user, loading], for: sessionID)
        let search = InternalToolCall(
            id: "blocking-search", toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"抹茶"}"#
        )
        let save = InternalToolCall(
            id: "nonblocking-save", toolName: "save_memory",
            arguments: #"{"content":"用户喜欢抹茶。","kind":"preference","source":"user_statement"}"#
        )

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(role: .assistant, content: "我会检索并保存。", toolCalls: [search, save]),
            loadingMessageID: loading.id, currentSessionID: sessionID, userMessage: user,
            wasTemporarySession: false, availableTools: [chatService.searchMemoryTool, chatService.saveMemoryTool],
            aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 1,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
        )

        let sent = try #require(mockAdapter.receivedMessages)
        let sentCalls = try #require(sent.first(where: { $0.id == loading.id })?.toolCalls)
        #expect(sentCalls.map(\.id) == [search.id, save.id])
        let results = sent.filter { $0.role == .tool }
        #expect(results.compactMap { $0.toolCalls?.first?.id } == [search.id, save.id])
        #expect(results.allSatisfy { !$0.content.isEmpty })
        #expect(results.last?.content.contains("用户喜欢抹茶") == true)
        #expect(sent.contains(where: { $0.id == user.id }))
        await cleanup()
    }

    @Test("流式与非流式多步请求均累积工具结果并保留各轮用量", arguments: [false, true])
    func multiStepToolRequestsAccumulateContext(enableStreaming: Bool) async throws {
        await cleanup()
        await memoryManager.addMemory(content: "用户喜欢抹茶拿铁。")
        let adapter = ToolContinuationRecordingAdapter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = ChatService(
            adapters: ["openai-compatible": adapter], memoryManager: memoryManager,
            urlSession: URLSession(configuration: configuration)
        )
        service.setSelectedModel(dummyModel)
        let session = service.createSavedSession(name: "多步工具上下文回归")
        service.setCurrentSession(session)
        defer { service.deleteSessions([session]) }
        let user = ChatMessage(role: .user, content: "检索两次后总结")
        var loading = ChatMessage(role: .assistant, content: "")
        service.applyResponseAttemptMetadata(
            .init(groupID: user.id, attemptID: UUID(), attemptIndex: 0), to: &loading
        )
        service.updateMessages([user, loading], for: session.id)
        let responses = [
            #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"search-2","type":"function","function":{"name":"search_memory","arguments":"{\"mode\":\"keyword\",\"query\":\"抹茶\"}"}}]}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"两次检索已完成。"}}],"usage":{"prompt_tokens":200,"completion_tokens":10,"total_tokens":210}}"#
        ]
        for (index, body) in responses.enumerated() {
            let url = try #require(URL(string: "https://fake.url/tool-continuation/\(index + 1)"))
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let responseData: Data
            if enableStreaming {
                var payload = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                let choices = try #require(payload["choices"] as? [[String: Any]])
                let delta = try #require(choices.first?["message"] as? [String: Any])
                payload["choices"] = [["delta": delta]]
                let eventData = try JSONSerialization.data(withJSONObject: payload)
                responseData = Data("data: \(String(decoding: eventData, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
            } else {
                responseData = Data(body.utf8)
            }
            MockURLProtocol.mockResponses[url] = .success((response, responseData))
        }
        let firstCall = InternalToolCall(
            id: "search-1", toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"抹茶"}"#
        )

        await service.processResponseMessage(
            responseMessage: ChatMessage(role: .assistant, content: "", toolCalls: [firstCall]),
            loadingMessageID: loading.id, currentSessionID: session.id, userMessage: user,
            wasTemporarySession: false, availableTools: [service.searchMemoryTool],
            aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 1,
            enableStreaming: enableStreaming,
            enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
        )

        #expect(adapter.requestBodies.count == 2)
        for (index, body) in adapter.requestBodies.enumerated() {
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["stream"] as? Bool == enableStreaming)
            let sent = try #require(payload["messages"] as? [[String: Any]])
            let results = sent.filter { $0["role"] as? String == "tool" }
            #expect(results.count == index + 1)
            #expect(results.compactMap { $0["tool_call_id"] as? String } == (1...(index + 1)).map { "search-\($0)" })
            #expect(results.allSatisfy { ($0["content"] as? String)?.contains("用户喜欢抹茶拿铁") == true })
            #expect(sent.contains { $0["content"] as? String == user.content })
        }
        let stored = service.messagesSnapshot(for: session.id)
        #expect(stored.last?.content == "两次检索已完成。")
        #expect(stored.compactMap { $0.tokenUsage?.promptTokens } == [100, 200])
        await cleanup()
    }
}

/// 保留真实 OpenAI 请求构建与响应解析，只把网络地址改到逐轮固定的模拟响应。
private final class ToolContinuationRecordingAdapter: APIAdapter {
    let requiresExplicitStreamingTermination = true
    private let adapter = OpenAIAdapter()
    private(set) var requestBodies: [Data] = []

    func buildChatRequest(
        for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage],
        tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        guard var request = adapter.buildChatRequest(
            for: model, commonPayload: commonPayload, messages: messages, tools: tools,
            audioAttachments: audioAttachments, imageAttachments: imageAttachments, fileAttachments: fileAttachments
        ), let body = request.httpBody else { return nil }
        requestBodies.append(body)
        request.url = URL(string: "https://fake.url/tool-continuation/\(requestBodies.count)")
        return request
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        try adapter.parseResponse(data: data)
    }

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        adapter.parseStreamingResponse(line: line)
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? { nil }
}
