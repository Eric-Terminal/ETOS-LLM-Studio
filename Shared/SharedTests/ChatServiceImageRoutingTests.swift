// ============================================================================
// ChatServiceImageRoutingTests.swift
// ============================================================================
// ChatServiceImageRoutingTests 测试文件
// - 覆盖主聊天在生图模型下的路由行为
// - 保障生图模式下的附件限制不会回归
// ============================================================================

import Testing
import Foundation
import Combine
@testable import Shared

@Suite("聊天服务生图路由测试")
struct ChatServiceImageRoutingTests {

    @MainActor
    @Test("选中带生图能力模型时主聊天自动走生图请求通道")
    func testSendAndProcessMessageRoutesToImageGenerationChannel() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let imageModelProvider = Provider(
            name: "Image Route Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "test-image-model",
                    displayName: "Test Image Model",
                    isActivated: true,
                    capabilities: [.chat, .imageGeneration]
                )
            ]
        )
        replaceProviders(with: [imageModelProvider])

        let adapter = ImageRoutingMockAdapter()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ImageRoutingURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let service = ChatService(
            adapters: ["openai-compatible": adapter],
            memoryManager: MemoryManager(),
            urlSession: session
        )

        let selectedModel = service.activatedRunnableModels.first
        service.setSelectedModel(selectedModel)

        await service.sendAndProcessMessage(
            content: "画一只会发光的猫",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        #expect(adapter.chatRequestCount == 0)
        #expect(adapter.imageRequestCount == 1)
        #expect(adapter.lastPrompt == "画一只会发光的猫")
    }

    @MainActor
    @Test("生图模式下发送语音附件会被直接拦截")
    func testSendAndProcessMessageRejectsAudioAttachmentInImageMode() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let imageModelProvider = Provider(
            name: "Image Route Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "test-image-model",
                    displayName: "Test Image Model",
                    isActivated: true,
                    capabilities: [.chat, .imageGeneration]
                )
            ]
        )
        replaceProviders(with: [imageModelProvider])

        let adapter = ImageRoutingMockAdapter()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ImageRoutingURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let service = ChatService(
            adapters: ["openai-compatible": adapter],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let audioAttachment = AudioAttachment(
            data: Data([0x00, 0x01, 0x02]),
            mimeType: "audio/wav",
            format: "wav",
            fileName: "test.wav"
        )

        await service.sendAndProcessMessage(
            content: "请根据语音生成图片",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            audioAttachment: audioAttachment
        )

        #expect(adapter.chatRequestCount == 0)
        #expect(adapter.imageRequestCount == 0)

        let messageContents = service.messagesForSessionSubject.value.map(\.content)
        #expect(messageContents.contains(where: { $0.contains("生图模式不支持语音附件。") }))
    }

    @MainActor
    private func replaceProviders(with providers: [Provider]) {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        for provider in providers {
            ConfigLoader.saveProvider(provider)
        }
    }
}

private final class ImageRoutingMockAdapter: APIAdapter {
    var chatRequestCount = 0
    var imageRequestCount = 0
    var lastPrompt: String?

    func buildChatRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        chatRequestCount += 1
        return URLRequest(url: URL(string: "https://example.com/chat")!)
    }

    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        imageRequestCount += 1
        lastPrompt = prompt
        return URLRequest(url: URL(string: "https://example.com/images")!)
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? {
        URLRequest(url: URL(string: "https://example.com/models")!)
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        []
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        ChatMessage(role: .assistant, content: "ok")
    }

    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+O7kAAAAASUVORK5CYII="
        let imageData = Data(base64Encoded: tinyPNGBase64) ?? Data([0x89, 0x50, 0x4E, 0x47])
        return [GeneratedImageResult(data: imageData, mimeType: "image/png", remoteURL: nil, revisedPrompt: nil)]
    }

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        nil
    }
}

private final class ImageRoutingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
