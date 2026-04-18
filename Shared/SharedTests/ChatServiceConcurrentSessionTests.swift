// ============================================================================
// ChatServiceConcurrentSessionTests.swift
// ============================================================================
// ChatServiceConcurrentSessionTests 测试文件
// - 覆盖会话级并发请求状态
// - 保障跨会话消息不会串写
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("聊天服务会话并发测试")
struct ChatServiceConcurrentSessionTests {

    @MainActor
    @Test("runningSessionIDs 会按会话并发生命周期更新")
    func testRunningSessionIDsLifecycle() async throws {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let provider = Provider(
            name: "Concurrent Session Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        replaceProviders(with: [provider])

        ControlledSessionURLProtocol.reset()
        ControlledSessionURLProtocol.register(marker: "A", responseBody: "回复-A")
        ControlledSessionURLProtocol.register(marker: "B", responseBody: "回复-B")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ControlledSessionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": ConcurrentSessionMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let sessionA = service.createSavedSession(name: "并发会话A")
        let sessionB = service.createSavedSession(name: "并发会话B")
        defer {
            service.deleteSessions([sessionA, sessionB])
            ControlledSessionURLProtocol.reset()
        }

        service.setCurrentSession(sessionA)
        let taskA = Task {
            await service.sendAndProcessMessage(
                content: "A",
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
        }

        try await waitUntil("会话 A 请求启动") {
            ControlledSessionURLProtocol.hasStarted(marker: "A")
        }

        #expect(service.runningSessionIDsSubject.value == Set([sessionA.id]))

        service.setCurrentSession(sessionB)
        let taskB = Task {
            await service.sendAndProcessMessage(
                content: "B",
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
        }

        try await waitUntil("会话 B 请求启动") {
            ControlledSessionURLProtocol.hasStarted(marker: "B")
        }

        let runningAfterBStarted = service.runningSessionIDsSubject.value
        #expect(runningAfterBStarted.contains(sessionA.id))
        #expect(runningAfterBStarted.contains(sessionB.id))

        ControlledSessionURLProtocol.release(marker: "B")
        await taskB.value

        let runningAfterBFinished = service.runningSessionIDsSubject.value
        #expect(runningAfterBFinished.contains(sessionA.id))
        #expect(!runningAfterBFinished.contains(sessionB.id))

        ControlledSessionURLProtocol.release(marker: "A")
        await taskA.value

        #expect(service.runningSessionIDsSubject.value.isEmpty)
    }

    @MainActor
    @Test("并发会话回复不会写入错误会话")
    func testConcurrentResponsesDoNotCrossWriteBetweenSessions() async throws {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let provider = Provider(
            name: "Concurrent Session Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        replaceProviders(with: [provider])

        ControlledSessionURLProtocol.reset()
        ControlledSessionURLProtocol.register(marker: "A", responseBody: "会话A回复")
        ControlledSessionURLProtocol.register(marker: "B", responseBody: "会话B回复")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ControlledSessionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": ConcurrentSessionMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let sessionA = service.createSavedSession(name: "隔离会话A")
        let sessionB = service.createSavedSession(name: "隔离会话B")
        defer {
            service.deleteSessions([sessionA, sessionB])
            ControlledSessionURLProtocol.reset()
        }

        service.setCurrentSession(sessionA)
        let taskA = Task {
            await service.sendAndProcessMessage(
                content: "A",
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
        }

        try await waitUntil("会话 A 请求启动") {
            ControlledSessionURLProtocol.hasStarted(marker: "A")
        }

        service.setCurrentSession(sessionB)
        let taskB = Task {
            await service.sendAndProcessMessage(
                content: "B",
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
        }

        try await waitUntil("会话 B 请求启动") {
            ControlledSessionURLProtocol.hasStarted(marker: "B")
        }

        ControlledSessionURLProtocol.release(marker: "B")
        await taskB.value
        ControlledSessionURLProtocol.release(marker: "A")
        await taskA.value

        let sessionAMessages = Persistence.loadMessages(for: sessionA.id)
        let sessionBMessages = Persistence.loadMessages(for: sessionB.id)

        let assistantRepliesA = sessionAMessages
            .filter { $0.role == .assistant }
            .map(\.content)
        let assistantRepliesB = sessionBMessages
            .filter { $0.role == .assistant }
            .map(\.content)

        #expect(assistantRepliesA.contains("会话A回复"))
        #expect(!assistantRepliesA.contains("会话B回复"))
        #expect(assistantRepliesB.contains("会话B回复"))
        #expect(!assistantRepliesB.contains("会话A回复"))
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

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        Issue.record("等待超时：\(description)")
    }
}

private final class ConcurrentSessionMockAdapter: APIAdapter {
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
        var components = URLComponents(string: "https://example.com/chat")
        components?.queryItems = [URLQueryItem(name: "marker", value: marker)]
        guard let url = components?.url else { return nil }
        return URLRequest(url: url)
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? {
        URLRequest(url: URL(string: "https://example.com/models")!)
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        []
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        ChatMessage(role: .assistant, content: String(decoding: data, as: UTF8.self))
    }

    func parseStreamingResponse(line: String) -> ChatMessagePart? {
        nil
    }
}

private final class ControlledSessionURLProtocol: URLProtocol {
    private struct RegisteredResponse {
        let gate: DispatchSemaphore
        let responseBody: Data
        var started: Bool
    }

    private static let lock = NSLock()
    private static var registeredResponses: [String: RegisteredResponse] = [:]

    static func reset() {
        lock.lock()
        registeredResponses.removeAll()
        lock.unlock()
    }

    static func register(marker: String, responseBody: String) {
        lock.lock()
        registeredResponses[marker] = RegisteredResponse(
            gate: DispatchSemaphore(value: 0),
            responseBody: Data(responseBody.utf8),
            started: false
        )
        lock.unlock()
    }

    static func release(marker: String) {
        lock.lock()
        let gate = registeredResponses[marker]?.gate
        lock.unlock()
        gate?.signal()
    }

    static func hasStarted(marker: String) -> Bool {
        lock.lock()
        let started = registeredResponses[marker]?.started ?? false
        lock.unlock()
        return started
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let marker = components.queryItems?.first(where: { $0.name == "marker" })?.value else {
            failWithError(message: "缺少 marker 参数")
            return
        }

        var gate: DispatchSemaphore?
        var responseBody = Data()

        Self.lock.lock()
        if var registered = Self.registeredResponses[marker] {
            registered.started = true
            gate = registered.gate
            responseBody = registered.responseBody
            Self.registeredResponses[marker] = registered
        }
        Self.lock.unlock()

        guard let gate else {
            failWithError(message: "未注册 marker: \(marker)")
            return
        }

        DispatchQueue.global().async {
            gate.wait()

            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: responseBody)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func failWithError(message: String) {
        let error = NSError(
            domain: "ControlledSessionURLProtocol",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }
}
