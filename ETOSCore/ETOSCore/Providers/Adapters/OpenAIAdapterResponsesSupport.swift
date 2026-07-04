// ============================================================================
// OpenAIAdapterResponsesSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// OpenAI Responses API 的输入构建、工具回填与响应解析辅助逻辑。
// ============================================================================

import Foundation

extension OpenAIAdapter {
    struct ResponsesInputAssembly {
        let items: [[String: Any]]
        let messageEndIndexes: [UUID: Int]
    }

    func buildResponsesMessageInput(
        for message: ChatMessage,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> [String: Any]? {
        guard message.role == .system || message.role == .user || message.role == .assistant else {
            return nil
        }

        let messageImageAttachments = imageAttachments[message.id] ?? []
        let messageFileAttachments = fileAttachments[message.id] ?? []
        let needsMultipart = !messageImageAttachments.isEmpty || !messageFileAttachments.isEmpty

        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needsMultipart {
            guard !message.content.isEmpty else { return nil }
            return [
                "type": "message",
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var content: [[String: Any]] = []
        if shouldSendText(trimmedContent) {
            content.append([
                "type": "input_text",
                "text": trimmedContent
            ])
        }

        for imageAttachment in messageImageAttachments {
            content.append([
                "type": "input_image",
                "image_url": imageAttachment.dataURL
            ])
        }

        for fileAttachment in messageFileAttachments {
            content.append([
                "type": "input_file",
                "file_data": fileAttachment.data.base64EncodedString(),
                "filename": fileAttachment.fileName
            ])
        }

        guard !content.isEmpty else { return nil }
        return [
            "type": "message",
            "role": message.role.rawValue,
            "content": content
        ]
    }

    func buildResponsesFunctionCallItem(from toolCall: InternalToolCall) -> [String: Any] {
        var item: [String: Any] = [
            "type": "function_call",
            "call_id": toolCall.id,
            "name": sanitizedToolName(toolCall.toolName),
            "arguments": toolCall.arguments,
            "status": "completed"
        ]
        if let rawItemID = toolCall.providerSpecificFields?[Self.responsesOutputItemIDKey],
           case let .string(itemID) = rawItemID,
           !itemID.isEmpty {
            item["id"] = itemID
        }
        if let rawStatus = toolCall.providerSpecificFields?[Self.responsesOutputItemStatusKey],
           case let .string(status) = rawStatus,
           !status.isEmpty {
            item["status"] = status
        }
        return item
    }

    func buildResponsesFunctionCallOutputItem(from message: ChatMessage) -> [String: Any]? {
        guard message.role == .tool, let callID = message.toolCalls?.first?.id else { return nil }
        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": message.content
        ]
    }

    static func reasoningContentEchoMode(from payload: [String: Any]) -> ReasoningContentEchoMode {
        resolvedReasoningContentEchoMode(from: payload, fallbackKey: reasoningContentEchoModeControlKey)
    }

    static func shouldEchoReasoningContent(for message: ChatMessage, mode: ReasoningContentEchoMode) -> Bool {
        shouldEchoReasoningMetadata(for: message, mode: mode)
    }

    func buildResponsesReasoningInputItems(from message: ChatMessage, mode: ReasoningContentEchoMode) -> [[String: Any]] {
        guard Self.shouldEchoReasoningContent(for: message, mode: mode) else { return [] }
        guard let rawItems = message.reasoningProviderSpecificFields?[Self.responsesReasoningItemsKey],
              case let .array(items) = rawItems else {
            return []
        }
        var result: [[String: Any]] = []
        var indexByID: [String: Int] = [:]
        for item in items {
            guard let dictionary = item.toAny() as? [String: Any],
                  dictionary["type"] as? String == "reasoning" else {
                continue
            }

            var reasoningItem = dictionary
            let summaryItems = reasoningItem["summary"] as? [[String: Any]]
            let hasSummaryText = summaryItems?.contains {
                (($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            } == true
            if !hasSummaryText,
               let reasoningContent = message.reasoningContent,
               !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasoningItem["summary"] = [
                    [
                        "type": "summary_text",
                        "text": reasoningContent
                    ]
                ]
            }

            if let id = reasoningItem["id"] as? String, let existingIndex = indexByID[id] {
                result[existingIndex] = reasoningItem
            } else {
                if let id = reasoningItem["id"] as? String {
                    indexByID[id] = result.count
                }
                result.append(reasoningItem)
            }
        }
        return result
    }

    func buildResponsesOutputInputItems(from message: ChatMessage, mode: ReasoningContentEchoMode) -> [[String: Any]] {
        guard message.role == .assistant,
              let rawItems = message.providerResponseMetadata?[Self.responsesOutputItemsKey],
              case let .array(items) = rawItems else {
            return []
        }

        var result: [[String: Any]] = []
        for item in items {
            guard let dictionary = item.toAny() as? [String: Any],
                  let type = dictionary["type"] as? String else {
                continue
            }
            if type == "reasoning", !Self.shouldEchoReasoningContent(for: message, mode: mode) {
                continue
            }
            result.append(dictionary)
        }
        return deduplicatedResponsesOutputItems(result)
    }

    func deduplicatedResponsesOutputItems(_ items: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var indexByKey: [String: Int] = [:]

        for item in items {
            let keys = responsesOutputItemMergeKeys(item)
            if !keys.isEmpty {
                if let existingIndex = keys.compactMap({ indexByKey[$0] }).first {
                    result[existingIndex] = item
                    for key in keys {
                        indexByKey[key] = existingIndex
                    }
                } else {
                    for key in keys {
                        indexByKey[key] = result.count
                    }
                    result.append(item)
                }
            } else {
                result.append(item)
            }
        }

        return result
    }

    func responsesOutputItemMergeKeys(_ item: [String: Any]) -> [String] {
        var keys: [String] = []
        if let id = item["id"] as? String, !id.isEmpty {
            keys.append("id:\(id)")
        }
        if let type = item["type"] as? String,
           let callID = item["call_id"] as? String,
           !callID.isEmpty {
            keys.append("\(type):\(callID)")
        }
        return keys
    }

    func responsesRequestSignature(from payload: [String: Any]) -> JSONValue? {
        var signaturePayload = payload
        signaturePayload.removeValue(forKey: "input")
        signaturePayload.removeValue(forKey: "previous_response_id")
        signaturePayload.removeValue(forKey: Self.responsesForceFullInputControlKey)
        return jsonValue(fromJSONObject: signaturePayload)
    }

    func responsesPreviousResponseID(from message: ChatMessage) -> String? {
        guard let rawValue = message.providerResponseMetadata?[Self.responsesResponseIDKey],
              case let .string(responseID) = rawValue,
              !responseID.isEmpty else {
            return nil
        }
        return responseID
    }

    func responsesRequestSignatureMatches(_ message: ChatMessage, signature: JSONValue) -> Bool {
        guard let storedSignature = message.providerResponseMetadata?[Self.responsesRequestSignatureKey] else {
            return false
        }
        return storedSignature == signature
    }

    func responsesIncrementalInput(
        assembly: ResponsesInputAssembly,
        messages: [ChatMessage],
        requestSignature: JSONValue
    ) -> (previousResponseID: String, inputItems: [[String: Any]])? {
        for message in messages.reversed() where message.role == .assistant {
            guard let previousResponseID = responsesPreviousResponseID(from: message),
                  responsesRequestSignatureMatches(message, signature: requestSignature),
                  let endIndex = assembly.messageEndIndexes[message.id],
                  endIndex < assembly.items.count else {
                continue
            }

            let incrementalItems = Array(assembly.items[endIndex...])
            guard !incrementalItems.isEmpty else { continue }
            return (previousResponseID, incrementalItems)
        }
        return nil
    }

    func buildResponsesInputItems(
        from messages: [ChatMessage],
        reasoningContentEchoMode: ReasoningContentEchoMode,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> [[String: Any]] {
        buildResponsesInputAssembly(
            from: messages,
            reasoningContentEchoMode: reasoningContentEchoMode,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        ).items
    }

    func buildResponsesInputAssembly(
        from messages: [ChatMessage],
        reasoningContentEchoMode: ReasoningContentEchoMode,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> ResponsesInputAssembly {
        var items: [[String: Any]] = []
        items.reserveCapacity(messages.count)
        var messageEndIndexes: [UUID: Int] = [:]

        for message in messages {
            let startIndex = items.count

            if message.role == .assistant {
                let outputItems = buildResponsesOutputInputItems(from: message, mode: reasoningContentEchoMode)
                if !outputItems.isEmpty {
                    items.append(contentsOf: outputItems)
                    messageEndIndexes[message.id] = items.count
                    continue
                }
            }

            if message.role == .assistant {
                items.append(contentsOf: buildResponsesReasoningInputItems(from: message, mode: reasoningContentEchoMode))
            }

            if let messageItem = buildResponsesMessageInput(
                for: message,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            ) {
                items.append(messageItem)
            }

            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                items.append(contentsOf: toolCalls.map { buildResponsesFunctionCallItem(from: $0) })
            } else if message.role == .tool, let outputItem = buildResponsesFunctionCallOutputItem(from: message) {
                items.append(outputItem)
            }

            if items.count > startIndex {
                messageEndIndexes[message.id] = items.count
            }
        }

        return ResponsesInputAssembly(items: items, messageEndIndexes: messageEndIndexes)
    }

    func makeResponsesToolChoicePayload(_ rawValue: Any?) -> Any? {
        if let toolChoice = rawValue as? [String: Any] {
            return toolChoice
        }
        if let rawString = rawValue as? String,
           let normalized = OpenAIResponsesToolChoice(rawString) {
            switch normalized {
            case .auto:
                return "auto"
            case .required:
                return "required"
            case .none:
                return "none"
            }
        }
        return nil
    }

    func parseResponsesTextContent(from content: [Any]) -> String {
        var segments: [String] = []
        for rawPart in content {
            guard let part = rawPart as? [String: Any],
                  let type = part["type"] as? String else { continue }
            switch type {
            case "output_text":
                if let text = part["text"] as? String, !text.isEmpty {
                    segments.append(text)
                }
            case "refusal":
                if let refusal = part["refusal"] as? String, !refusal.isEmpty {
                    segments.append(refusal)
                }
            default:
                continue
            }
        }
        return segments.joined()
    }

    func parseResponsesReasoningContent(from item: [String: Any]) -> String? {
        var reasoning: String? = nil

        if let content = item["content"] as? [Any] {
            for rawPart in content {
                guard let part = rawPart as? [String: Any],
                      let type = part["type"] as? String else { continue }
                switch type {
                case "reasoning_text", "summary_text":
                    if let text = part["text"] as? String {
                        appendSegment(text, to: &reasoning)
                    }
                default:
                    continue
                }
            }
        }

        if let summary = item["summary"] as? [Any] {
            for rawPart in summary {
                guard let part = rawPart as? [String: Any],
                      let type = part["type"] as? String,
                      type == "summary_text",
                      let text = part["text"] as? String else { continue }
                appendSegment(text, to: &reasoning)
            }
        }

        return reasoning
    }

    func parseResponsesMessage(from payload: [String: Any]) throws -> ChatMessage {
        if let errorObject = payload["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            throw NSError(domain: "OpenAIResponsesError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let outputItems = payload["output"] as? [Any] else {
            throw NSError(domain: "OpenAIResponsesError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("响应中缺少 output 数组", comment: "OpenAI Responses missing output error")])
        }

        var textContent = ""
        var reasoningContent: String? = nil
        var reasoningItems: [JSONValue] = []
        var responseOutputItems: [JSONValue] = []
        var internalToolCalls: [InternalToolCall] = []

        for rawItem in outputItems {
            guard let item = rawItem as? [String: Any],
                  let type = item["type"] as? String else { continue }
            if let outputItem = jsonValue(fromJSONObject: item) {
                responseOutputItems.append(outputItem)
            }
            switch type {
            case "message":
                if let content = item["content"] as? [Any] {
                    textContent += parseResponsesTextContent(from: content)
                }
            case "function_call":
                let callID = (item["call_id"] as? String)
                    ?? (item["id"] as? String)
                    ?? "tool-\(UUID().uuidString)"
                guard let name = item["name"] as? String else { continue }
                let arguments = item["arguments"] as? String ?? ""
                var providerSpecificFields: [String: JSONValue] = [:]
                if let itemID = item["id"] as? String, !itemID.isEmpty {
                    providerSpecificFields[Self.responsesOutputItemIDKey] = .string(itemID)
                }
                if let status = item["status"] as? String, !status.isEmpty {
                    providerSpecificFields[Self.responsesOutputItemStatusKey] = .string(status)
                }
                internalToolCalls.append(
                    InternalToolCall(
                        id: callID,
                        toolName: name,
                        arguments: arguments,
                        providerSpecificFields: providerSpecificFields.isEmpty ? nil : providerSpecificFields
                    )
                )
            case "reasoning":
                if let reasoning = parseResponsesReasoningContent(from: item) {
                    appendSegment(reasoning, to: &reasoningContent)
                }
                if let reasoningItem = jsonValue(fromJSONObject: item) {
                    reasoningItems.append(reasoningItem)
                }
            default:
                continue
            }
        }

        let reasoningProviderSpecificFields: [String: JSONValue]? = reasoningItems.isEmpty
            ? nil
            : [Self.responsesReasoningItemsKey: .array(reasoningItems)]
        var providerResponseMetadata: [String: JSONValue] = [:]
        if let responseID = payload["id"] as? String, !responseID.isEmpty {
            providerResponseMetadata[Self.responsesResponseIDKey] = .string(responseID)
        }
        if !responseOutputItems.isEmpty {
            providerResponseMetadata[Self.responsesOutputItemsKey] = .array(responseOutputItems)
        }

        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            reasoningProviderSpecificFields: reasoningProviderSpecificFields,
            providerResponseMetadata: providerResponseMetadata.isEmpty ? nil : providerResponseMetadata,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeResponsesTokenUsage(from: payload["usage"])
        )
    }

    func responsesProviderMetadata(response: [String: Any]? = nil, outputItem: [String: Any]? = nil) -> [String: JSONValue]? {
        var metadata: [String: JSONValue] = [:]

        if let responseID = response?["id"] as? String, !responseID.isEmpty {
            metadata[Self.responsesResponseIDKey] = .string(responseID)
        }

        var outputItems: [JSONValue] = []
        if let responseOutput = response?["output"] as? [Any] {
            for rawItem in responseOutput {
                if let item = jsonValue(fromJSONObject: rawItem) {
                    outputItems.append(item)
                }
            }
        }
        if let outputItem,
           let item = jsonValue(fromJSONObject: outputItem) {
            outputItems.append(item)
        }
        if !outputItems.isEmpty {
            metadata[Self.responsesOutputItemsKey] = .array(outputItems)
        }

        return metadata.isEmpty ? nil : metadata
    }

    func parseResponsesStreamingEvent(_ payload: [String: Any]) -> ChatMessagePart? {
        guard let eventType = payload["type"] as? String else { return nil }
        switch eventType {
        case "response.output_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.refusal.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.function_call_arguments.delta":
            guard let delta = payload["delta"] as? String else { return nil }
            let callID = payload["call_id"] as? String
            var providerSpecificFields: [String: JSONValue] = [:]
            if let itemID = payload["item_id"] as? String, !itemID.isEmpty {
                providerSpecificFields[Self.responsesOutputItemIDKey] = .string(itemID)
            }
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: nil,
                        argumentsFragment: delta,
                        providerSpecificFields: providerSpecificFields.isEmpty ? nil : providerSpecificFields
                    )
                ]
            )

        case "response.function_call_arguments.done":
            let callID = payload["call_id"] as? String
            var providerSpecificFields: [String: JSONValue] = [:]
            if let itemID = payload["item_id"] as? String, !itemID.isEmpty {
                providerSpecificFields[Self.responsesOutputItemIDKey] = .string(itemID)
            }
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: nil,
                        argumentsFragment: nil,
                        argumentsReplacement: payload["arguments"] as? String,
                        providerSpecificFields: providerSpecificFields.isEmpty ? nil : providerSpecificFields
                    )
                ]
            )

        case "response.output_item.added":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return nil
            }
            let responseMetadata = responsesProviderMetadata(outputItem: item)
            if itemType == "reasoning",
               let reasoningItem = jsonValue(fromJSONObject: item) {
                return ChatMessagePart(
                    reasoningProviderSpecificFields: [
                        Self.responsesReasoningItemsKey: .array([reasoningItem])
                    ],
                    providerResponseMetadata: responseMetadata
                )
            }
            guard itemType == "function_call" else {
                return ChatMessagePart(providerResponseMetadata: responseMetadata)
            }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String)
            let arguments = item["arguments"] as? String
            var providerSpecificFields: [String: JSONValue] = [:]
            if let itemID = item["id"] as? String, !itemID.isEmpty {
                providerSpecificFields[Self.responsesOutputItemIDKey] = .string(itemID)
            }
            if let status = item["status"] as? String, !status.isEmpty {
                providerSpecificFields[Self.responsesOutputItemStatusKey] = .string(status)
            }
            return ChatMessagePart(
                providerResponseMetadata: responseMetadata,
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: item["name"] as? String,
                        argumentsFragment: arguments,
                        providerSpecificFields: providerSpecificFields.isEmpty ? nil : providerSpecificFields
                    )
                ]
            )

        case "response.output_item.done":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return nil
            }
            let responseMetadata = responsesProviderMetadata(outputItem: item)
            guard itemType == "reasoning" else {
                guard itemType == "function_call" else {
                    return ChatMessagePart(providerResponseMetadata: responseMetadata)
                }
                let callID = item["call_id"] as? String
                var providerSpecificFields: [String: JSONValue] = [:]
                if let itemID = item["id"] as? String, !itemID.isEmpty {
                    providerSpecificFields[Self.responsesOutputItemIDKey] = .string(itemID)
                }
                if let status = item["status"] as? String, !status.isEmpty {
                    providerSpecificFields[Self.responsesOutputItemStatusKey] = .string(status)
                }
                return ChatMessagePart(
                    providerResponseMetadata: responseMetadata,
                    toolCallDeltas: [
                        ChatMessagePart.ToolCallDelta(
                            id: callID,
                            index: payload["output_index"] as? Int,
                            nameFragment: item["name"] as? String,
                            argumentsFragment: nil,
                            argumentsReplacement: item["arguments"] as? String,
                            providerSpecificFields: providerSpecificFields.isEmpty ? nil : providerSpecificFields
                        )
                    ]
                )
            }
            guard let reasoningItem = jsonValue(fromJSONObject: item) else {
                return ChatMessagePart(providerResponseMetadata: responseMetadata)
            }
            return ChatMessagePart(
                reasoningProviderSpecificFields: [
                    Self.responsesReasoningItemsKey: .array([reasoningItem])
                ],
                providerResponseMetadata: responseMetadata
            )

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(reasoningContent: delta)
            }
            return nil

        case "response.created", "response.completed", "response.incomplete":
            guard let response = payload["response"] as? [String: Any] else {
                return nil
            }
            let metadata = responsesProviderMetadata(response: response)
            let usage = makeResponsesTokenUsage(from: response["usage"])
            if metadata == nil, usage == nil {
                return nil
            }
            return ChatMessagePart(providerResponseMetadata: metadata, tokenUsage: usage)

        default:
            return nil
        }
    }
}
