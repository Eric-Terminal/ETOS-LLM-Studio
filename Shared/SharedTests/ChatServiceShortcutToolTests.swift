import Testing
import Foundation
@testable import Shared

@Suite("ChatService Shortcut Tool Tests")
struct ChatServiceShortcutToolTests {

    @MainActor
    @Test("sendAndProcessMessage injects enabled shortcut tools")
    func testShortcutToolsInjected() async {
        let originalProviders = ConfigLoader.loadProviders()
        let originalShortcutTools = ShortcutToolStore.loadTools()

        defer {
            for provider in ConfigLoader.loadProviders() {
                ConfigLoader.deleteProvider(provider)
            }
            for provider in originalProviders {
                ConfigLoader.saveProvider(provider)
            }
            ShortcutToolStore.saveTools(originalShortcutTools)
            ShortcutToolManager.shared.reloadFromDisk()
        }

        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }

        let provider = Provider(
            name: "Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        ConfigLoader.saveProvider(provider)

        let shortcutTool = ShortcutToolDefinition(
            name: "Injected Tool",
            isEnabled: true,
            generatedDescription: "for unit test"
        )
        ShortcutToolStore.saveTools([shortcutTool])
        ShortcutToolManager.shared.reloadFromDisk()

        let adapter = ShortcutInjectionMockAdapter()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ShortcutInjectionURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = ChatService(
            adapters: ["openai-compatible": adapter],
            memoryManager: MemoryManager(),
            urlSession: session
        )

        await service.sendAndProcessMessage(
            content: "hello",
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

        let toolNames = adapter.receivedTools?.map(\.name) ?? []
        #expect(toolNames.contains(where: { $0.hasPrefix(ShortcutToolNaming.toolAliasPrefix) }))
    }
}

private final class ShortcutInjectionMockAdapter: APIAdapter {
    var receivedTools: [InternalToolDefinition]?

    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID : AudioAttachment], imageAttachments: [UUID : [ImageAttachment]], fileAttachments: [UUID : [FileAttachment]]) -> URLRequest? {
        receivedTools = tools
        return URLRequest(url: URL(string: "https://example.com/chat")!)
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

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        nil
    }
}

private final class ShortcutInjectionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data("{}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
