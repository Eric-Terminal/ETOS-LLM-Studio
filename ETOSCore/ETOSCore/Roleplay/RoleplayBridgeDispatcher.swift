// ============================================================================
// RoleplayBridgeDispatcher.swift
// ============================================================================
// ETOS LLM Studio
//
// 接收 HTML 卡片动作，更新变量并把发送、填入和生成请求交给聊天界面。
// ============================================================================

import Foundation

public enum RoleplayBridgeNotification {
    public static let requestedAction = Notification.Name("com.ETOS.roleplayBridge.requestedAction")
    public static let sessionIDKey = "sessionID"
    public static let actionKey = "action"
    public static let textKey = "text"
    public static let eventNameKey = "eventName"
}

public enum RoleplayBridgeDispatcher {
    public static func handle(
        _ payload: [String: Any],
        sessionID: UUID,
        messageID: UUID,
        versionIndex: Int,
        store: RoleplayStore = .shared
    ) {
        guard let action = payload["action"] as? String else { return }
        switch action {
        case "set_variable":
            guard let path = payload["path"] as? String,
                  let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            let scope = variableScope(payload["scope"] as? String)
            snapshot.setValue(
                value,
                scope: scope,
                path: path,
                messageID: messageID,
                versionIndex: versionIndex
            )
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "replace_variables":
            guard let dictionary = payload["value"] as? [String: Any] else { return }
            let variables = dictionary.compactMapValues(JSONValue.init(anyJSONValue:))
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            let scope = variableScope(payload["scope"] as? String)
            if scope == .message {
                snapshot.replaceMessageVariables(variables, messageID: messageID, versionIndex: versionIndex)
            } else {
                for (key, value) in variables {
                    snapshot.setValue(value, scope: scope, path: key, messageID: messageID, versionIndex: versionIndex)
                }
            }
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "send_message", "set_input", "generate", "event":
            NotificationCenter.default.post(
                name: RoleplayBridgeNotification.requestedAction,
                object: nil,
                userInfo: [
                    RoleplayBridgeNotification.sessionIDKey: sessionID,
                    RoleplayBridgeNotification.actionKey: action,
                    RoleplayBridgeNotification.textKey: payload["text"] as? String ?? "",
                    RoleplayBridgeNotification.eventNameKey: payload["name"] as? String ?? ""
                ]
            )
        default:
            return
        }
    }

    private static func variableScope(_ raw: String?) -> RoleplayVariableScope {
        switch raw?.lowercased() {
        case "global": return .global
        case "preset": return .preset
        case "character": return .character
        case "persona": return .persona
        case "message": return .message
        case "script": return .script
        default: return .chat
        }
    }
}
