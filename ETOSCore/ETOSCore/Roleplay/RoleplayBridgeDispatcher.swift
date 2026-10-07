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
    public static let completedRequest = Notification.Name("com.ETOS.roleplayBridge.completedRequest")
    public static let sessionIDKey = "sessionID"
    public static let actionKey = "action"
    public static let textKey = "text"
    public static let eventNameKey = "eventName"
    public static let requestIDKey = "requestID"
    public static let resultKey = "result"
    public static let errorKey = "error"
}

public enum RoleplayDisplayedMessageBridge {
    public static let variableKey = "__etos_displayed_html"
    public static let didChangeNotification = Notification.Name("com.ETOS.roleplayDisplayedMessage.didChange")

    public static func postDidChange(sessionID: UUID) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [RoleplayBridgeNotification.sessionIDKey: sessionID]
        )
    }
}

public enum RoleplayEventBridge {
    public static let didEmitNotification = Notification.Name("com.ETOS.roleplayEvent.didEmit")
    public static let argumentsKey = "arguments"
    public static let sourceKey = "source"
}

public enum RoleplayBridgeDispatcher {
    private static let mutationQueue = RoleplayBridgeOperationQueue()

    /// 返回任务覆盖动作执行和异步生成；消息落盘仍须等待 Persistence 的写入屏障。
    @discardableResult
    public static func handle(
        _ payload: [String: Any],
        sessionID: UUID,
        messageID: UUID,
        versionIndex: Int,
        store: RoleplayStore = .shared,
        service: ChatService? = nil,
        validateSource: @escaping @Sendable () -> Bool = { true }
    ) -> Task<Void, Never> {
        let submitted = RoleplayBridgeSubmittedPayload(values: payload)
        let operation: @Sendable () async -> Void = {
            guard !Task.isCancelled else { return }
            guard validateSource() else {
                if submitted.values["action"] as? String == "generate_text",
                   let requestID = submitted.values["request_id"] as? String {
                    postGenerationResult(nil, error: RoleplayDraftWriteError.changedExternally.localizedDescription,
                                         requestID: requestID, sessionID: sessionID)
                }
                return
            }
            guard !Task.isCancelled else { return }
            await dispatch(submitted.values, sessionID: sessionID, messageID: messageID,
                           versionIndex: versionIndex, store: store, service: service ?? .shared)
        }
        // 生成会等待网页返回宏和提示词；这些响应不能排在生成后面，否则形成互相等待。
        if let action = payload["action"] as? String,
           ["generate_text", "macro_expansion_response", "prompt_mutation_response"].contains(action) {
            return Task.detached(priority: .utility, operation: operation)
        }
        return mutationQueue.enqueue(operation)
    }

    private static func dispatch(
        _ payload: [String: Any], sessionID: UUID, messageID: UUID, versionIndex: Int,
        store: RoleplayStore, service: ChatService
    ) async {
        guard let action = payload["action"] as? String else { return }
        switch action {
        case "set_variable":
            guard let path = payload["path"] as? String,
                  let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            let scope = variableScope(payload["scope"] as? String)
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            snapshot.setValue(value, scope: scope, path: path, messageID: messageID, versionIndex: versionIndex)
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "replace_variables":
            guard let dictionary = payload["value"] as? [String: Any] else { return }
            let variables = dictionary.compactMapValues(JSONValue.init(anyJSONValue:))
            let scope = variableScope(payload["scope"] as? String)
            let scriptID = (payload["script_id"] as? String).flatMap(UUID.init(uuidString:))
            let extensionID = payload["extension_id"] as? String
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            if scope == .script, let scriptID {
                snapshot.replaceScriptVariables(variables, scriptID: scriptID)
            } else if let extensionID, !extensionID.isEmpty {
                snapshot.replaceExtensionVariables(variables, extensionID: extensionID)
            } else {
                snapshot.replaceVariables(variables, scope: scope, messageID: messageID, versionIndex: versionIndex)
            }
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "replace_message_variables":
            guard let dictionary = payload["value"] as? [String: Any],
                  let messageIndex = (payload["message_id"] as? NSNumber)?.intValue else { return }
            let variables = dictionary.compactMapValues(JSONValue.init(anyJSONValue:))
            let swipeIndex = (payload["swipe_id"] as? NSNumber)?.intValue ?? 0
            let messages = service.messagesSnapshot(for: sessionID)
            guard messages.indices.contains(messageIndex) else { return }
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            snapshot.replaceVariables(variables, scope: .message, messageID: messages[messageIndex].id, versionIndex: swipeIndex)
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "delete_variable":
            guard let path = payload["path"] as? String else { return }
            let scope = variableScope(payload["scope"] as? String)
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            snapshot.removeValue(scope: scope, path: path, messageID: messageID, versionIndex: versionIndex)
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        case "set_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.applyRoleplayMessageUpdates(value, sessionID: sessionID)
        case "create_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            let insertBefore = (payload["insert_before"] as? NSNumber)?.intValue
            service.createRoleplayMessages(value, insertBefore: insertBefore, sessionID: sessionID)
        case "delete_chat_messages":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.deleteRoleplayMessages(value, sessionID: sessionID)
        case "rotate_chat_messages":
            guard let begin = (payload["begin"] as? NSNumber)?.intValue,
                  let middle = (payload["middle"] as? NSNumber)?.intValue,
                  let end = (payload["end"] as? NSNumber)?.intValue else { return }
            service.rotateRoleplayMessages(begin: begin, middle: middle, end: end, sessionID: sessionID)
        case "replace_worldbook":
            guard let name = payload["name"] as? String,
                  let entries = payload["entries"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.replaceRoleplayWorldbook(named: name, entries: entries)
        case "create_worldbook":
            guard let name = payload["name"] as? String else { return }
            service.createRoleplayWorldbook(named: name)
        case "delete_worldbook":
            guard let name = payload["name"] as? String else { return }
            service.deleteRoleplayWorldbook(named: name)
        case "rebind_character_worldbooks":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.rebindRoleplayCharacterWorldbooks(value, sessionID: sessionID)
        case "replace_regex_rules":
            guard let value = payload["value"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.replaceRoleplayRegexRules(value, sessionID: sessionID)
        case "set_displayed_message":
            guard let messageIndex = (payload["message_id"] as? NSNumber)?.intValue,
                  let html = payload["html"] as? String else { return }
            let messages = service.messagesSnapshot(for: sessionID)
            guard messages.indices.contains(messageIndex) else { return }
            let target = messages[messageIndex]
            var snapshot = store.variableSnapshot(sessionID: sessionID)
            snapshot.setValue(.string(html), scope: .message, path: RoleplayDisplayedMessageBridge.variableKey,
                              messageID: target.id, versionIndex: target.getCurrentVersionIndex())
            store.saveVariableSnapshot(snapshot, sessionID: sessionID)
            RoleplayDisplayedMessageBridge.postDidChange(sessionID: sessionID)
        case "replace_script_buttons":
            guard let scriptID = (payload["script_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let buttons = payload["buttons"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            service.replaceRoleplayScriptButtons(scriptID: scriptID, buttons: buttons)
        case "generate_text":
            guard let requestID = payload["request_id"] as? String,
                  let config = payload["config"].flatMap(JSONValue.init(anyJSONValue:)) else { return }
            let raw = (payload["raw"] as? Bool) ?? false
            do {
                let result = try await service.generateRoleplayCompletion(config: config, raw: raw, sessionID: sessionID, store: store)
                guard !Task.isCancelled else { return }
                postGenerationResult(result, error: nil, requestID: requestID, sessionID: sessionID)
            } catch {
                guard !Task.isCancelled else { return }
                postGenerationResult(nil, error: error.localizedDescription, requestID: requestID, sessionID: sessionID)
            }
        case "macro_expansion_response":
            guard let requestID = payload["request_id"] as? String,
                  let text = payload["text"] as? String else { return }
            await RoleplayMacroExpansionBridge.shared.receive(requestID: requestID, text: text)
        case "prompt_mutation_response":
            guard let requestID = payload["request_id"] as? String,
                  let prompt = payload["prompt"] as? [[String: Any]] else { return }
            let contents = prompt.compactMap { $0["content"] as? String }
            guard contents.count == prompt.count else { return }
            await RoleplayPromptMutationBridge.shared.receive(requestID: requestID, contents: contents)
        case "event":
            guard let name = payload["name"] as? String else { return }
            NotificationCenter.default.post(
                name: RoleplayEventBridge.didEmitNotification,
                object: nil,
                userInfo: [
                    RoleplayBridgeNotification.sessionIDKey: sessionID,
                    RoleplayBridgeNotification.eventNameKey: name,
                    RoleplayEventBridge.argumentsKey: payload["value"] as? [Any] ?? [],
                    RoleplayEventBridge.sourceKey: payload["source"] as? String ?? ""
                ]
            )
        case "send_message", "set_input", "generate":
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

    private static func postGenerationResult(
        _ result: String?,
        error: String?,
        requestID: String,
        sessionID: UUID
    ) {
        var userInfo: [String: Any] = [
            RoleplayBridgeNotification.sessionIDKey: sessionID,
            RoleplayBridgeNotification.requestIDKey: requestID
        ]
        if let result { userInfo[RoleplayBridgeNotification.resultKey] = result }
        if let error { userInfo[RoleplayBridgeNotification.errorKey] = error }
        NotificationCenter.default.post(
            name: RoleplayBridgeNotification.completedRequest,
            object: nil,
            userInfo: userInfo
        )
    }
}
