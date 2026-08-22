// ============================================================================
// ChatServiceGuideCompletion.swift
// ============================================================================
// ETOS LLM Studio
//
// 复用现有提供商适配器执行向导请求，但不创建会话、不落消息、不写请求日志。
// ============================================================================

import Foundation

extension ChatService {
    public func generateGuideChatCompletion(
        messages: [ChatMessage],
        tools: [InternalToolDefinition],
        runnableModel: RunnableModel,
        onContentDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ChatMessage {
        guard !LocalModelProviderBridge.isLocalRunnableModel(runnableModel),
              let adapter = adapters[runnableModel.effectiveAPIFormat] else {
            throw GuideError.missingRunnableModel
        }

        var payload: [String: Any] = [
            "stream": true,
            requestLogSuppressionControlKey: true
        ]
        if !tools.isEmpty {
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
        return try await parseGuideStream(
            request: request,
            provider: runnableModel.provider,
            adapter: adapter,
            tools: tools,
            onContentDelta: onContentDelta
        )
    }

    private func parseGuideStream(
        request: URLRequest,
        provider: Provider,
        adapter: APIAdapter,
        tools: [InternalToolDefinition],
        onContentDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ChatMessage {
        let bytes = try await streamData(for: request, provider: provider)
        let responseMessageID = UUID()
        var content = ""
        var reasoningContent: String?
        var tokenUsage: MessageTokenUsage?
        var builders: [Int: (id: String?, name: String?, arguments: String, fields: [String: JSONValue]?)] = [:]
        var order: [Int] = []
        var indexByID: [String: Int] = [:]
        var parsedEvents = 0
        var termination: ChatMessagePart.StreamTermination?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let part = adapter.parseStreamingResponse(line: line) else { continue }
            if part.content != nil || part.reasoningContent != nil || part.toolCallDeltas != nil || part.tokenUsage != nil {
                parsedEvents += 1
            }
            if let incoming = part.streamTermination {
                if case .failed = incoming {
                    termination = incoming
                } else if termination == nil {
                    termination = incoming
                }
            }
            if let usage = part.tokenUsage {
                tokenUsage = mergeTokenUsage(existing: tokenUsage, incoming: usage)
            }
            if let delta = part.content, !delta.isEmpty {
                content += delta
                await onContentDelta(delta)
            }
            if let delta = part.reasoningContent {
                reasoningContent = (reasoningContent ?? "") + delta
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

                var builder = builders[index] ?? (nil, nil, "", nil)
                if let id = delta.id { builder.id = id }
                if let name = delta.nameFragment, !name.isEmpty { builder.name = name }
                if let replacement = delta.argumentsReplacement {
                    builder.arguments = replacement
                } else if let fragment = delta.argumentsFragment {
                    builder.arguments += fragment
                }
                if let fields = delta.providerSpecificFields {
                    builder.fields = mergeProviderResponseMetadata(existing: builder.fields, incoming: fields)
                }
                builders[index] = builder
                if !order.contains(index) { order.append(index) }
            }
        }

        if case .failed(let reason) = termination {
            throw NSError(
                domain: "GuideStreamingResponse",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: reason ?? URLError(.badServerResponse).localizedDescription]
            )
        }
        if adapter.requiresExplicitStreamingTermination, termination != .completed {
            throw URLError(.networkConnectionLost)
        }
        guard parsedEvents > 0 else { throw GuideError.invalidResponse }

        let calls = order.compactMap { index -> InternalToolCall? in
            guard let builder = builders[index], let name = builder.name else { return nil }
            return InternalToolCall(
                id: builder.id ?? "guide-tool-\(responseMessageID.uuidString)-\(index)",
                toolName: resolveToolName(name, availableTools: tools),
                arguments: builder.arguments,
                providerSpecificFields: builder.fields
            )
        }
        return ChatMessage(
            id: responseMessageID,
            role: .assistant,
            content: content,
            reasoningContent: reasoningContent,
            toolCalls: calls.isEmpty ? nil : calls,
            tokenUsage: tokenUsage
        )
    }
}
