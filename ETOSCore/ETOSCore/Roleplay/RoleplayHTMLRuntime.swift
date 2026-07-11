// ============================================================================
// RoleplayHTMLRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 识别酒馆助手前端代码块，并生成含 ETOS/TavernHelper 兼容桥的 HTML 文档。
// ============================================================================

import Foundation

public struct RoleplayHTMLDocument: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var source: String

    public init(id: Int, source: String) {
        self.id = id
        self.source = source
    }
}

public struct RoleplayHTMLExtraction: Codable, Hashable, Sendable {
    public var remainingText: String
    public var documents: [RoleplayHTMLDocument]

    public init(remainingText: String, documents: [RoleplayHTMLDocument]) {
        self.remainingText = remainingText
        self.documents = documents
    }

    public var containsHTML: Bool { !documents.isEmpty }
}

public enum RoleplayHTMLExtractor {
    public static func extract(from content: String) -> RoleplayHTMLExtraction {
        guard isFrontend(content) || content.contains("```") else {
            return .init(remainingText: content, documents: [])
        }
        guard let fenceRegex = try? NSRegularExpression(
            pattern: #"```(?:html|htm|xml)?\s*\n([\s\S]*?)```"#,
            options: [.caseInsensitive]
        ) else { return .init(remainingText: content, documents: []) }
        let source = content as NSString
        let matches = fenceRegex.matches(in: content, range: NSRange(location: 0, length: source.length))
        var documents: [RoleplayHTMLDocument] = []
        let remaining = NSMutableString(string: content)
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let candidate = source.substring(with: match.range(at: 1))
            guard isFrontend(candidate) else { continue }
            documents.insert(.init(id: match.range.location, source: candidate), at: 0)
            remaining.replaceCharacters(in: match.range, with: "")
        }
        if documents.isEmpty, isFrontend(content) {
            return .init(remainingText: "", documents: [.init(id: 0, source: content)])
        }
        return .init(
            remainingText: (remaining as String).trimmingCharacters(in: .whitespacesAndNewlines),
            documents: documents
        )
    }

    public static func isFrontend(_ content: String) -> Bool {
        content.range(
            of: #"(?:<html\b|<head\b|<body\b|class\s*=\s*['\"][^'\"]*\bTH-render\b|<script\b|<style\b|<div\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

public enum RoleplayHTMLDocumentFactory {
    public static func makeDocument(
        source: String,
        variables: [String: JSONValue],
        userName: String,
        characterName: String,
        userAvatarPath: String,
        characterAvatarPath: String,
        chatMessages: [ChatMessage] = [],
        variableSnapshot: RoleplayVariableSnapshot? = nil
    ) -> String {
        let body: String
        if source.range(of: #"<html\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            body = source
        } else {
            body = "<!doctype html><html><head></head><body>\(source)</body></html>"
        }
        let bootstrap = bridgeBootstrap(
            variables: variables,
            userName: userName,
            characterName: characterName,
            userAvatarPath: userAvatarPath,
            characterAvatarPath: characterAvatarPath,
            chatMessages: chatMessages,
            variableSnapshot: variableSnapshot
        )
        let headInjection = """
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0, user-scalable=yes">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css">
<script src="https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/vue@3.5.13/dist/vue.global.prod.js"></script>
<script src="https://cdn.jsdelivr.net/npm/yaml@2.7.0/browser/dist/index.js"></script>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  :root { color-scheme: light dark; }
  html, body { margin: 0; padding: 0; width: 100%; min-height: 1px; background: transparent; overflow-x: hidden; }
  *, *::before, *::after { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; overflow-wrap: anywhere; }
</style>
<script>\(bootstrap)</script>
"""
        if let headRange = body.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return body.replacingCharacters(in: headRange, with: "\(body[headRange])\n\(headInjection)")
        }
        return "\(headInjection)\n\(body)"
    }

    private static func bridgeBootstrap(
        variables: [String: JSONValue],
        userName: String,
        characterName: String,
        userAvatarPath: String,
        characterAvatarPath: String,
        chatMessages: [ChatMessage],
        variableSnapshot: RoleplayVariableSnapshot?
    ) -> String {
        let variablesJSON = jsonLiteral(.dictionary(variables))
        let userJSON = jsonString(userName)
        let characterJSON = jsonString(characterName)
        let userAvatarJSON = jsonString(userAvatarPath)
        let characterAvatarJSON = jsonString(characterAvatarPath)
        let chatMessagesJSON = jsonLiteral(.array(chatMessages.enumerated().map { index, message in
            let role: String
            let name: String
            switch message.role {
            case .user:
                role = "user"
                name = userName
            case .assistant:
                role = "assistant"
                name = characterName
            case .system:
                role = "system"
                name = "System"
            case .tool:
                role = "system"
                name = "Tool"
            case .error:
                role = "system"
                name = "Error"
            }
            let currentVersion = message.getCurrentVersionIndex()
            let currentData = variableSnapshot?.messageVariables(
                messageID: message.id,
                versionIndex: currentVersion
            ) ?? [:]
            let allData = message.getAllVersions().indices.map { version in
                JSONValue.dictionary(variableSnapshot?.messageVariables(messageID: message.id, versionIndex: version) ?? [:])
            }
            return .dictionary([
                "message_id": .int(index),
                "name": .string(name),
                "role": .string(role),
                "is_hidden": .bool(message.role == .system || message.role == .tool),
                "message": .string(message.content),
                "data": .dictionary(currentData),
                "extra": .dictionary([:]),
                "swipe_id": .int(currentVersion),
                "swipes": .array(message.getAllVersions().map(JSONValue.string)),
                "swipes_data": .array(allData)
            ])
        }))
        return """
(function () {
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  let variables = \(variablesJSON);
  const chatMessages = \(chatMessagesJSON);
  const listeners = new Map();
  const post = payload => {
    try { window.webkit?.messageHandlers?.etosRoleplay?.postMessage(payload); } catch (_) {}
  };
  const pathParts = path => String(path || '').replaceAll('[', '.').replaceAll(']', '').split('.').filter(Boolean);
  const getPath = (root, path, fallback = null) => {
    let value = root;
    for (const part of pathParts(path)) {
      if (value == null || !(part in Object(value))) return fallback;
      value = value[part];
    }
    return value;
  };
  const setPath = (root, path, value) => {
    const parts = pathParts(path);
    if (!parts.length) return;
    let target = root;
    parts.slice(0, -1).forEach(part => {
      if (target[part] == null || typeof target[part] !== 'object') target[part] = {};
      target = target[part];
    });
    target[parts.at(-1)] = clone(value);
  };
  const emitLocal = async (type, ...args) => {
    for (const listener of listeners.get(type) || []) await listener(...args);
    window.dispatchEvent(new CustomEvent('etos:' + type, { detail: args }));
  };
  const normalizeMessageRange = range => {
    if (range === undefined || range === null || range === 'all') return [0, chatMessages.length - 1];
    if (typeof range === 'number') {
      const index = range < 0 ? chatMessages.length + range : range;
      return [index, index];
    }
    const text = String(range);
    if (/^-?\\d+$/.test(text)) {
      const raw = Number(text);
      const index = raw < 0 ? chatMessages.length + raw : raw;
      return [index, index];
    }
    const match = text.match(/^(-?\\d+)-(-?\\d+)$/);
    if (!match) return [0, chatMessages.length - 1];
    const values = match.slice(1).map(Number).map(value => value < 0 ? chatMessages.length + value : value).sort((a, b) => a - b);
    return values;
  };
  const api = {
    getVariables: (_option = { type: 'chat' }) => clone(variables),
    getAllVariables: () => clone(variables),
    replaceVariables: (value, option = { type: 'chat' }) => {
      variables = clone(value || {});
      post({ action: 'replace_variables', scope: option.type || 'chat', value: variables });
    },
    insertOrAssignVariables: (value, option = { type: 'chat' }) => {
      variables = Object.assign(variables, clone(value || {}));
      post({ action: 'replace_variables', scope: option.type || 'chat', value: variables });
      return clone(variables);
    },
    getVariable: (path, fallback = null) => clone(getPath(variables, path, fallback)),
    setVariable: (path, value, option = { type: 'chat' }) => {
      setPath(variables, path, value);
      post({ action: 'set_variable', scope: option.type || 'chat', path, value });
      emitLocal('VARIABLE_UPDATED', path, clone(value));
      return clone(value);
    },
    sendMessage: text => post({ action: 'send_message', text: String(text ?? '') }),
    chooseOption: text => post({ action: 'send_message', text: String(text ?? '') }),
    setInput: text => post({ action: 'set_input', text: String(text ?? '') }),
    triggerGeneration: () => post({ action: 'generate' }),
    eventOn: (type, listener) => {
      const values = listeners.get(type) || [];
      values.push(listener);
      listeners.set(type, values);
      return { stop: () => listeners.set(type, (listeners.get(type) || []).filter(item => item !== listener)) };
    },
    eventOnce: (type, listener) => {
      const wrapped = (...args) => { listener(...args); api.eventOff(type, wrapped); };
      return api.eventOn(type, wrapped);
    },
    eventOff: (type, listener) => listeners.set(type, (listeners.get(type) || []).filter(item => item !== listener)),
    eventEmit: async (type, ...args) => { await emitLocal(type, ...args); post({ action: 'event', name: type, value: args }); },
    getCurrentMessageId: () => Math.max(-1, chatMessages.length - 1),
    getChatMessages: (range = 'all', options = {}) => {
      const [start, end] = normalizeMessageRange(range);
      return clone(chatMessages.slice(Math.max(0, start), Math.min(chatMessages.length - 1, end) + 1).filter(message => {
        if (options.role && options.role !== 'all' && options.role !== message.role) return false;
        if (options.hide_state === 'hidden' && !message.is_hidden) return false;
        if (options.hide_state === 'unhidden' && message.is_hidden) return false;
        return true;
      }));
    },
    getDisplayedMessages: (range = 'all', options = {}) => api.getChatMessages(range, options),
    getCharacterName: () => \(characterJSON),
    getUserName: () => \(userJSON),
    userAvatarPath: \(userAvatarJSON),
    charAvatarPath: \(characterAvatarJSON)
  };
  window.etos = api;
  window.TavernHelper = Object.assign(window.TavernHelper || {}, api);
  Object.assign(window, api);
  window.Mvu = window.Mvu || {
    get: path => api.getVariable(path),
    set: (path, value) => api.setVariable(path, value),
    variables: () => api.getAllVariables()
  };
  window.SillyTavern = window.SillyTavern || { getContext: () => ({ name1: \(userJSON), name2: \(characterJSON) }) };
  const reportHeight = () => post({ action: 'height', value: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 1) });
  window.addEventListener('DOMContentLoaded', () => {
    reportHeight();
    new ResizeObserver(reportHeight).observe(document.documentElement);
    emitLocal('MESSAGE_IFRAME_RENDER_STARTED');
    requestAnimationFrame(() => emitLocal('MESSAGE_IFRAME_RENDER_ENDED'));
    emitLocal('app_ready');
    emitLocal('chat_id_changed');
    const last = chatMessages.at(-1);
    if (last?.role === 'user') emitLocal('message_sent', last.message_id);
    if (last?.role === 'assistant') {
      emitLocal('message_received', last.message_id);
      emitLocal('character_message_rendered', last.message_id);
    }
  });
})();
"""
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let output = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return output
    }

    private static func jsonLiteral(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value), let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }
}
