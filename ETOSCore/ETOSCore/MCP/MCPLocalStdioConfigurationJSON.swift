// ============================================================================
// MCPLocalStdioConfigurationJSON.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 stdio MCP 与常见单服务器 JSON 配置之间的无状态转换。
// ============================================================================

import Foundation

public enum MCPLocalStdioConfigurationJSONError: LocalizedError {
    case invalidJSON(String)
    case invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason):
            return String(
                format: NSLocalizedString("JSON 格式无效：%@", comment: "MCP stdio JSON syntax error"),
                reason
            )
        case .invalidConfiguration:
            return NSLocalizedString(
                "stdio 配置必须包含非空的 command；type 只能是 stdio，args、env 与 cwd 必须使用对应的 JSON 类型。",
                comment: "MCP stdio JSON semantic error"
            )
        }
    }
}

public enum MCPLocalStdioConfigurationJSON {
    public static let example = """
    {
      "args": [
        "mcp-server-git"
      ],
      "command": "uvx",
      "type": "stdio"
    }
    """

    public static func decode(_ text: String) throws -> MCPLocalStdioConfiguration {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw MCPLocalStdioConfigurationJSONError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any],
              let command = nonEmptyString(dictionary["command"]),
              validType(dictionary["type"]),
              let arguments = stringArray(dictionary["args"] ?? dictionary["arguments"]),
              let environment = stringDictionary(dictionary["env"] ?? dictionary["environment"]),
              let workingDirectory = workingDirectory(dictionary["cwd"] ?? dictionary["workingDirectory"]) else {
            throw MCPLocalStdioConfigurationJSONError.invalidConfiguration
        }
        return MCPLocalStdioConfiguration(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    public static func encode(_ configuration: MCPLocalStdioConfiguration) -> String {
        var object: [String: Any] = [
            "args": configuration.arguments,
            "command": configuration.command,
            "type": "stdio"
        ]
        if !configuration.environment.isEmpty {
            object["env"] = configuration.environment
        }
        if configuration.workingDirectory != "/home/etos" {
            object["cwd"] = configuration.workingDirectory
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return example
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validType(_ value: Any?) -> Bool {
        guard let value else { return true }
        return (value as? String)?.lowercased() == "stdio"
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let value else { return [] }
        return value as? [String]
    }

    private static func stringDictionary(_ value: Any?) -> [String: String]? {
        guard let value else { return [:] }
        return value as? [String: String]
    }

    private static func workingDirectory(_ value: Any?) -> String? {
        guard let value else { return "/home/etos" }
        guard let directory = nonEmptyString(value), directory.hasPrefix("/") else { return nil }
        return directory
    }
}
