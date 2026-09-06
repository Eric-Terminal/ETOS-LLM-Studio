// ============================================================================
// MCPToolCallTitleMetadata.swift
// ============================================================================
// ETOS LLM Studio
//
// 在模型可见的 MCP 参数结构中携带用户可读标题，并在调用外部 Server 前剥离。
// ============================================================================

import Foundation

public enum MCPToolCallTitleMetadata {
    public static let argumentKey = "__etos_tool_title"

    public struct ParsedArguments: Equatable, Sendable {
        public let title: String?
        public let argumentsJSON: String
    }

    public static func injectingTitle(into schema: JSONValue) -> JSONValue {
        guard case .dictionary(var root) = schema else { return schema }

        var properties: [String: JSONValue]
        if case .dictionary(let existingProperties) = root["properties"] {
            properties = existingProperties
        } else {
            properties = [:]
        }
        properties[argumentKey] = .dictionary([
            "type": .string("string"),
            "description": .string(NSLocalizedString(
                "为这次 MCP 工具调用提供简短的用户可见任务标题，使用与用户相同的语言。中文尽量不超过 15 个字，其他语言使用 5 到 10 个词。此字段仅供 ETOS 界面显示，不会发送给 MCP Server。",
                comment: "MCP tool call title schema description sent to the model"
            ))
        ])
        root["properties"] = .dictionary(properties)

        var required: [JSONValue]
        if case .array(let existingRequired) = root["required"] {
            required = existingRequired
        } else {
            required = []
        }
        if !required.contains(.string(argumentKey)) {
            required.append(.string(argumentKey))
        }
        root["required"] = .array(required)
        return .dictionary(root)
    }

    public static func parse(argumentsJSON: String) -> ParsedArguments {
        guard let data = argumentsJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedArguments(title: nil, argumentsJSON: argumentsJSON)
        }

        let rawTitle = object.removeValue(forKey: argumentKey) as? String
        let title = rawTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(160)
        let normalizedTitle = title.flatMap { $0.isEmpty ? nil : String($0) }

        guard let sanitizedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let sanitizedJSON = String(data: sanitizedData, encoding: .utf8) else {
            return ParsedArguments(title: normalizedTitle, argumentsJSON: argumentsJSON)
        }
        return ParsedArguments(title: normalizedTitle, argumentsJSON: sanitizedJSON)
    }
}
