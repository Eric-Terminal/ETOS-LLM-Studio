// ============================================================================
// MCPNativeDeviceExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 设备操作 MCP 的统一解码和路由入口。
// ============================================================================

import Foundation

actor MCPNativeDeviceExecutor {
    static let shared = MCPNativeDeviceExecutor()

    private let clipboard = MCPNativeClipboardExecutor()
    private let notifications = MCPNativeNotificationExecutor()
    private let alarms = MCPNativeAlarmExecutor()
    private let maps = MCPNativeMapsExecutor()
    private let status = MCPNativeDeviceStatusExecutor()

    func execute(toolName: String, argumentsJSON: String) async throws -> [String: Any] {
        let arguments = try Self.arguments(from: argumentsJSON)
        return try await execute(toolName: toolName, arguments: arguments)
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        let payload: [String: Any]
        switch toolName {
        case _ where toolName.hasPrefix("clipboard."):
            payload = try await clipboard.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("notifications."):
            payload = try await notifications.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("alarms."):
            payload = try await alarms.execute(toolName: toolName, arguments: arguments)
        case _ where toolName.hasPrefix("maps."), "device.open_url":
            payload = try await maps.execute(toolName: toolName, arguments: arguments)
        case "device.get_status":
            payload = try await status.execute()
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        var result: [String: Any] = [
            "provider": "etos_builtin_native_device",
            "tool_name": toolName
        ]
        result.merge(payload) { _, new in new }
        return result
    }

    private static func arguments(from text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("原生工具参数必须是 JSON 对象。", comment: "Native MCP arguments must be object")
            )
        }
        return object
    }
}
