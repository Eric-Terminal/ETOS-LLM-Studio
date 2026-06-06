// ============================================================================
// LocalLLMChatMessageBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 ELS 聊天消息转换为 llama.cpp chat template API 所需的结构化消息。
// ============================================================================

import Foundation

public struct LocalLLMChatMessage: Hashable, Sendable {
    public var role: String
    public var content: String
    public var name: String?
    public var toolCallID: String?
    public var toolCallsJSON: String?

    public init(
        role: String,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCallsJSON = toolCallsJSON
    }
}

public struct LocalLLMToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public enum LocalLLMChatMessageBuilder {
    public static func messages(from messages: [ChatMessage]) -> [LocalLLMChatMessage] {
        messages.compactMap { message in
            let role = roleName(for: message.role)
            let content = content(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCallsJSON = toolCallsJSON(for: message)
            guard !content.isEmpty || toolCallsJSON != nil else { return nil }
            return LocalLLMChatMessage(
                role: role,
                content: content,
                name: toolName(for: message),
                toolCallID: toolCallID(for: message),
                toolCallsJSON: toolCallsJSON
            )
        }
    }

    public static func toolDefinitions(from tools: [InternalToolDefinition]?) -> [LocalLLMToolDefinition] {
        guard let tools else { return [] }
        return tools.compactMap { tool in
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return LocalLLMToolDefinition(
                name: name,
                description: tool.description,
                parametersJSON: tool.parameters.prettyPrintedCompact()
            )
        }
    }

    public static func parseToolCalls(from generatedText: String, tools: [LocalLLMToolDefinition]) -> LocalLLMToolCallParseResult {
        parseGeneratedOutput(from: generatedText, tools: tools)
    }

    public static func parseGeneratedOutput(from generatedText: String, tools: [LocalLLMToolDefinition] = []) -> LocalLLMToolCallParseResult {
        let reasoningResult = extractReasoningContent(from: generatedText)
        let toolResult = extractToolCalls(from: reasoningResult.content, tools: tools)
        let normalizedReasoning = normalizeParsedText(reasoningResult.reasoning)
        return LocalLLMToolCallParseResult(
            content: normalizeGeneratedContent(toolResult.content),
            reasoningContent: normalizedReasoning.isEmpty ? nil : normalizedReasoning,
            toolCalls: toolResult.toolCalls
        )
    }

    private static func extractToolCalls(from generatedText: String, tools: [LocalLLMToolDefinition]) -> (content: String, toolCalls: [InternalToolCall]) {
        guard !tools.isEmpty else {
            return (generatedText, [])
        }
        let toolNames = Set(tools.map(\.name))
        var workingText = generatedText
        var calls = extractGemma4ToolCalls(from: &workingText, validToolNames: toolNames)
        calls += extractBracketToolCalls(from: &workingText, validToolNames: toolNames, idOffset: calls.count)

        var matchedRanges: [Range<String.Index>] = []
        let candidates = jsonCandidates(from: workingText)
        for candidate in candidates {
            if matchedRanges.contains(where: { $0.overlaps(candidate.range) }) {
                continue
            }
            guard let data = candidate.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            let parsedCalls = parseToolCallObjects(from: object, validToolNames: toolNames, idOffset: calls.count)
            if !parsedCalls.isEmpty {
                matchedRanges.append(candidate.range)
                calls.append(contentsOf: parsedCalls)
            }
        }
        removeRanges(matchedRanges, from: &workingText)
        let content = removeResidualToolMarkers(from: workingText)
        return (content, calls)
    }

    private static func roleName(for role: MessageRole) -> String {
        switch role {
        case .system:
            return "system"
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .tool:
            return "tool"
        case .error:
            return "user"
        }
    }

    private static func content(for message: ChatMessage) -> String {
        switch message.role {
        case .error:
            return ""
        default:
            return message.content
        }
    }

    private static func toolName(for message: ChatMessage) -> String? {
        guard message.role == .tool else { return nil }
        return message.toolCalls?.first?.toolName
    }

    private static func toolCallID(for message: ChatMessage) -> String? {
        guard message.role == .tool else { return nil }
        return message.toolCalls?.first?.id
    }

    private static func toolCallsJSON(for message: ChatMessage) -> String? {
        guard message.role == .assistant,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return nil
        }

        let objects = toolCalls.map { call -> [String: Any] in
            let arguments: Any
            if let data = call.arguments.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                arguments = decoded
            } else {
                arguments = call.arguments
            }
            return [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.toolName,
                    "arguments": arguments
                ]
            ]
        }

        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private struct ReasoningMarker {
        let start: String
        let end: String
    }

    private static func extractReasoningContent(from text: String) -> (content: String, reasoning: String?) {
        var workingText = text
        var reasoningSegments: [String] = []

        extractSpecialReasoningBlocks(from: &workingText, into: &reasoningSegments)
        extractLeadingReasoningBlocks(from: &workingText, into: &reasoningSegments)

        return (
            content: workingText,
            reasoning: reasoningSegments.isEmpty ? nil : reasoningSegments.joined(separator: "\n\n")
        )
    }

    private static func extractSpecialReasoningBlocks(from text: inout String, into reasoningSegments: inout [String]) {
        let markers = [
            ReasoningMarker(start: "<|start|>assistant<|channel|>analysis<|message|>", end: "<|end|>"),
            ReasoningMarker(start: "<|channel|>analysis<|message|>", end: "<|end|>"),
            ReasoningMarker(start: "<|channel>thought", end: "<channel|>"),
            ReasoningMarker(start: "[THINK]", end: "[/THINK]")
        ]

        while let match = earliestReasoningMarker(in: text, markers: markers) {
            let bodyStart = match.range.upperBound
            if let endRange = text.range(of: match.marker.end, range: bodyStart..<text.endIndex) {
                reasoningSegments.append(String(text[bodyStart..<endRange.lowerBound]))
                text.removeSubrange(match.range.lowerBound..<endRange.upperBound)
            } else {
                reasoningSegments.append(String(text[bodyStart..<text.endIndex]))
                text.removeSubrange(match.range.lowerBound..<text.endIndex)
                break
            }
        }
    }

    private static func earliestReasoningMarker(
        in text: String,
        markers: [ReasoningMarker]
    ) -> (marker: ReasoningMarker, range: Range<String.Index>)? {
        var selected: (marker: ReasoningMarker, range: Range<String.Index>)?
        for marker in markers {
            guard let range = text.range(of: marker.start) else { continue }
            if let current = selected {
                if range.lowerBound < current.range.lowerBound {
                    selected = (marker, range)
                }
            } else {
                selected = (marker, range)
            }
        }
        return selected
    }

    private static func extractLeadingReasoningBlocks(from text: inout String, into reasoningSegments: inout [String]) {
        let markers = [
            ReasoningMarker(start: "<thought>", end: "</thought>"),
            ReasoningMarker(start: "<thinking>", end: "</thinking>"),
            ReasoningMarker(start: "<think>", end: "</think>")
        ]

        while true {
            guard let tagStart = firstNonWhitespaceIndex(in: text, from: text.startIndex) else { return }
            guard let marker = markers.first(where: { text[tagStart...].hasPrefix($0.start) }) else {
                return
            }

            let bodyStart = text.index(tagStart, offsetBy: marker.start.count)
            if let endRange = text.range(of: marker.end, range: bodyStart..<text.endIndex) {
                reasoningSegments.append(String(text[bodyStart..<endRange.lowerBound]))
                text.removeSubrange(tagStart..<endRange.upperBound)
            } else {
                reasoningSegments.append(String(text[bodyStart..<text.endIndex]))
                text.removeSubrange(tagStart..<text.endIndex)
                return
            }
        }
    }

    private static func firstNonWhitespaceIndex(in text: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        while index < text.endIndex {
            if !text[index].isWhitespace {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func normalizeParsedText(_ text: String?) -> String {
        guard let text else { return "" }
        return normalizeGeneratedContent(text)
    }

    private static func normalizeGeneratedContent(_ text: String) -> String {
        var content = text
        let tokensToRemove = [
            "<|turn>model\n",
            "<|turn>model",
            "<start_of_turn>model\n",
            "<start_of_turn>model",
            "<|start|>assistant<|channel|>final<|message|>",
            "<|channel|>final<|message|>",
            "<|channel>final",
            "<|end|>",
            "<end_of_turn>",
            "<turn|>",
            "<|eot_id|>",
            "<|im_end|>",
            "<channel|>",
            "</s>",
            "<eos>"
        ]
        for token in tokensToRemove {
            content = content.replacingOccurrences(of: token, with: "")
        }
        content = content.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeResidualToolMarkers(from text: String) -> String {
        var content = text
        let markers = [
            "<tool_call>",
            "</tool_call>",
            "<tool_calls>",
            "</tool_calls>",
            "<|tool_call>call:",
            "<|tool_call>",
            "<tool_call|>",
            "[TOOL_CALLS]",
            "[ARGS]"
        ]
        for marker in markers {
            content = content.replacingOccurrences(of: marker, with: "")
        }
        return content
    }

    private static func extractGemma4ToolCalls(
        from text: inout String,
        validToolNames: Set<String>
    ) -> [InternalToolCall] {
        var calls: [InternalToolCall] = []
        var rangesToRemove: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let startMarker = "<|tool_call>call:"
        let endMarker = "<tool_call|>"

        while searchStart < text.endIndex,
              let startRange = text.range(of: startMarker, range: searchStart..<text.endIndex) {
            let bodyStart = startRange.upperBound
            guard let endRange = text.range(of: endMarker, range: bodyStart..<text.endIndex) else {
                break
            }
            let body = String(text[bodyStart..<endRange.lowerBound])
            if let call = parseGemma4ToolCallBody(
                body,
                validToolNames: validToolNames,
                index: calls.count
            ) {
                calls.append(call)
                rangesToRemove.append(startRange.lowerBound..<endRange.upperBound)
            }
            searchStart = endRange.upperBound
        }

        removeRanges(rangesToRemove, from: &text)
        return calls
    }

    private static func parseGemma4ToolCallBody(
        _ body: String,
        validToolNames: Set<String>,
        index: Int
    ) -> InternalToolCall? {
        guard let argumentsStart = body.firstIndex(of: "{") else { return nil }
        let name = body[..<argumentsStart].trimmingCharacters(in: .whitespacesAndNewlines)
        guard validToolNames.contains(name) else { return nil }
        let arguments = gemma4ArgumentsJSON(String(body[argumentsStart...]))
        return InternalToolCall(
            id: "local_tool_\(index + 1)",
            toolName: name,
            arguments: arguments
        )
    }

    private static func gemma4ArgumentsJSON(_ rawArguments: String) -> String {
        let quotedStrings = rawArguments.replacingOccurrences(of: #"<|"|>"#, with: "\"")
        let quotedKeys = quoteUnquotedJSONKeys(quotedStrings)
        return compactJSONString(quotedKeys) ?? quotedKeys.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quoteUnquotedJSONKeys(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"([\{,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)(\s*:)"#,
            with: #"$1"$2"$3"#,
            options: .regularExpression
        )
    }

    private static func extractBracketToolCalls(
        from text: inout String,
        validToolNames: Set<String>,
        idOffset: Int
    ) -> [InternalToolCall] {
        let marker = "[TOOL_CALLS]"
        let argumentsMarker = "[ARGS]"
        let orderedToolNames = validToolNames.sorted { $0.count > $1.count }
        var calls: [InternalToolCall] = []
        var rangesToRemove: [Range<String.Index>] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
            guard let nameStart = firstNonWhitespaceIndex(in: text, from: markerRange.upperBound),
                  let toolName = orderedToolNames.first(where: { text[nameStart...].hasPrefix($0) }) else {
                searchStart = markerRange.upperBound
                continue
            }

            let nameEnd = text.index(nameStart, offsetBy: toolName.count)
            guard let argumentsMarkerRange = text.range(of: argumentsMarker, range: nameEnd..<text.endIndex),
                  let jsonStart = firstNonWhitespaceIndex(in: text, from: argumentsMarkerRange.upperBound),
                  let candidate = jsonCandidate(in: text, startingAt: jsonStart) else {
                searchStart = nameEnd
                continue
            }

            calls.append(InternalToolCall(
                id: "local_tool_\(idOffset + calls.count + 1)",
                toolName: toolName,
                arguments: compactJSONString(candidate.text) ?? candidate.text
            ))
            rangesToRemove.append(markerRange.lowerBound..<candidate.range.upperBound)
            searchStart = candidate.range.upperBound
        }

        removeRanges(rangesToRemove, from: &text)
        return calls
    }

    private static func jsonCandidate(in text: String, startingAt start: String.Index) -> (text: String, range: Range<String.Index>)? {
        guard start < text.endIndex, text[start] == "{" || text[start] == "[" else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if escaping {
                escaping = false
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                escaping = true
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString.toggle()
                index = text.index(after: index)
                continue
            }
            if inString {
                index = text.index(after: index)
                continue
            }
            if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 {
                    let upperBound = text.index(after: index)
                    let range = start..<upperBound
                    return (String(text[range]), range)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func jsonCandidates(from text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(text: String, range: Range<String.Index>)] = []
        for start in text.indices where text[start] == "{" || text[start] == "[" {
            if let candidate = jsonCandidate(in: text, startingAt: start) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func parseToolCallObjects(
        from object: Any,
        validToolNames: Set<String>,
        idOffset: Int = 0
    ) -> [InternalToolCall] {
        let rawCalls: [Any]
        if let dictionary = object as? [String: Any], let toolCalls = dictionary["tool_calls"] as? [Any] {
            rawCalls = toolCalls
        } else if let array = object as? [Any] {
            rawCalls = array
        } else {
            rawCalls = [object]
        }

        return rawCalls.enumerated().compactMap { index, rawCall in
            guard let dictionary = rawCall as? [String: Any] else { return nil }
            let function = dictionary["function"] as? [String: Any]
            let name = (dictionary["name"] as? String) ?? (function?["name"] as? String) ?? ""
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validToolNames.contains(trimmedName) else { return nil }

            let rawArguments = dictionary["arguments"] ?? function?["arguments"] ?? [:]
            let arguments: String
            if let string = rawArguments as? String {
                arguments = string
            } else if JSONSerialization.isValidJSONObject(rawArguments),
                      let data = try? JSONSerialization.data(withJSONObject: rawArguments, options: [.sortedKeys]),
                      let json = String(data: data, encoding: .utf8) {
                arguments = json
            } else {
                arguments = "{}"
            }
            let id = (dictionary["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return InternalToolCall(
                id: id?.isEmpty == false ? id! : "local_tool_\(idOffset + index + 1)",
                toolName: trimmedName,
                arguments: arguments
            )
        }
    }

    private static func compactJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let compactData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: compactData, encoding: .utf8)
    }

    private static func removeRanges(_ ranges: [Range<String.Index>], from text: inout String) {
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            text.removeSubrange(range)
        }
    }
}
