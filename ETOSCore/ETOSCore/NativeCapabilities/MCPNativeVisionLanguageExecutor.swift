// ============================================================================
// MCPNativeVisionLanguageExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// Vision 与 NaturalLanguage 的统一路由；两者都是确定性端侧分析。
// ============================================================================

import Foundation

actor MCPNativeVisionLanguageExecutor {
    static let shared = MCPNativeVisionLanguageExecutor()

    private let vision = MCPNativeVisionExecutor()
    private let language = MCPNativeLanguageExecutor()

    func execute(toolName: String, argumentsJSON: String) async throws -> [String: Any] {
        let arguments = try Self.arguments(from: argumentsJSON)
        let payload: [String: Any]
        if toolName.hasPrefix("vision.") {
            payload = try await vision.execute(toolName: toolName, arguments: arguments)
        } else if toolName.hasPrefix("language.") {
            payload = try await language.execute(toolName: toolName, arguments: arguments)
        } else {
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        var result: [String: Any] = [
            "provider": "etos_builtin_on_device",
            "tool_name": toolName,
            "uses_model": false
        ]
        result.merge(payload) { _, new in new }
        return result
    }

    private static func arguments(from text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("端侧视觉与语言工具参数必须是 JSON 对象。", comment: "Vision language arguments must be object")
            )
        }
        return object
    }
}
