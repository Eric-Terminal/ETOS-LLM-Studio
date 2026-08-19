// ============================================================================
// ChatServiceModelConnectivityTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证模型测活会走对应真实端点，并拒绝没有有效载荷的成功响应。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("模型连通性测试", .serialized)
struct ChatServiceModelConnectivityTests {
    @Test("批量测活覆盖所有可直接使用的已添加模型")
    func candidatesIncludeSupportedActivatedKinds() {
        let provider = makeProvider(models: [
            Model(modelName: "chat", isActivated: true),
            Model(modelName: "embedding", isActivated: true, kind: .embedding),
            Model(modelName: "image", isActivated: true, kind: .image),
            Model(modelName: "inactive", isActivated: false),
            Model(modelName: "legacy-rerank", isActivated: true, kind: .rerank)
        ])
        let service = ChatService(adapters: [:])

        let candidates = service.connectivityTestCandidates(for: provider)

        #expect(candidates.map(\.model.modelName) == ["chat", "embedding", "image"])
    }

    @Test("非流式成功状态不接受空模型响应")
    func nonStreamingProbeRejectsEmptyResponse() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.chatResponse = ChatMessage(role: .assistant, content: "")
        let (service, runnableModel) = makeService(adapter: adapter, model: Model(modelName: "chat", isActivated: true))

        let result = await service.testSingleModelNonStreamingConnectivity(for: runnableModel)

        #expect(result.status == .failed)
        #expect(result.errorMessage?.isEmpty == false)
        #expect(adapter.chatRequestCount == 1)
    }

    @Test("流式成功状态必须包含可解析事件")
    func streamingProbeRejectsUnparseableEvents() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.streamingContent = nil
        let (service, runnableModel) = makeService(
            adapter: adapter,
            model: Model(modelName: "chat", isActivated: true),
            responseBody: Data("data: ignored\n\n".utf8),
            contentType: "text/event-stream"
        )

        let result = await service.testSingleModelStreamingConnectivity(for: runnableModel)

        #expect(result.status == .failed)
        #expect(result.errorMessage?.isEmpty == false)
    }

    @Test("工具能力通过真实工具请求验证而不依赖能力开关")
    func toolProbeDoesNotTrustStoredCapabilityFlag() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.chatResponse = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                InternalToolCall(
                    id: "call-time",
                    toolName: AppToolKind.getSystemTime.toolName,
                    arguments: "{}"
                )
            ]
        )
        let model = Model(modelName: "chat-with-unknown-tools", isActivated: true, capabilities: [])
        let (service, runnableModel) = makeService(adapter: adapter, model: model)

        let result = await service.testSingleModelToolCallingConnectivity(for: runnableModel)

        #expect(result.status == .succeeded)
        #expect(adapter.receivedTools?.first?.name == AppToolKind.getSystemTime.toolName)
    }

    @Test("嵌入模型走嵌入端点并校验向量")
    func embeddingProbeUsesEmbeddingEndpoint() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.embeddingResponse = [[0.1, 0.2, 0.3]]
        let model = Model(modelName: "text-embedding", isActivated: true, kind: .embedding)
        let (service, runnableModel) = makeService(adapter: adapter, model: model)

        let result = await service.testSingleModelEmbeddingConnectivity(for: runnableModel)

        #expect(result.status == .succeeded)
        #expect(adapter.embeddingRequestCount == 1)
        #expect(adapter.chatRequestCount == 0)
        #expect(result.responsePreview?.contains("3") == true)
    }

    @Test("嵌入测活拒绝空向量")
    func embeddingProbeRejectsEmptyVector() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.embeddingResponse = [[]]
        let model = Model(modelName: "empty-embedding", isActivated: true, kind: .embedding)
        let (service, runnableModel) = makeService(adapter: adapter, model: model)

        let result = await service.testSingleModelEmbeddingConnectivity(for: runnableModel)

        #expect(result.status == .failed)
        #expect(result.errorMessage?.isEmpty == false)
    }

    @Test("图片模型走图片生成端点并校验结果")
    func imageProbeUsesImageGenerationEndpoint() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.imageResponse = [
            GeneratedImageResult(data: Data([0x89, 0x50]), mimeType: "image/png", remoteURL: nil, revisedPrompt: nil)
        ]
        let model = Model(modelName: "image-model", isActivated: true, kind: .image)
        let (service, runnableModel) = makeService(adapter: adapter, model: model)

        let result = await service.testSingleModelImageGenerationConnectivity(for: runnableModel)

        #expect(result.status == .succeeded)
        #expect(adapter.imageRequestCount == 1)
        #expect(adapter.chatRequestCount == 0)
    }

    @Test("图片测活拒绝没有数据或地址的空结果")
    func imageProbeRejectsEmptyResult() async {
        let adapter = ConnectivityProbeMockAdapter()
        adapter.imageResponse = [
            GeneratedImageResult(data: nil, mimeType: nil, remoteURL: nil, revisedPrompt: nil)
        ]
        let model = Model(modelName: "empty-image", isActivated: true, kind: .image)
        let (service, runnableModel) = makeService(adapter: adapter, model: model)

        let result = await service.testSingleModelImageGenerationConnectivity(for: runnableModel)

        #expect(result.status == .failed)
        #expect(result.errorMessage?.isEmpty == false)
    }

    private func makeProvider(models: [Model]) -> Provider {
        Provider(
            name: "Connectivity",
            baseURL: "https://connectivity.test/v1",
            apiKeys: ["test-key"],
            apiFormat: "mock",
            models: models
        )
    }

    private func makeService(
        adapter: ConnectivityProbeMockAdapter,
        model: Model,
        responseBody: Data = Data("{}".utf8),
        contentType: String = "application/json"
    ) -> (ChatService, RunnableModel) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectivityProbeURLProtocol.self]
        ConnectivityProbeURLProtocol.configure(body: responseBody, contentType: contentType)

        let provider = makeProvider(models: [model])
        let service = ChatService(
            adapters: ["mock": adapter],
            urlSession: URLSession(configuration: configuration)
        )
        return (service, RunnableModel(provider: provider, model: model))
    }
}

private final class ConnectivityProbeMockAdapter: APIAdapter {
    let requiresExplicitStreamingTermination = false

    var chatRequestCount = 0
    var embeddingRequestCount = 0
    var imageRequestCount = 0
    var receivedTools: [InternalToolDefinition]?
    var chatResponse = ChatMessage(role: .assistant, content: "OK")
    var streamingContent: String? = "OK"
    var embeddingResponse: [[Float]] = []
    var imageResponse: [GeneratedImageResult] = []

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
        receivedTools = tools
        return URLRequest(url: URL(string: "https://connectivity.test/chat")!)
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? {
        URLRequest(url: URL(string: "https://connectivity.test/models")!)
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        []
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        chatResponse
    }

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        streamingContent.map { ChatMessagePart(content: $0) }
    }

    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        embeddingRequestCount += 1
        return URLRequest(url: URL(string: "https://connectivity.test/embeddings")!)
    }

    func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        embeddingResponse
    }

    func buildImageGenerationRequest(
        for model: RunnableModel,
        prompt: String,
        referenceImages: [ImageAttachment]
    ) -> URLRequest? {
        imageRequestCount += 1
        return URLRequest(url: URL(string: "https://connectivity.test/images")!)
    }

    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        imageResponse
    }
}

private final class ConnectivityProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseBody = Data()
    private static var responseContentType = "application/json"

    static func configure(body: Data, contentType: String) {
        lock.lock()
        responseBody = body
        responseContentType = contentType
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let body = Self.responseBody
        let contentType = Self.responseContentType
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
