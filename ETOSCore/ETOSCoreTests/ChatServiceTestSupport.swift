// ============================================================================
// ChatServiceTestSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 集成测试共用的模拟适配器与轻量响应结构。
// ============================================================================

import Foundation
@testable import ETOSCore

final class MockAPIAdapter: APIAdapter {
    var receivedMessages: [ChatMessage]?
    var receivedTitleMessages: [ChatMessage]?
    var receivedReasoningSummaryMessages: [ChatMessage]?
    var receivedConversationSummaryMessages: [ChatMessage]?
    var receivedConversationProfileMessages: [ChatMessage]?
    var receivedTools: [InternalToolDefinition]?
    var receivedAudioAttachments: [UUID: AudioAttachment]?
    var receivedImageAttachments: [UUID: [ImageAttachment]]?
    var receivedFileAttachments: [UUID: [FileAttachment]]?
    var responseToReturn: ChatMessage?
    var receivedChatModel: RunnableModel?
    var receivedTitleModel: RunnableModel?
    var receivedReasoningSummaryModel: RunnableModel?
    var receivedChatStreamFlags: [Bool] = []

    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        if messages.first?.content.contains("思考摘要助手") == true {
            receivedReasoningSummaryMessages = messages
            receivedReasoningSummaryModel = model
            return URLRequest(url: URL(string: "https://fake.url/reasoning-summary")!)
        } else if messages.first?.content.contains("会话压缩助手") == true {
            receivedConversationSummaryMessages = messages
            return URLRequest(url: URL(string: "https://fake.url/chat")!)
        } else if messages.first?.content.contains("用户画像整理助手") == true ||
                    messages.first?.content.contains("用户画像去重助手") == true {
            receivedConversationProfileMessages = messages
            return URLRequest(url: URL(string: "https://fake.url/conversation-profile")!)
        } else if messages.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            receivedTitleMessages = messages
            receivedTitleModel = model
            return URLRequest(url: URL(string: "https://fake.url/title-gen")!)
        } else {
            receivedMessages = messages
            receivedTools = tools
            receivedAudioAttachments = audioAttachments
            receivedImageAttachments = imageAttachments
            receivedFileAttachments = fileAttachments
            receivedChatModel = model
            if let stream = commonPayload["stream"] as? Bool {
                receivedChatStreamFlags.append(stream)
            }
            return URLRequest(url: URL(string: "https://fake.url/chat")!)
        }
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        if let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
           let content = response.choices.first?.message.content {
            return ChatMessage(role: .assistant, content: content)
        }

        if let received = receivedMessages, received.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let content = response.choices.first?.message.content ?? ""
            return ChatMessage(role: .assistant, content: content)
        }

        return responseToReturn ?? ChatMessage(role: .assistant, content: "Default mock response")
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? { nil }
    func parseStreamingResponse(line: String) -> ChatMessagePart? { nil }
}

final class RetryStreamingMockAdapter: APIAdapter {
    func buildChatRequest(
        for model: RunnableModel,
        commonPayload: [String : Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID : AudioAttachment],
        imageAttachments: [UUID : [ImageAttachment]],
        fileAttachments: [UUID : [FileAttachment]]
    ) -> URLRequest? {
        let marker = messages.last(where: { $0.role == .user })?.content ?? "unknown"
        var components = URLComponents(string: "https://fake.url/retry-stream")
        components?.queryItems = [URLQueryItem(name: "marker", value: marker)]
        return components?.url.map { URLRequest(url: $0) }
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? {
        URLRequest(url: URL(string: "https://fake.url/models")!)
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        []
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        ChatMessage(role: .assistant, content: String(decoding: data, as: UTF8.self))
    }

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        ChatMessagePart(content: line)
    }
}
