// ============================================================================
// RoleplayMVUEventBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 将原生 MVU 生命周期广播给当前会话的酒馆助手与 HTML 运行时。
// ============================================================================

import Foundation

public enum RoleplayMVUEventName {
    public static let variableInitialized = "mag_variable_initialized"
    public static let legacyVariableInitialized = "mag_variable_initiailized"
    public static let variableUpdateStarted = "mag_variable_update_started"
    public static let commandParsed = "mag_command_parsed"
    public static let variableUpdateEnded = "mag_variable_update_ended"
    public static let beforeMessageUpdate = "mag_before_message_update"
    public static let singleVariableUpdated = "mag_variable_updated"
}

enum RoleplayMVUEventBridge {
    static func emit(
        _ name: String,
        arguments: [Any],
        sessionID: UUID
    ) {
        NotificationCenter.default.post(
            name: RoleplayEventBridge.didEmitNotification,
            object: nil,
            userInfo: [
                RoleplayBridgeNotification.sessionIDKey: sessionID,
                RoleplayBridgeNotification.eventNameKey: name,
                RoleplayEventBridge.argumentsKey: arguments,
                RoleplayEventBridge.sourceKey: "ETOS-native-mvu:\(sessionID.uuidString)"
            ]
        )
    }

    static func variables(_ data: RoleplayMVUData) -> [String: Any] {
        data.variables.mapValues { $0.toAny() }
    }
}
