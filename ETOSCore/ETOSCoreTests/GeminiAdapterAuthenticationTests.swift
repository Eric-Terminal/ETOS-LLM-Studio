// ============================================================================
// GeminiAdapterAuthenticationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 Gemini 请求的密钥传递、流式参数和自定义请求头覆盖约定。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Gemini 请求认证")
struct GeminiAdapterAuthenticationTests {
    @Test("各类请求通过请求头传递密钥并保留自定义查询参数", arguments: [false, true])
    func usesHeaderAuthentication(useHeaderOverrides: Bool) throws {
        let adapter = GeminiAdapter()
        let apiKey = "AQ.test-key"
        let provider = Provider(
            name: "Gemini 认证测试",
            baseURL: "https://proxy.example/google/v1beta?route=gemini",
            apiKeys: [apiKey],
            apiFormat: "gemini",
            headerOverrides: useHeaderOverrides ? [
                "X-Goog-Api-Key": "override-{api_key}",
                "X-Client": "ETOS"
            ] : [:]
        )
        let chatModel = RunnableModel(provider: provider, model: Model(modelName: "gemini-2.5-pro"))
        let embeddingModel = RunnableModel(
            provider: provider,
            model: Model(modelName: "gemini-embedding-001", kind: .embedding)
        )
        let messages = [ChatMessage(role: .user, content: "测试认证")]
        let chatRequest = adapter.buildChatRequest(
            for: chatModel,
            commonPayload: [:],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        )
        let streamingRequest = adapter.buildChatRequest(
            for: chatModel,
            commonPayload: ["stream": true],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        )
        let cases: [(request: URLRequest?, path: String, method: String, streaming: Bool)] = [
            (chatRequest, "models/gemini-2.5-pro:generateContent", "POST", false),
            (streamingRequest, "models/gemini-2.5-pro:streamGenerateContent", "POST", true),
            (adapter.buildModelListRequest(for: provider), "models", "GET", false),
            (
                adapter.buildEmbeddingRequest(for: embeddingModel, texts: ["第一段"]),
                "models/gemini-embedding-001:embedContent", "POST", false
            ),
            (
                adapter.buildEmbeddingRequest(for: embeddingModel, texts: ["第一段", "第二段"]),
                "models/gemini-embedding-001:batchEmbedContents", "POST", false
            ),
            (
                adapter.buildImageGenerationRequest(for: chatModel, prompt: "画一只猫", referenceImages: []),
                "models/gemini-2.5-pro:generateContent", "POST", false
            )
        ]

        for testCase in cases {
            let request = try #require(testCase.request)
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            var expectedQueryItems = [URLQueryItem(name: "route", value: "gemini")]
            if testCase.streaming {
                expectedQueryItems.append(URLQueryItem(name: "alt", value: "sse"))
            }

            #expect(url.path == "/google/v1beta/\(testCase.path)")
            #expect(request.httpMethod == testCase.method)
            #expect(components.queryItems == expectedQueryItems)
            #expect(!url.absoluteString.contains(apiKey))
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == (useHeaderOverrides ? "override-\(apiKey)" : apiKey))
            #expect(request.value(forHTTPHeaderField: "X-Client") == (useHeaderOverrides ? "ETOS" : nil))
        }
    }

    @Test("聊天请求沿用视频上传所选密钥并用于请求头占位符", arguments: [false, true])
    func preservesSelectedVideoAPIKey(isStreaming: Bool) throws {
        let provider = Provider(
            name: "Gemini 视频密钥测试",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeys: ["unused-key"],
            apiFormat: "gemini",
            headerOverrides: ["X-Selected-Key": "{api_key}"]
        )
        let model = RunnableModel(provider: provider, model: Model(modelName: "gemini-2.5-pro"))
        let request = try #require(GeminiAdapter().buildChatRequest(
            for: model,
            commonPayload: ["stream": isStreaming, GeminiAdapter.apiKeyControlKey: "AQ.selected-key"],
            messages: [ChatMessage(role: .user, content: "概括视频")],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))

        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AQ.selected-key")
        #expect(request.value(forHTTPHeaderField: "X-Selected-Key") == "AQ.selected-key")
        #expect(request.url?.query == (isStreaming ? "alt=sse" : nil))
    }
}
