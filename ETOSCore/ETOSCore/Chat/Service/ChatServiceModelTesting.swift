// ============================================================================
// ChatServiceModelTesting.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供不写入聊天历史的模型连通性测试。
// ============================================================================

import Foundation

private struct ConnectivityProbeOutput {
    let responsePreview: String?
    let tokenUsage: MessageTokenUsage?

    init(responsePreview: String?, tokenUsage: MessageTokenUsage? = nil) {
        self.responsePreview = responsePreview
        self.tokenUsage = tokenUsage
    }
}

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
        case embedding
        case imageGeneration

        public var id: String { rawValue }

        public var localizedName: String {
            switch self {
            case .nonStreaming:
                return NSLocalizedString("非流式", comment: "Single model connectivity test kind")
            case .streaming:
                return NSLocalizedString("流式", comment: "Single model connectivity test kind")
            case .toolCalling:
                return NSLocalizedString("工具调用", comment: "Single model connectivity test kind")
            case .embedding:
                return NSLocalizedString("嵌入", comment: "Single model connectivity test kind")
            case .imageGeneration:
                return NSLocalizedString("图片生成", comment: "Single model connectivity test kind")
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
            .filter { $0.isActivated && ModelKind.allCases.contains($0.kind) }
            .map { RunnableModel(provider: provider, model: $0) }
    }

    public func testModelConnectivity(
        for runnableModel: RunnableModel
    ) async -> ModelConnectivityTestResult {
        let singleResult: SingleModelConnectivityTestResult
        switch runnableModel.model.kind {
        case .chat:
            singleResult = await testSingleModelNonStreamingConnectivity(for: runnableModel)
        case .embedding:
            singleResult = await testSingleModelEmbeddingConnectivity(for: runnableModel)
        case .image:
            singleResult = await testSingleModelImageGenerationConnectivity(for: runnableModel)
        case .rerank, .textToSpeech:
            singleResult = SingleModelConnectivityTestResult(
                kind: .nonStreaming,
                status: .failed,
                errorMessage: SingleModelConnectivityTestError.unsupportedModelKind.localizedDescription
            )
        }
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

    public func testSingleModelEmbeddingConnectivity(
        for runnableModel: RunnableModel
    ) async -> SingleModelConnectivityTestResult {
        await runConnectivityProbe(
            kind: .embedding,
            runnableModel: runnableModel,
            isStreaming: false
        ) { adapter in
            guard runnableModel.model.kind == .embedding else {
                throw SingleModelConnectivityTestError.unsupportedModelKind
            }
            guard let request = adapter.buildEmbeddingRequest(
                for: runnableModel,
                texts: [NSLocalizedString("用于验证嵌入接口的测试文本。", comment: "Model embedding connectivity test input")]
            ) else {
                throw SingleModelConnectivityTestError.buildRequestFailed(.embedding)
            }

            let data = try await self.fetchData(for: request, provider: runnableModel.provider)
            let vectors = try adapter.parseEmbeddingResponse(data: data)
            guard let firstVector = vectors.first,
                  !firstVector.isEmpty,
                  vectors.allSatisfy({ vector in
                      vector.count == firstVector.count && vector.allSatisfy(\.isFinite)
                  }) else {
                throw SingleModelConnectivityTestError.emptyEmbeddingResponse
            }
            return ConnectivityProbeOutput(
                responsePreview: String(
                    format: NSLocalizedString("返回 %d 个向量，维度 %d。", comment: "Model embedding connectivity test preview"),
                    vectors.count,
                    firstVector.count
                )
            )
        }
    }

    public func testSingleModelImageGenerationConnectivity(
        for runnableModel: RunnableModel
    ) async -> SingleModelConnectivityTestResult {
        await runConnectivityProbe(
            kind: .imageGeneration,
            runnableModel: runnableModel,
            isStreaming: false
        ) { adapter in
            guard runnableModel.model.kind == .image else {
                throw SingleModelConnectivityTestError.unsupportedModelKind
            }
            guard let request = adapter.buildImageGenerationRequest(
                for: runnableModel,
                prompt: NSLocalizedString("生成一个纯白背景上的简单黑色方块。", comment: "Model image connectivity test prompt"),
                referenceImages: []
            ) else {
                throw SingleModelConnectivityTestError.buildRequestFailed(.imageGeneration)
            }

            let data = try await self.fetchData(for: request, provider: runnableModel.provider)
            let images = try adapter.parseImageGenerationResponse(data: data)
            let validImages = images.filter { image in
                image.data?.isEmpty == false || image.remoteURL != nil
            }
            guard !validImages.isEmpty else {
                throw SingleModelConnectivityTestError.emptyImageResponse
            }
            return ConnectivityProbeOutput(
                responsePreview: String(
                    format: NSLocalizedString("返回 %d 张图片。", comment: "Model image connectivity test preview"),
                    validImages.count
                )
            )
        }
    }

    private func runSingleModelConnectivityTest(
        kind: SingleModelConnectivityTestResult.Kind,
        runnableModel: RunnableModel,
        isStreaming: Bool,
        tools: [InternalToolDefinition]?,
        prompt: String,
        responsePreview: ((ChatMessage) throws -> String?)? = nil
    ) async -> SingleModelConnectivityTestResult {
        await runConnectivityProbe(
            kind: kind,
            runnableModel: runnableModel,
            isStreaming: isStreaming
        ) { adapter in
            guard runnableModel.model.isChatModel else {
                throw SingleModelConnectivityTestError.unsupportedModelKind
            }

            let request = try await self.connectivityTestRequest(
                for: runnableModel,
                adapter: adapter,
                isStreaming: isStreaming,
                tools: tools,
                prompt: prompt
            )

            let responseMessage: ChatMessage
            if isStreaming {
                responseMessage = try await self.performStreamingConnectivityRequest(
                    request,
                    provider: runnableModel.provider,
                    adapter: adapter,
                    availableTools: tools
                )
            } else {
                let data = try await self.fetchData(for: request, provider: runnableModel.provider)
                responseMessage = try adapter.parseResponse(data: data)
            }
            try Self.validateConnectivityResponse(responseMessage)

            return ConnectivityProbeOutput(
                responsePreview: try responsePreview?(responseMessage)
                    ?? Self.trimmedConnectivityPreview(responseMessage.content),
                tokenUsage: responseMessage.tokenUsage
            )
        }
    }

    private func runConnectivityProbe(
        kind: SingleModelConnectivityTestResult.Kind,
        runnableModel: RunnableModel,
        isStreaming: Bool,
        operation: (APIAdapter) async throws -> ConnectivityProbeOutput
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
            let adapter = try connectivityTestAdapter(for: runnableModel)
            try validateConnectivityTestProvider(runnableModel.provider)
            let output = try await operation(adapter)

            result.status = .succeeded
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.responsePreview = output.responsePreview
            persistRequestLog(
                context: requestContext,
                status: .success,
                tokenUsage: output.tokenUsage,
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
        guard let adapter = adapters[runnableModel.effectiveAPIFormat] else {
            throw NetworkError.adapterNotFound(format: runnableModel.effectiveAPIFormat)
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
    ) async throws -> URLRequest {
        let messages = [
            ChatMessage(role: .user, content: prompt)
        ]
        var payload: [String: Any] = ["stream": isStreaming]
        payload[ReasoningContentEchoPayload.key] = await openAIReasoningContentEchoModeControlValue()
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
        let responseMessageID = UUID()
        var content = ""
        var reasoningContent: String?
        var tokenUsage: MessageTokenUsage?
        var toolCallBuilders: [Int: (id: String?, name: String?, arguments: String, providerSpecificFields: [String: JSONValue]?)] = [:]
        var toolCallOrder: [Int] = []
        var toolCallIndexByID: [String: Int] = [:]
        var parsedEventCount = 0
        var streamTermination: ChatMessagePart.StreamTermination?

        for try await line in bytes.lines {
            guard let part = adapter.parseStreamingResponse(line: line) else { continue }
            if part.content != nil
                || part.reasoningContent != nil
                || part.reasoningProviderSpecificFields != nil
                || part.providerResponseMetadata != nil
                || part.toolCallDeltas != nil
                || part.tokenUsage != nil {
                parsedEventCount += 1
            }
            if let incomingTermination = part.streamTermination {
                switch incomingTermination {
                case .completed:
                    if streamTermination == nil {
                        streamTermination = .completed
                    }
                case .failed:
                    streamTermination = incomingTermination
                }
            }
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
                    if let argumentsReplacement = delta.argumentsReplacement {
                        builder.arguments = argumentsReplacement
                    } else if let argsFragment = delta.argumentsFragment, !argsFragment.isEmpty {
                        builder.arguments += argsFragment
                    }
                    if let providerSpecificFields = delta.providerSpecificFields, !providerSpecificFields.isEmpty {
                        builder.providerSpecificFields = mergeProviderResponseMetadata(
                            existing: builder.providerSpecificFields,
                            incoming: providerSpecificFields
                        )
                    }
                    toolCallBuilders[resolvedIndex] = builder
                    if !toolCallOrder.contains(resolvedIndex) {
                        toolCallOrder.append(resolvedIndex)
                    }
                }
            }
        }

        if case .failed(let reason) = streamTermination {
            let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedReason = trimmedReason.flatMap { $0.isEmpty ? nil : $0 }
                ?? URLError(.badServerResponse).localizedDescription
            throw NSError(
                domain: "StreamingResponse",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: resolvedReason
                ]
            )
        }
        if adapter.requiresExplicitStreamingTermination,
           streamTermination != .completed {
            throw URLError(.networkConnectionLost)
        }

        guard parsedEventCount > 0 else {
            throw SingleModelConnectivityTestError.invalidStreamingResponse
        }

        let toolCalls = toolCallOrder.compactMap { orderIdx -> InternalToolCall? in
            guard let builder = toolCallBuilders[orderIdx], let name = builder.name else { return nil }
            let resolvedName = resolveToolName(name, availableTools: availableTools ?? [])
            return InternalToolCall(
                id: builder.id ?? "tool-\(responseMessageID.uuidString)-\(orderIdx)",
                toolName: resolvedName,
                arguments: builder.arguments,
                providerSpecificFields: builder.providerSpecificFields
            )
        }

        return ChatMessage(
            id: responseMessageID,
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

    private static func validateConnectivityResponse(_ message: ChatMessage) throws {
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasToolCall = message.toolCalls?.isEmpty == false
        guard hasContent || hasReasoning || hasToolCall else {
            throw SingleModelConnectivityTestError.emptyChatResponse
        }
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
    case buildRequestFailed(SingleModelConnectivityTestResult.Kind)
    case emptyChatResponse
    case invalidStreamingResponse
    case emptyEmbeddingResponse
    case emptyImageResponse
    case toolCallMissing(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModelKind:
            return NSLocalizedString("当前模型用途不支持此测试。", comment: "Single model connectivity unsupported kind")
        case .buildRequestFailed(let kind):
            return String(
                format: NSLocalizedString("当前适配器无法构建“%@”测试请求。", comment: "Model connectivity request build failed"),
                kind.localizedName
            )
        case .emptyChatResponse:
            return NSLocalizedString("上游返回了成功状态，但响应中没有有效内容。", comment: "Model connectivity empty chat response")
        case .invalidStreamingResponse:
            return NSLocalizedString("上游返回了成功状态，但没有可解析的流式事件。", comment: "Model connectivity invalid streaming response")
        case .emptyEmbeddingResponse:
            return NSLocalizedString("上游返回了成功状态，但没有有效的嵌入向量。", comment: "Model connectivity empty embedding response")
        case .emptyImageResponse:
            return NSLocalizedString("上游返回了成功状态，但没有有效的图片结果。", comment: "Model connectivity empty image response")
        case .toolCallMissing(let response):
            return String(
                format: NSLocalizedString("模型没有返回工具调用。响应：%@", comment: "Single model tool calling missing call"),
                response
            )
        }
    }
}
