// ============================================================================
// GuideCompletionClients.swift
// ============================================================================
// ETOS LLM Studio
//
// 内置免费线路与用户自有模型线路共同实现内存向导传输协议。
// ============================================================================

import Foundation

public final class GuideUserModelCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let chatService: ChatService
    private let runnableModel: RunnableModel

    public init(chatService: ChatService = .shared, runnableModel: RunnableModel) {
        self.chatService = chatService
        self.runnableModel = runnableModel
    }

    public func events(
        messages: [ChatMessage],
        tools: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [chatService, runnableModel] in
                do {
                    let response = try await chatService.generateGuideChatCompletion(
                        messages: messages,
                        tools: tools,
                        runnableModel: runnableModel
                    ) { delta in
                        continuation.yield(.contentDelta(delta))
                    }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

public actor GuideEphemeralTokenProvider {
    private struct Response: Decodable {
        let token: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    private let baseURL: URL
    private let urlSession: URLSession
    private var cachedToken: Response?

    public init(
        baseURL: URL = FeedbackServiceConfig.default.baseURL,
        urlSession: URLSession = NetworkSessionConfiguration.shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func token() async throws -> String {
        if let cachedToken, cachedToken.expiresAt.timeIntervalSinceNow > 5 {
            return cachedToken.token
        }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1").appendingPathComponent("guide").appendingPathComponent("token")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Response.self, from: data)
        cachedToken = decoded
        return decoded.token
    }

    public func invalidate() {
        cachedToken = nil
    }
}

private struct GuideHTTPStatusError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 401:
            return NSLocalizedString("内置向导临时令牌已失效。", comment: "向导临时令牌错误")
        case 429:
            return NSLocalizedString("当前网络已有向导请求正在生成，请稍后再试。", comment: "向导并发限制错误")
        default:
            return NSLocalizedString("内置向导服务暂时不可用。", comment: "向导服务状态错误")
        }
    }
}

public final class GuideBuiltInCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let baseURL: URL
    private let urlSession: URLSession
    private let tokenProvider: GuideEphemeralTokenProvider
    private let adapter = OpenAIAdapter()

    public init(
        baseURL: URL = FeedbackServiceConfig.default.baseURL,
        urlSession: URLSession = NetworkSessionConfiguration.shared,
        tokenProvider: GuideEphemeralTokenProvider? = nil
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider ?? GuideEphemeralTokenProvider(baseURL: baseURL, urlSession: urlSession)
    }

    public func events(
        messages: [ChatMessage],
        tools: [InternalToolDefinition],
        sessionID: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let run: (String) async throws -> ChatMessage = { token in
                        let request = try self.makeRequest(
                            messages: messages,
                            tools: tools,
                            sessionID: sessionID,
                            token: token
                        )
                        return try await self.consumeStream(request, tools: tools) { delta in
                            continuation.yield(.contentDelta(delta))
                        }
                    }
                    let response: ChatMessage
                    do {
                        response = try await run(tokenProvider.token())
                    } catch let error as GuideHTTPStatusError where error.statusCode == 401 {
                        await tokenProvider.invalidate()
                        response = try await run(tokenProvider.token())
                    }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeRequest(
        messages: [ChatMessage],
        tools: [InternalToolDefinition],
        sessionID: UUID,
        token: String
    ) throws -> URLRequest {
        var payload: [String: Any] = [
            "model": "built-in-guide",
            "stream": true,
            "messages": messages.flatMap(openAIMessages(from:))
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.toAny()
                    ]
                ]
            }
            payload["tool_choice"] = "auto"
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID.uuidString.lowercased(), forHTTPHeaderField: "X-Guide-Session-ID")
        return request
    }

    private func openAIMessages(from message: ChatMessage) -> [[String: Any]] {
        switch message.role {
        case .system, .user:
            return [["role": message.role.rawValue, "content": message.content]]
        case .assistant:
            var value: [String: Any] = ["role": "assistant", "content": message.content]
            if let calls = message.toolCalls, !calls.isEmpty {
                value["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.toolName, "arguments": call.arguments]
                    ]
                }
            }
            return [value]
        case .tool:
            return (message.toolCalls ?? []).map { call in
                [
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": call.result ?? message.content
                ]
            }
        case .error:
            return [["role": "user", "content": message.content]]
        }
    }

    private func consumeStream(
        _ request: URLRequest,
        tools: [InternalToolDefinition],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ChatMessage {
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GuideHTTPStatusError(statusCode: httpResponse.statusCode)
        }

        let responseID = UUID()
        var content = ""
        var reasoning: String?
        var builders: [Int: (id: String?, name: String?, arguments: String)] = [:]
        var order: [Int] = []
        var indexByID: [String: Int] = [:]
        var didComplete = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let part = adapter.parseStreamingResponse(line: line) else { continue }
            if part.streamTermination == .completed { didComplete = true }
            if case .failed(let reason) = part.streamTermination {
                throw NSError(
                    domain: "GuideBuiltInStream",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: reason ?? URLError(.badServerResponse).localizedDescription]
                )
            }
            if let delta = part.content, !delta.isEmpty {
                content += delta
                await onDelta(delta)
            }
            if let delta = part.reasoningContent {
                reasoning = (reasoning ?? "") + delta
            }
            for delta in part.toolCallDeltas ?? [] {
                let index: Int
                if let id = delta.id, let existing = indexByID[id] {
                    index = existing
                } else if let explicit = delta.index {
                    index = explicit
                    if let id = delta.id { indexByID[id] = explicit }
                } else {
                    index = (order.last ?? -1) + 1
                    if let id = delta.id { indexByID[id] = index }
                }
                var builder = builders[index] ?? (nil, nil, "")
                if let id = delta.id { builder.id = id }
                if let name = delta.nameFragment, !name.isEmpty { builder.name = name }
                if let replacement = delta.argumentsReplacement {
                    builder.arguments = replacement
                } else if let fragment = delta.argumentsFragment {
                    builder.arguments += fragment
                }
                builders[index] = builder
                if !order.contains(index) { order.append(index) }
            }
        }
        guard didComplete else { throw URLError(.networkConnectionLost) }
        let toolNames = Set(tools.map(\.name))
        let calls = order.compactMap { index -> InternalToolCall? in
            guard let builder = builders[index], let name = builder.name, toolNames.contains(name) else { return nil }
            return InternalToolCall(
                id: builder.id ?? "guide-tool-\(responseID.uuidString)-\(index)",
                toolName: name,
                arguments: builder.arguments
            )
        }
        return ChatMessage(
            id: responseID,
            role: .assistant,
            content: content,
            reasoningContent: reasoning,
            toolCalls: calls.isEmpty ? nil : calls
        )
    }
}
