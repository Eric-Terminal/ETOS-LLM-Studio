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
            let scope = variableScope(payload["scope"] as? String)
            Task.detached(priority: .utility) {
                var snapshot = store.variableSnapshot(sessionID: sessionID)
                snapshot.setValue(
                    value,
                    scope: scope,
                    path: path,
                    messageID: messageID,
                    versionIndex: versionIndex
                )
                store.saveVariableSnapshot(snapshot, sessionID: sessionID)
            }
        case "replace_variables":
            guard let dictionary = payload["value"] as? [String: Any] else { return }
            let variables = dictionary.compactMapValues(JSONValue.init(anyJSONValue:))
            let scope = variableScope(payload["scope"] as? String)
            Task.detached(priority: .utility) {
                var snapshot = store.variableSnapshot(sessionID: sessionID)
                snapshot.replaceVariables(
                    variables,
                    scope: scope,
                    messageID: messageID,
                    versionIndex: versionIndex
                )
                store.saveVariableSnapshot(snapshot, sessionID: sessionID)
            }
        case "delete_variable":
            guard let path = payload["path"] as? String else { return }
            let scope = variableScope(payload["scope"] as? String)
            Task.detached(priority: .utility) {
                var snapshot = store.variableSnapshot(sessionID: sessionID)
                snapshot.removeValue(
                    scope: scope,
                    path: path,
                    messageID: messageID,
                    versionIndex: versionIndex
                )
                store.saveVariableSnapshot(snapshot, sessionID: sessionID)
            }
        case "set_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            Task.detached(priority: .utility) {
                ChatService.shared.applyRoleplayMessageUpdates(value, sessionID: sessionID)
            }
        case "create_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            let insertBefore = (payload["insert_before"] as? NSNumber)?.intValue
            Task.detached(priority: .utility) {
                ChatService.shared.createRoleplayMessages(value, insertBefore: insertBefore, sessionID: sessionID)
            }
        case "delete_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            Task.detached(priority: .utility) {
                ChatService.shared.deleteRoleplayMessages(value, sessionID: sessionID)
            }
        case "rotate_chat_messages":
            guard let begin = (payload["begin"] as? NSNumber)?.intValue,
                  let middle = (payload["middle"] as? NSNumber)?.intValue,
                  let end = (payload["end"] as? NSNumber)?.intValue else { return }
            Task.detached(priority: .utility) {
                ChatService.shared.rotateRoleplayMessages(begin: begin, middle: middle, end: end, sessionID: sessionID)
            }
        case "replace_worldbook":
            guard let name = payload["name"] as? String,
                  let entries = payload["entries"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            Task.detached(priority: .utility) {
                ChatService.shared.replaceRoleplayWorldbook(named: name, entries: entries)
            }
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
