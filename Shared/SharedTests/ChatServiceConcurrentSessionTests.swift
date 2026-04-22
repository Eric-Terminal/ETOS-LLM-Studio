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
    @Test("cancelRequest(for:) 仅取消目标会话，不影响其他会话请求")
    func testCancelRequestOnlyAffectsTargetSession() async throws {
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
        ControlledSessionURLProtocol.register(marker: "A", responseBody: "会话A完成")
        ControlledSessionURLProtocol.register(marker: "B", responseBody: "会话B完成")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ControlledSessionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": ConcurrentSessionMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let sessionA = service.createSavedSession(name: "取消会话A")
        let sessionB = service.createSavedSession(name: "取消会话B")
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

        await service.cancelRequest(for: sessionA.id)
        let runningAfterCancelA = service.runningSessionIDsSubject.value
        #expect(!runningAfterCancelA.contains(sessionA.id))
        #expect(runningAfterCancelA.contains(sessionB.id))

        ControlledSessionURLProtocol.release(marker: "B")
        await taskB.value
        await taskA.value

        #expect(service.runningSessionIDsSubject.value.isEmpty)

        let sessionAMessages = Persistence.loadMessages(for: sessionA.id)
        let sessionBMessages = Persistence.loadMessages(for: sessionB.id)

        let assistantRepliesA = sessionAMessages
            .filter { $0.role == .assistant }
            .map(\.content)
        let assistantRepliesB = sessionBMessages
            .filter { $0.role == .assistant }
            .map(\.content)

        #expect(!assistantRepliesA.contains("会话A完成"))
        #expect(assistantRepliesB.contains("会话B完成"))
    }

    @MainActor
    @Test("流式请求中途断网时保留已生成正文并追加错误气泡")
    func testStreamingErrorPreservesPartialAssistantAndAppendsErrorMessage() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let provider = Provider(
            name: "Streaming Error Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        replaceProviders(with: [provider])

        StreamingFailureURLProtocol.reset()
        StreamingFailureURLProtocol.register(
            marker: "partial",
            chunks: ["第一段回复\n"],
            errorMessage: "网络连接已经断开。"
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StreamingFailureURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": StreamingFailureMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let testSession = service.createSavedSession(name: "流式断网保留正文")
        defer {
            service.deleteSessions([testSession])
            StreamingFailureURLProtocol.reset()
        }
        service.setCurrentSession(testSession)

        await service.sendAndProcessMessage(
            content: "partial",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: true,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let storedMessages = Persistence.loadMessages(for: testSession.id)
        #expect(storedMessages.count == 3)
        #expect(storedMessages[0].role == .user)
        #expect(storedMessages[1].role == .assistant)
        #expect(storedMessages[1].content == "第一段回复")
        #expect(storedMessages[2].role == .error)
        #expect(storedMessages[2].content.contains("网络连接已经断开。"))
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

private final class StreamingFailureMockAdapter: APIAdapter {
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
        var components = URLComponents(string: "https://example.com/stream")
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
        ChatMessagePart(content: line)
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
    private var activeMarker: String?
    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        let responses = Array(registeredResponses.values)
        registeredResponses.removeAll()
        lock.unlock()
        for response in responses {
            response.gate.signal()
        }
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
        activeMarker = marker

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
            self.stateLock.lock()
            let stopped = self.isStopped
            self.stateLock.unlock()
            if stopped { return }

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

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
        if let marker = activeMarker {
            Self.release(marker: marker)
        }
    }

    private func failWithError(message: String) {
        let error = NSError(
            domain: "ControlledSessionURLProtocol",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class StreamingFailureURLProtocol: URLProtocol {
    private struct RegisteredScenario {
        let chunks: [Data]
        let error: Error
    }

    private static let lock = NSLock()
    private static var registeredScenarios: [String: RegisteredScenario] = [:]

    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        registeredScenarios.removeAll()
        lock.unlock()
    }

    static func register(marker: String, chunks: [String], errorMessage: String) {
        lock.lock()
        registeredScenarios[marker] = RegisteredScenario(
            chunks: chunks.map { Data($0.utf8) },
            error: NSError(
                domain: "StreamingFailureURLProtocol",
                code: -1005,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        )
        lock.unlock()
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

        Self.lock.lock()
        let scenario = Self.registeredScenarios[marker]
        Self.lock.unlock()

        guard let scenario else {
            failWithError(message: "未注册 marker: \(marker)")
            return
        }

        DispatchQueue.global().async {
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain; charset=utf-8"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            for chunk in scenario.chunks {
                self.stateLock.lock()
                let stopped = self.isStopped
                self.stateLock.unlock()
                if stopped { return }
                self.client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.02)
            }

            self.stateLock.lock()
            let stopped = self.isStopped
            self.stateLock.unlock()
            if stopped { return }

            self.client?.urlProtocol(self, didFailWithError: scenario.error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
    }

    private func failWithError(message: String) {
        let error = NSError(
            domain: "StreamingFailureURLProtocol",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }
}
