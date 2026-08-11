// ============================================================================
// MCPNativeMediaExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 媒体与环境 MCP 的统一路由，并把可信会话/Run 标识传给有状态蓝牙连接。
// ============================================================================

import Foundation

actor MCPNativeMediaExecutor {
    static let shared = MCPNativeMediaExecutor()

    private let speech = MCPNativeSpeechExecutor()
    private let media = MCPNativeMediaPlaybackExecutor()
    private let weather = MCPNativeWeatherExecutor()
    private let nfc = MCPNativeNFCExecutor()

    func execute(toolName: String, argumentsJSON: String) async throws -> [String: Any] {
        var arguments = try Self.arguments(from: argumentsJSON)
        let sourceSessionID = (arguments.removeValue(
            forKey: MCPBuiltInAppToolServer.conversationSourceSessionIDArgument
        ) as? String).flatMap(UUID.init(uuidString:))
        let sourceRunID = (arguments.removeValue(
            forKey: MCPBuiltInAppToolServer.localAgentRunIDArgument
        ) as? String).flatMap(UUID.init(uuidString:))
        arguments.removeValue(forKey: MCPBuiltInAppToolServer.conversationToolCallIDArgument)
        arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument)
        let scopeID = sourceRunID ?? sourceSessionID

        let payload: [String: Any]
        switch toolName {
        case _ where toolName.hasPrefix("speech."):
            payload = try await speech.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("media."):
            payload = try await media.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("weather."):
            payload = try await weather.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("home."):
            payload = try await MCPNativeHomeExecutor.shared.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("bluetooth."):
            payload = try await MCPNativeBluetoothExecutor.shared.execute(toolName: toolName, arguments: arguments, scopeID: scopeID)
        case _ where toolName.hasPrefix("nfc."):
            payload = try await nfc.execute(toolName: toolName, arguments: arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        var result: [String: Any] = [
            "provider": "etos_builtin_native_media",
            "tool_name": toolName
        ]
        result.merge(payload) { _, new in new }
        return result
    }

    func finishRun(id: UUID) async {
        await MCPNativeBluetoothExecutor.shared.finishRun(id: id)
    }

    private static func arguments(from text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("原生媒体工具参数必须是 JSON 对象。", comment: "Native media MCP arguments must be object")
            )
        }
        return object
    }
}
