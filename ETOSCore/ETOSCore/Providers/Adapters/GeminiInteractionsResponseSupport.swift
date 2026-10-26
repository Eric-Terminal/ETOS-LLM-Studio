import Foundation

extension GeminiInteractionsAdapter {
    static let stepsKey = "gemini_interactions_steps"

    public func parseResponse(data: Data) throws -> ChatMessage {
        let payload = try responseObject(data)
        guard let steps = payload["steps"] as? [[String: Any]] else { throw responseError() }
        var text = ""
        var thoughts = ""
        var calls: [InternalToolCall] = []
        var stored: [String: JSONValue] = [:]
        for (index, step) in steps.enumerated() where step["type"] as? String != "user_input" {
            let part = part(for: step, index: index)
            text += part.content ?? ""
            thoughts += part.reasoningContent ?? ""
            for delta in part.toolCallDeltas ?? [] {
                guard let id = delta.id, let name = delta.nameFragment else { throw responseError() }
                calls.append(InternalToolCall(id: id, toolName: name, arguments: delta.argumentsReplacement ?? "{}"))
            }
            if let value = jsonValue(step) { stored[String(index)] = value }
        }
        return ChatMessage(
            role: .assistant, content: text, reasoningContent: thoughts.isEmpty ? nil : thoughts,
            providerResponseMetadata: [Self.stepsKey: .dictionary(stored)],
            toolCalls: calls.isEmpty ? nil : calls,
            tokenUsage: tokenUsage(payload["usage"] as? [String: Any])
        )
    }

    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }
        let text = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = event["error"] as? [String: Any] {
            return ChatMessagePart(streamTermination: .failed(reason: error["message"] as? String))
        }
        let metadata = event["metadata"] as? [String: Any]
        let usage = tokenUsage(event["usage"] as? [String: Any] ?? metadata?["total_usage"] as? [String: Any])
        switch event["event_type"] as? String {
        case "step.start":
            guard let index = event["index"] as? Int, let step = event["step"] as? [String: Any] else { return nil }
            var result = part(for: step, index: index)
            // 空参数起始块不能先填入 {}，否则后续 arguments_delta 会被拼成无效 JSON。
            if var calls = result.toolCallDeltas, let arguments = step["arguments"] as? [String: Any], arguments.isEmpty {
                calls[0].argumentsReplacement = nil
                result.toolCallDeltas = calls
            }
            result.providerResponseMetadata = stepMetadata(index: index, operation: "step", value: step)
            result.tokenUsage = usage
            return result
        case "step.delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return nil }
            var result = ChatMessagePart(tokenUsage: usage)
            switch delta["type"] as? String {
            case "text": result.content = delta["text"] as? String
            case "thought_summary": result.reasoningContent = (delta["content"] as? [String: Any])?["text"] as? String
            case "arguments_delta":
                result.toolCallDeltas = [.init(id: nil, index: index, nameFragment: nil, argumentsFragment: delta["arguments"] as? String)]
            default: break
            }
            result.providerResponseMetadata = stepMetadata(index: index, operation: "delta", value: delta)
            return result
        case "step.stop":
            return ChatMessagePart(tokenUsage: usage)
        case "interaction.completed":
            guard let interaction = event["interaction"] as? [String: Any] else { return nil }
            return ChatMessagePart(
                tokenUsage: tokenUsage(interaction["usage"] as? [String: Any]) ?? usage,
                streamTermination: termination(interaction)
            )
        case "interaction.status_update":
            // requires_action 是工具调用的正常交接；流仍可能继续发送签名与用量，等 completed 收尾。
            let status = event["status"] as? String
            return ChatMessagePart(tokenUsage: usage, streamTermination: ["failed", "cancelled", "incomplete"].contains(status ?? "") ? termination(event) : nil)
        case "error": return ChatMessagePart(streamTermination: .failed(reason: nil))
        default: return nil
        }
    }

    private func part(for step: [String: Any], index: Int) -> ChatMessagePart {
        switch step["type"] as? String {
        case "model_output":
            return ChatMessagePart(content: textContent(step["content"]))
        case "thought":
            return ChatMessagePart(reasoningContent: textContent(step["summary"]))
        case "function_call":
            let arguments = step["arguments"].flatMap(jsonValue)?.prettyPrintedCompact()
            return ChatMessagePart(toolCallDeltas: [.init(
                id: step["id"] as? String, index: index, nameFragment: step["name"] as? String,
                argumentsFragment: nil, argumentsReplacement: arguments
            )])
        default: return ChatMessagePart()
        }
    }

    private func textContent(_ content: Any?) -> String {
        (content as? [[String: Any]] ?? []).compactMap { item in
            item["type"] as? String == "text" ? item["text"] as? String : nil
        }.joined()
    }

    func responseObject(_ data: Data) throws -> [String: Any] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw responseError() }
        if let error = payload["error"] as? [String: Any] { throw responseError(error["message"] as? String) }
        guard case .completed = termination(payload) else {
            let errors = payload["errors"] as? [[String: Any]]
            throw responseError(errors?.first?["message"] as? String)
        }
        return payload
    }

    private func termination(_ payload: [String: Any]) -> ChatMessagePart.StreamTermination {
        switch payload["status"] as? String {
        case "completed", "requires_action": return .completed
        default:
            let errors = payload["errors"] as? [[String: Any]]
            return .failed(reason: errors?.first?["message"] as? String ?? responseError().localizedDescription)
        }
    }

    func responseError(_ message: String? = nil) -> NSError {
        NSError(domain: "GeminiInteractionsAPI", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message ?? NSLocalizedString(
                "Gemini Interactions 未返回完整的有效响应。",
                value: "Gemini Interactions did not return a complete, valid response.", comment: "Interactions 响应无效或未完成"
            )
        ])
    }

    private func tokenUsage(_ usage: [String: Any]?) -> MessageTokenUsage? {
        guard let usage else { return nil }
        let result = MessageTokenUsage(
            promptTokens: usage["total_input_tokens"] as? Int,
            completionTokens: usage["total_output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int,
            thinkingTokens: usage["total_thought_tokens"] as? Int,
            cacheReadTokens: usage["total_cached_tokens"] as? Int
        )
        return result.hasData ? result : nil
    }

    private func jsonValue(_ object: Any) -> JSONValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func stepMetadata(index: Int, operation: String, value: [String: Any]) -> [String: JSONValue]? {
        guard let value = jsonValue(value) else { return nil }
        return [Self.stepsKey: .dictionary([String(index): .dictionary([operation: value])])]
    }

    /// 状态由每条消息持有，适配器本身无流式状态，避免并发会话混入其他请求的签名或参数。
    static func mergingSteps(existing: JSONValue?, incoming: JSONValue) -> JSONValue {
        var steps: [String: JSONValue] = [:]
        if case let .dictionary(value)? = existing { steps = value }
        guard case let .dictionary(operations) = incoming else { return .dictionary(steps) }
        for (index, value) in operations {
            guard case let .dictionary(operation) = value else { continue }
            if let step = operation["step"] {
                steps[index] = step
                continue
            }
            guard case let .dictionary(delta)? = operation["delta"] else {
                steps[index] = value
                continue
            }
            var step: [String: JSONValue] = [:]
            if case let .dictionary(value)? = steps[index] { step = value }
            switch delta["type"] {
            case .string("text")?:
                var content: [JSONValue] = []
                if case let .array(value)? = step["content"] { content = value }
                let text: String
                if case let .string(value)? = delta["text"] { text = value } else { text = "" }
                if let last = content.indices.last, case var .dictionary(item) = content[last],
                   item["type"] == .string("text"), case let .string(previous)? = item["text"] {
                    item["text"] = .string(previous + text)
                    content[last] = .dictionary(item)
                } else { content.append(.dictionary(["type": .string("text"), "text": .string(text)])) }
                step["content"] = .array(content)
            case .string("thought_summary")?:
                if let content = delta["content"] {
                    var summary: [JSONValue] = []
                    if case let .array(value)? = step["summary"] { summary = value }
                    step["summary"] = .array(summary + [content])
                }
            case .string("thought_signature")?: step["signature"] = delta["signature"]
            case .string("text_annotation_delta")?:
                if case var .array(content)? = step["content"], let last = content.indices.last,
                   case var .dictionary(item) = content[last], item["type"] == .string("text"),
                   case let .array(incoming)? = delta["annotations"] {
                    var annotations: [JSONValue] = []
                    if case let .array(value)? = item["annotations"] { annotations = value }
                    item["annotations"] = .array(annotations + incoming)
                    content[last] = .dictionary(item)
                    step["content"] = .array(content)
                }
            case .string("image")?, .string("audio")?, .string("video")?, .string("document")?:
                var content: [JSONValue] = []
                if case let .array(value)? = step["content"] { content = value }
                step["content"] = .array(content + [.dictionary(delta)])
            case .string("arguments_delta")?:
                // 拼接期间保持字符串，回放前才解码成协议要求的参数对象。
                var arguments = ""
                if case let .string(value)? = step["arguments"] { arguments = value }
                if case let .string(value)? = delta["arguments"] { arguments += value }
                step["arguments"] = .string(arguments)
            default:
                for (key, value) in delta where key != "type" {
                    if key == "result", case let .array(incoming) = value, case let .array(existing)? = step[key] {
                        step[key] = .array(existing + incoming)
                    } else { step[key] = value }
                }
            }
            steps[index] = .dictionary(step)
        }
        return .dictionary(steps)
    }

    func replaySteps(for message: ChatMessage) -> [[String: Any]]? {
        guard let stored = message.providerResponseMetadata?[Self.stepsKey]?.toAny() as? [String: [String: Any]] else { return nil }
        var steps = stored.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { stored[$0] }
        for index in steps.indices where steps[index]["type"] as? String == "function_call" {
            if let arguments = steps[index]["arguments"] as? String {
                guard let data = arguments.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                steps[index]["arguments"] = object
            } else if steps[index]["arguments"] == nil {
                // 零参数工具可能只有起始事件，没有参数分片；回放仍需要完整参数对象。
                steps[index]["arguments"] = [String: Any]()
            }
        }
        let originalText = steps.filter { $0["type"] as? String == "model_output" }.map { textContent($0["content"]) }.joined()
        let originalCalls = steps.filter { $0["type"] as? String == "function_call" }
        let calls = message.toolCalls ?? []
        // 编辑正文或工具参数后，旧签名不再代表当前消息；只回放仍与可见历史一致的原生步骤。
        guard originalText == message.content, originalCalls.count == calls.count else { return nil }
        for (original, call) in zip(originalCalls, calls) {
            guard original["id"] as? String == call.id,
                  original["name"] as? String == geminiAdapter.sanitizedToolName(call.toolName),
                  let arguments = call.arguments.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: arguments),
                  jsonValue(original["arguments"] ?? [:]) == value else { return nil }
        }
        // 无状态 Interactions 必须原样回传模型步骤及签名，不能受通用思考文本回传开关裁剪。
        return steps.filter { $0["type"] as? String != "user_input" && $0["type"] as? String != "function_result" }
    }
}
