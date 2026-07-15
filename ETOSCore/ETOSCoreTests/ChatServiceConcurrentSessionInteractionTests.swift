// ============================================================================
// ChatServiceConcurrentSessionInteractionTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天服务并发会话的取消请求、流式失败与测试基础设施。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("聊天服务并发会话交互测试")
struct ChatServiceConcurrentSessionInteractionTests {

    @MainActor
    @Test("切回后台运行会话时优先使用运行期消息快照")
    func testActivatingRunningBackgroundSessionUsesRuntimeMessageSnapshot() {
        let service = ChatService(memoryManager: MemoryManager())
        let sessionA = service.createSavedSession(name: "后台工具会话")
        let sessionB = service.createSavedSession(name: "当前会话")
        defer {
            service.deleteSessions([sessionA, sessionB])
        }

        let toolCall = InternalToolCall(
            id: "call_widget",
            toolName: "app_show_widget",
            arguments: #"{"widget_code":"<div>hi</div>"}"#
        )
        let staleAssistant = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [toolCall],
            responseGroupID: sessionA.id,
            responseAttemptID: UUID(),
            responseAttemptIndex: 0
        )
        Persistence.saveMessages([staleAssistant], for: sessionA.id)

        var resolvedCall = toolCall
        resolvedCall.result = "OK"
        let freshAssistant = ChatMessage(
            id: staleAssistant.id,
            role: .assistant,
            content: "",
            toolCalls: [resolvedCall],
            responseGroupID: staleAssistant.responseGroupID,
            responseAttemptID: staleAssistant.responseAttemptID,
            responseAttemptIndex: staleAssistant.responseAttemptIndex
        )
        let followUpLoading = ChatMessage(
            role: .assistant,
            content: "",
            responseGroupID: staleAssistant.responseGroupID,
            responseAttemptID: staleAssistant.responseAttemptID,
            responseAttemptIndex: staleAssistant.responseAttemptIndex
        )
        let runtimeMessages = [freshAssistant, followUpLoading]
        let token = UUID()
        service.setRequestContext(
            ChatService.RequestExecutionContext(
                token: token,
                task: nil,
                loadingMessageID: followUpLoading.id,
                imageGenerationContext: nil
            ),
            for: sessionA.id
        )
        service.storeRuntimeMessagesSnapshot(runtimeMessages, for: sessionA.id)

        service.setCurrentSession(sessionB)
        let activatedMessages = service.messagesForSessionActivation(sessionA.id)

        #expect(activatedMessages.map(\.id) == runtimeMessages.map(\.id))
        #expect(activatedMessages.first?.toolCalls?.first?.result == "OK")

        service.clearRequestContextIfNeeded(for: sessionA.id, token: token)
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

        var runningAtCancelEvent: Set<UUID>?
        let statusCancellable = service.sessionRequestStatusSubject.sink { event in
            guard event.sessionID == sessionA.id, event.status == .cancelled else { return }
            runningAtCancelEvent = service.runningSessionIDsSubject.value
        }

        await service.cancelRequest(for: sessionA.id)
        statusCancellable.cancel()
        let runningAfterCancelA = service.runningSessionIDsSubject.value
        let runningAtCancelledEvent = try #require(runningAtCancelEvent)
        #expect(!runningAtCancelledEvent.contains(sessionA.id))
        #expect(runningAtCancelledEvent.contains(sessionB.id))
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
        let assistantMessage = storedMessages.first { $0.role == .assistant }
        let errorMessage = storedMessages.first { $0.role == .error }
        #expect(storedMessages.count == 3)
        #expect(storedMessages.map(\.role) == [.user, .assistant, .error])
        #expect(assistantMessage?.content == "第一段回复")
        #expect(errorMessage?.content.contains("网络连接已经断开。") == true)
    }

    @MainActor
    @Test("流式尾部混入代理错误响应体时展示 HTTP 状态和完整详情")
    func testStreamingTrailingProxyErrorBodyUsesHTTPErrorFormatting() async throws {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let provider = Provider(
            name: "Streaming Proxy Error Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        replaceProviders(with: [provider])

        let longTail = String(repeating: "代理错误详情", count: 80)
        StreamingTrailingProxyErrorURLProtocol.reset()
        StreamingTrailingProxyErrorURLProtocol.register(
            marker: "proxy-timeout",
            chunks: [
                "delta:第一段回复\n",
                "HTTP/1.1 504 Gateway Timeout\n",
                "<html><head><title>504 Gateway Time-out</title></head><body>\(longTail)</body></html>\n"
            ],
            finishErrorMessage: "代理关闭了空闲流式连接。"
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StreamingTrailingProxyErrorURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": StreamingTrailingProxyErrorMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let testSession = service.createSavedSession(name: "流式代理错误体")
        defer {
            service.deleteSessions([testSession])
            StreamingTrailingProxyErrorURLProtocol.reset()
        }
        service.setCurrentSession(testSession)

        await service.sendAndProcessMessage(
            content: "proxy-timeout",
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
        let assistantMessage = storedMessages.first { $0.role == .assistant }
        #expect(storedMessages.count == 3)
        #expect(storedMessages.map(\.role) == [.user, .assistant, .error])
        #expect(assistantMessage?.content == "第一段回复")

        let errorMessage = try #require(storedMessages.last)
        #expect(errorMessage.role == .error)
        #expect(errorMessage.content.contains("HTTP 504"))
        #expect(errorMessage.content.contains("504 Gateway Time-out"))
        #expect(errorMessage.content.contains("响应已截断"))
        #expect(errorMessage.fullErrorContent?.contains("HTTP 504") == true)
        #expect(errorMessage.fullErrorContent?.contains(longTail) == true)
    }

    @MainActor
    @Test("流式输出期间编辑历史用户消息不会被后续分片覆盖")
    func testEditingUserMessageDuringStreamingIsPreserved() async throws {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            replaceProviders(with: originalProviders)
        }

        let provider = Provider(
            name: "Streaming Edit Test Provider",
            baseURL: "https://example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
            ]
        )
        replaceProviders(with: [provider])

        ControlledStreamingURLProtocol.reset()
        ControlledStreamingURLProtocol.register(marker: "edit-me", chunks: ["第一段\n", "第二段\n"])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ControlledStreamingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let service = ChatService(
            adapters: ["openai-compatible": StreamingFailureMockAdapter()],
            memoryManager: MemoryManager(),
            urlSession: session
        )
        service.setSelectedModel(service.activatedRunnableModels.first)

        let testSession = service.createSavedSession(name: "流式编辑保留")
        defer {
            service.deleteSessions([testSession])
            ControlledStreamingURLProtocol.reset()
        }
        service.setCurrentSession(testSession)

        let task = Task {
            await service.sendAndProcessMessage(
                content: "edit-me",
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
        }

        try await waitUntil("流式第一段已发布") {
            service.messagesForSessionSubject.value.contains { message in
                message.role == .assistant && message.content == "第一段"
            }
        }

        let userMessage = try #require(service.messagesForSessionSubject.value.first(where: { $0.role == .user }))
        var editedUserMessage = userMessage
        editedUserMessage.content = "已编辑的用户消息"
        service.updateMessage(editedUserMessage)

        ControlledStreamingURLProtocol.releaseNext(marker: "edit-me")
        await task.value

        let runtimeMessages = service.messagesForSessionSubject.value
        #expect(runtimeMessages.first(where: { $0.id == userMessage.id })?.content == "已编辑的用户消息")
        #expect(runtimeMessages.last(where: { $0.role == .assistant })?.content == "第一段第二段")

        let storedMessages = Persistence.loadMessages(for: testSession.id)
        #expect(storedMessages.first(where: { $0.id == userMessage.id })?.content == "已编辑的用户消息")
        #expect(storedMessages.last(where: { $0.role == .assistant })?.content == "第一段第二段")
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

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () -> Bool
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

final class ConcurrentSessionMockAdapter: APIAdapter {
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

private final class StreamingTrailingProxyErrorMockAdapter: APIAdapter {
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
        var components = URLComponents(string: "https://example.com/proxy-stream")
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
        guard line.hasPrefix("delta:") else { return nil }
        let content = String(line.dropFirst("delta:".count))
        return ChatMessagePart(content: content)
    }
}

private final class StreamingTrailingProxyErrorURLProtocol: URLProtocol {
    private struct RegisteredScenario {
        let chunks: [Data]
        let finishError: Error?
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

    static func register(marker: String, chunks: [String], finishErrorMessage: String? = nil) {
        let finishError = finishErrorMessage.map {
            NSError(
                domain: "StreamingTrailingProxyErrorURLProtocol",
                code: -1005,
                userInfo: [NSLocalizedDescriptionKey: $0]
            )
        }
        lock.lock()
        registeredScenarios[marker] = RegisteredScenario(
            chunks: chunks.map { Data($0.utf8) },
            finishError: finishError
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
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
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

            if let finishError = scenario.finishError {
                self.client?.urlProtocol(self, didFailWithError: finishError)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
    }

    private func failWithError(message: String) {
        let error = NSError(
            domain: "StreamingTrailingProxyErrorURLProtocol",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class ControlledStreamingURLProtocol: URLProtocol {
    private struct RegisteredScenario {
        let gates: [DispatchSemaphore]
        let chunks: [Data]
        var started: Bool
    }

    private static let lock = NSLock()
    private static var registeredScenarios: [String: RegisteredScenario] = [:]

    private var activeMarker: String?
    private let stateLock = NSLock()
    private var isStopped = false

    static func reset() {
        lock.lock()
        let scenarios = Array(registeredScenarios.values)
        registeredScenarios.removeAll()
        lock.unlock()
        for scenario in scenarios {
            for gate in scenario.gates {
                gate.signal()
            }
        }
    }

    static func register(marker: String, chunks: [String]) {
        lock.lock()
        registeredScenarios[marker] = RegisteredScenario(
            gates: chunks.dropFirst().map { _ in DispatchSemaphore(value: 0) },
            chunks: chunks.map { Data($0.utf8) },
            started: false
        )
        lock.unlock()
    }

    static func releaseNext(marker: String) {
        lock.lock()
        let gate = registeredScenarios[marker]?.gates.first
        lock.unlock()
        gate?.signal()
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

        Self.lock.lock()
        if var scenario = Self.registeredScenarios[marker] {
            scenario.started = true
            Self.registeredScenarios[marker] = scenario
        }
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
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            for chunkIndex in scenario.chunks.indices {
                if chunkIndex > 0 {
                    scenario.gates[chunkIndex - 1].wait()
                }
                self.stateLock.lock()
                let stopped = self.isStopped
                self.stateLock.unlock()
                if stopped { return }
                self.client?.urlProtocol(self, didLoad: scenario.chunks[chunkIndex])
            }

            self.stateLock.lock()
            let stopped = self.isStopped
            self.stateLock.unlock()
            if stopped { return }

            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
        if let marker = activeMarker {
            Self.releaseNext(marker: marker)
        }
    }

    private func failWithError(message: String) {
        let error = NSError(
            domain: "ControlledStreamingURLProtocol",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }
}

final class ControlledSessionURLProtocol: URLProtocol {
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
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
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
