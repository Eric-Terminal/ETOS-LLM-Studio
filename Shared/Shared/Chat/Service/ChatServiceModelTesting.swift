// ============================================================================
// ChatServiceModelTesting.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供不写入聊天历史的模型连通性测试。
// ============================================================================

import Foundation

public struct ModelConnectivityTestResult: Identifiable, Sendable {
    public enum Status: Sendable, Equatable {
        case pending
        case testing
        case succeeded
        case failed
    }

    public let id: String
    public let providerID: UUID
    public let providerName: String
    public let modelID: UUID
    public let modelName: String
    public let displayName: String
    public var status: Status
    public var latencyMilliseconds: Int?
    public var responsePreview: String?
    public var errorMessage: String?

    public init(
        runnableModel: RunnableModel,
        status: Status = .pending,
        latencyMilliseconds: Int? = nil,
        responsePreview: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = runnableModel.id
        self.providerID = runnableModel.provider.id
        self.providerName = runnableModel.provider.name
        self.modelID = runnableModel.model.id
        self.modelName = runnableModel.model.modelName
        self.displayName = runnableModel.model.displayName
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.responsePreview = responsePreview
        self.errorMessage = errorMessage
    }
}

public struct SingleModelConnectivityTestResult: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case nonStreaming
        case streaming
        case toolCalling

        public var id: String { rawValue }

        public var localizedName: String {
            switch self {
            case .nonStreaming:
                return NSLocalizedString("非流式", comment: "Single model connectivity test kind")
            case .streaming:
                return NSLocalizedString("流式", comment: "Single model connectivity test kind")
            case .toolCalling:
                return NSLocalizedString("工具调用", comment: "Single model connectivity test kind")
            }
        }
    }

    public let kind: Kind
    public var id: String { kind.rawValue }
    public var status: ModelConnectivityTestResult.Status
    public var latencyMilliseconds: Int?
    public var responsePreview: String?
    public var errorMessage: String?

    public init(
        kind: Kind,
        status: ModelConnectivityTestResult.Status = .pending,
        latencyMilliseconds: Int? = nil,
        responsePreview: String? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.responsePreview = responsePreview
        self.errorMessage = errorMessage
    }
}

public extension ModelConnectivityTestResult.Status {
    var localizedName: String {
        switch self {
        case .pending:
            return NSLocalizedString("等待测试", comment: "Model connectivity test status")
        case .testing:
            return NSLocalizedString("测试中", comment: "Model connectivity test status")
        case .succeeded:
            return NSLocalizedString("可用", comment: "Model connectivity test status")
        case .failed:
            return NSLocalizedString("不可用", comment: "Model connectivity test status")
        }
    }
}

extension ChatService {
    public func connectivityTestCandidates(for provider: Provider) -> [RunnableModel] {
        provider.models
            .filter { $0.isActivated && $0.isChatModel }
            .map { RunnableModel(provider: provider, model: $0) }
    }

    public func testModelConnectivity(
        for runnableModel: RunnableModel
    ) async -> ModelConnectivityTestResult {
        let singleResult = await testSingleModelNonStreamingConnectivity(for: runnableModel)
        return ModelConnectivityTestResult(
            runnableModel: runnableModel,
            status: singleResult.status,
            latencyMilliseconds: singleResult.latencyMilliseconds,
            responsePreview: singleResult.responsePreview,
            errorMessage: singleResult.errorMessage
        )
    }

    public func testSingleModelNonStreamingConnectivity(
        for runnableModel: RunnableModel
    ) async -> SingleModelConnectivityTestResult {
        await runSingleModelConnectivityTest(
            kind: .nonStreaming,
            runnableModel: runnableModel,
            isStreaming: false,
            tools: nil,
            prompt: NSLocalizedString("请只回复 OK。", comment: "Model connectivity test prompt")
        )
    }

    public func testSingleModelToolCallingConnectivity(
        for runnableModel: RunnableModel
    ) async -> SingleModelConnectivityTestResult {
        guard runnableModel.model.supportsToolCalling else {
            return SingleModelConnectivityTestResult(
                kind: .toolCalling,
                status: .failed,
                errorMessage: NSLocalizedString("当前模型未开启“可调用工具”能力。", comment: "Single model tool calling test disabled")
            )
        }

        let tool = InternalToolDefinition(
            name: AppToolKind.getSystemTime.toolName,
            description: AppToolKind.getSystemTime.summary,
            parameters: AppToolKind.getSystemTime.parameters,
            isBlocking: true
        )

        return await runSingleModelConnectivityTest(
            kind: .toolCalling,
            runnableModel: runnableModel,
            isStreaming: false,
            tools: [tool],
            prompt: NSLocalizedString("请调用 app_get_system_time 工具获取当前设备时间，不要直接回答。", comment: "Single model tool calling test prompt")
        ) { message in
            guard let toolCall = message.toolCalls?.first(where: { $0.toolName == AppToolKind.getSystemTime.toolName }) else {
                let fallback = Self.trimmedConnectivityPreview(message.content) ?? NSLocalizedString("模型没有返回工具调用。", comment: "Single model tool calling missing call")
                throw SingleModelConnectivityTestError.toolCallMissing(fallback)
            }
            let arguments = toolCall.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if arguments.isEmpty || arguments == "{}" {
                return String(format: NSLocalizedString("调用：%@", comment: "Single model tool call preview"), toolCall.toolName)
            }
            return String(
                format: NSLocalizedString("调用：%@，参数：%@", comment: "Single model tool call preview with arguments"),
                toolCall.toolName,
                arguments
            )
        }
    }

    public func testSingleModelStreamingConnectivity(
        for runnableModel: RunnableModel
    ) async -> SingleModelConnectivityTestResult {
        await runSingleModelConnectivityTest(
            kind: .streaming,
            runnableModel: runnableModel,
            isStreaming: true,
            tools: nil,
            prompt: NSLocalizedString("请只回复 OK。", comment: "Model connectivity test prompt")
        )
    }

    private func runSingleModelConnectivityTest(
        kind: SingleModelConnectivityTestResult.Kind,
        runnableModel: RunnableModel,
        isStreaming: Bool,
        tools: [InternalToolDefinition]?,
        prompt: String,
        responsePreview: ((ChatMessage) throws -> String?)? = nil
    ) async -> SingleModelConnectivityTestResult {
        var result = SingleModelConnectivityTestResult(kind: kind, status: .testing)
        let startedAt = Date()
        let requestContext = RequestLogContext(
            requestID: UUID(),
            sessionID: nil,
            providerID: runnableModel.provider.id,
            providerName: runnableModel.provider.name,
            modelID: runnableModel.model.modelName,
            requestSource: .modelTest,
            isStreaming: isStreaming,
            requestedAt: startedAt
        )

        do {
            guard runnableModel.model.isChatModel else {
                throw SingleModelConnectivityTestError.unsupportedModelKind
            }
            let adapter = try connectivityTestAdapter(for: runnableModel)
            try validateConnectivityTestProvider(runnableModel.provider)

            let request = try connectivityTestRequest(
                for: runnableModel,
                adapter: adapter,
                isStreaming: isStreaming,
                tools: tools,
                prompt: prompt
            )

            let responseMessage: ChatMessage
            if isStreaming {
                responseMessage = try await performStreamingConnectivityRequest(
                    request,
                    provider: runnableModel.provider,
                    adapter: adapter,
                    availableTools: tools
                )
            } else {
                let data = try await fetchData(for: request, provider: runnableModel.provider)
                responseMessage = try adapter.parseResponse(data: data)
            }

            result.status = .succeeded
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.responsePreview = try responsePreview?(responseMessage)
                ?? Self.trimmedConnectivityPreview(responseMessage.content)
            persistRequestLog(
                context: requestContext,
                status: .success,
                tokenUsage: responseMessage.tokenUsage,
                finishedAt: Date()
            )
        } catch let error where isCancellationError(error) || Task.isCancelled {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = NSLocalizedString("测试已取消。", comment: "Model connectivity test cancelled")
            persistRequestLog(
                context: requestContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = NetworkError.badStatusCode(code: code, responseBody: bodyData).localizedDescription
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
        } catch {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = error.localizedDescription
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "model_test_failed"
            )
        }

        return result
    }

    private func connectivityTestAdapter(for runnableModel: RunnableModel) throws -> APIAdapter {
        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: runnableModel.provider.apiFormat)
        }
        return adapter
    }

    private func validateConnectivityTestProvider(_ provider: Provider) throws {
        if let configurationError = providerConfigurationValidationErrorMessage(
            for: provider,
            action: NSLocalizedString("测试模型连通性", comment: "Model connectivity test action")
        ) {
            throw NetworkError.invalidProviderConfiguration(message: configurationError)
        }
    }

    private func connectivityTestRequest(
        for runnableModel: RunnableModel,
        adapter: APIAdapter,
        isStreaming: Bool,
        tools: [InternalToolDefinition]?,
        prompt: String
    ) throws -> URLRequest {
        let messages = [
            ChatMessage(role: .user, content: prompt)
        ]
        var payload: [String: Any] = [
            "temperature": 0,
            "stream": isStreaming
        ]
        if tools?.isEmpty == false {
            payload["tool_choice"] = "auto"
        }
        guard let request = adapter.buildChatRequest(
            for: runnableModel,
            commonPayload: payload,
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ) else {
            throw DetachedCompletionError.buildRequestFailed
        }
        return request
    }

    private func performStreamingConnectivityRequest(
        _ request: URLRequest,
        provider: Provider,
        adapter: APIAdapter,
        availableTools: [InternalToolDefinition]?
    ) async throws -> ChatMessage {
        let bytes = try await streamData(for: request, provider: provider)
        var content = ""
        var reasoningContent: String?
        var tokenUsage: MessageTokenUsage?
        var toolCallBuilders: [Int: (id: String?, name: String?, arguments: String, providerSpecificFields: [String: JSONValue]?)] = [:]
        var toolCallOrder: [Int] = []
        var toolCallIndexByID: [String: Int] = [:]

        for try await line in bytes.lines {
            guard let part = adapter.parseStreamingResponse(line: line) else { continue }
            if let incomingUsage = part.tokenUsage {
                tokenUsage = mergeTokenUsage(existing: tokenUsage, incoming: incomingUsage)
            }
            if let contentPart = part.content {
                content += contentPart
            }
            if let reasoningPart = part.reasoningContent {
                if reasoningContent == nil { reasoningContent = "" }
                reasoningContent! += reasoningPart
            }
            if let toolDeltas = part.toolCallDeltas, !toolDeltas.isEmpty {
                for delta in toolDeltas {
                    let resolvedIndex: Int
                    if let id = delta.id, let existed = toolCallIndexByID[id] {
                        resolvedIndex = existed
                    } else if let explicitIndex = delta.index {
                        resolvedIndex = explicitIndex
                        if let id = delta.id {
                            toolCallIndexByID[id] = explicitIndex
                        }
                    } else {
                        resolvedIndex = (toolCallOrder.last ?? -1) + 1
                        if let id = delta.id {
                            toolCallIndexByID[id] = resolvedIndex
                        }
                    }

                    var builder = toolCallBuilders[resolvedIndex] ?? (id: nil, name: nil, arguments: "", providerSpecificFields: nil)
                    if let id = delta.id { builder.id = id }
                    if let nameFragment = delta.nameFragment, !nameFragment.isEmpty { builder.name = nameFragment }
                    if let argsFragment = delta.argumentsFragment, !argsFragment.isEmpty { builder.arguments += argsFragment }
                    if let providerSpecificFields = delta.providerSpecificFields, !providerSpecificFields.isEmpty {
                        builder.providerSpecificFields = providerSpecificFields
                    }
                    toolCallBuilders[resolvedIndex] = builder
                    if !toolCallOrder.contains(resolvedIndex) {
                        toolCallOrder.append(resolvedIndex)
                    }
                }
            }
        }

        let toolCalls = toolCallOrder.compactMap { orderIdx -> InternalToolCall? in
            guard let builder = toolCallBuilders[orderIdx], let name = builder.name else { return nil }
            let resolvedName = resolveToolName(name, availableTools: availableTools ?? [])
            return InternalToolCall(
                id: builder.id ?? "tool-\(orderIdx)",
                toolName: resolvedName,
                arguments: builder.arguments,
                providerSpecificFields: builder.providerSpecificFields
            )
        }

        return ChatMessage(
            role: .assistant,
            content: content,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            tokenUsage: tokenUsage
        )
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private static func trimmedConnectivityPreview(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 160 {
            return trimmed
        }
        return String(trimmed.prefix(160))
    }
}

private enum SingleModelConnectivityTestError: LocalizedError {
    case unsupportedModelKind
    case toolCallMissing(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModelKind:
            return NSLocalizedString("当前模型不是聊天模型，无法执行模型测试。", comment: "Single model connectivity unsupported kind")
        case .toolCallMissing(let response):
            return String(
                format: NSLocalizedString("模型没有返回工具调用。响应：%@", comment: "Single model tool calling missing call"),
                response
            )
        }
    }
}
