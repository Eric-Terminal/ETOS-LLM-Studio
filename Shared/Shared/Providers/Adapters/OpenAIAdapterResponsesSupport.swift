// ============================================================================
// OpenAIAdapterResponsesSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// OpenAI Responses API 的输入构建、工具回填与响应解析辅助逻辑。
// ============================================================================

import Foundation

extension OpenAIAdapter {
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
        [
            "type": "function_call",
            "call_id": toolCall.id,
            "name": sanitizedToolName(toolCall.toolName),
            "arguments": toolCall.arguments,
            "status": "completed"
        ]
    }

    func buildResponsesFunctionCallOutputItem(from message: ChatMessage) -> [String: Any]? {
        guard message.role == .tool, let callID = message.toolCalls?.first?.id else { return nil }
        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": message.content
        ]
    }

    func buildResponsesReasoningInputItems(from message: ChatMessage) -> [[String: Any]] {
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

    func buildResponsesInputItems(
        from messages: [ChatMessage],
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []
        items.reserveCapacity(messages.count)

        for message in messages {
            if message.role == .assistant {
                items.append(contentsOf: buildResponsesReasoningInputItems(from: message))
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
        }

        return items
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
        var internalToolCalls: [InternalToolCall] = []

        for rawItem in outputItems {
            guard let item = rawItem as? [String: Any],
                  let type = item["type"] as? String else { continue }
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
                internalToolCalls.append(
                    InternalToolCall(
                        id: callID,
                        toolName: name,
                        arguments: arguments
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

        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            reasoningProviderSpecificFields: reasoningProviderSpecificFields,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeResponsesTokenUsage(from: payload["usage"])
        )
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
            let callID = (payload["call_id"] as? String) ?? (payload["item_id"] as? String)
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: nil,
                        argumentsFragment: delta
                    )
                ]
            )

        case "response.output_item.added":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return nil
            }
            if itemType == "reasoning",
               let reasoningItem = jsonValue(fromJSONObject: item) {
                return ChatMessagePart(reasoningProviderSpecificFields: [
                    Self.responsesReasoningItemsKey: .array([reasoningItem])
                ])
            }
            guard itemType == "function_call" else { return nil }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String)
            let arguments = item["arguments"] as? String
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: item["name"] as? String,
                        argumentsFragment: arguments
                    )
                ]
            )

        case "response.output_item.done":
            guard let item = payload["item"] as? [String: Any],
                  item["type"] as? String == "reasoning",
                  let reasoningItem = jsonValue(fromJSONObject: item) else {
                return nil
            }
            return ChatMessagePart(reasoningProviderSpecificFields: [
                Self.responsesReasoningItemsKey: .array([reasoningItem])
            ])

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(reasoningContent: delta)
            }
            return nil

        case "response.completed", "response.incomplete":
            guard let response = payload["response"] as? [String: Any],
                  let usage = makeResponsesTokenUsage(from: response["usage"]) else {
                return nil
            }
            return ChatMessagePart(tokenUsage: usage)

        default:
            return nil
        }
    }
}
