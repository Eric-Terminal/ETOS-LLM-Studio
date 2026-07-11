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
            pattern: #"```(html|htm|xml)?\s*\n([\s\S]*?)```"#,
            options: [.caseInsensitive]
        ) else { return .init(remainingText: content, documents: []) }
        let source = content as NSString
        let matches = fenceRegex.matches(in: content, range: NSRange(location: 0, length: source.length))
        var documents: [RoleplayHTMLDocument] = []
        let remaining = NSMutableString(string: content)
        for match in matches.reversed() {
            guard match.numberOfRanges > 2 else { continue }
            let languageIsHTML = match.range(at: 1).location != NSNotFound
            let candidate = source.substring(with: match.range(at: 2))
            guard languageIsHTML || isFrontend(candidate) else { continue }
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
            of: #"(?:<!doctype\s+html\b|<html\b|<head\b|<body\b|class\s*=\s*['\"][^'\"]*\bTH-render\b)"#,
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
        variableSnapshot: RoleplayVariableSnapshot? = nil,
        messageID: UUID? = nil,
        messageVersionIndex: Int = 0,
        worldbooks: [Worldbook] = []
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
            variableSnapshot: variableSnapshot,
            messageID: messageID,
            messageVersionIndex: messageVersionIndex,
            worldbooks: worldbooks
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
        variableSnapshot: RoleplayVariableSnapshot?,
        messageID: UUID?,
        messageVersionIndex: Int,
        worldbooks: [Worldbook]
    ) -> String {
        var scopedVariables = Dictionary(uniqueKeysWithValues: RoleplayVariableScope.allCases.map { scope in
            (
                scope.rawValue,
                JSONValue.dictionary(variableSnapshot?.scopedVariables(
                    scope,
                    messageID: messageID,
                    versionIndex: messageVersionIndex
                ) ?? [:])
            )
        })
        if variableSnapshot == nil {
            scopedVariables[RoleplayVariableScope.chat.rawValue] = .dictionary(variables)
        }
        let scopedVariablesJSON = jsonLiteral(.dictionary(scopedVariables))
        let userJSON = jsonString(userName)
        let characterJSON = jsonString(characterName)
        let userAvatarJSON = jsonString(userAvatarPath)
        let characterAvatarJSON = jsonString(characterAvatarPath)
        let worldbooksJSON = encodableJSONLiteral(worldbooks, fallback: "[]")
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
  let scopedVariables = \(scopedVariablesJSON);
  let chatMessages = \(chatMessagesJSON);
  const worldbookList = \(worldbooksJSON);
  const worldbooks = Object.fromEntries(worldbookList.map(book => [book.name, (book.entries || []).map((entry, index) => ({
    ...entry,
    uid: entry.uid ?? index,
    key: entry.keys || entry.key || [],
    keysecondary: entry.secondaryKeys || entry.keysecondary || [],
    enabled: entry.isEnabled ?? entry.enabled ?? !entry.disable,
    disable: !(entry.isEnabled ?? entry.enabled ?? !entry.disable)
  }))]));
  const listeners = new Map();
  const audioState = {
    bgm: { playlist: [], player: null, enabled: true, muted: false, volume: 100 },
    ambient: { playlist: [], player: null, enabled: true, muted: false, volume: 100 }
  };
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
  const deletePath = (root, path) => {
    const parts = pathParts(path);
    if (!parts.length) return false;
    let target = root;
    for (const part of parts.slice(0, -1)) {
      if (target?.[part] == null || typeof target[part] !== 'object') return false;
      target = target[part];
    }
    return delete target[parts.at(-1)];
  };
  const mergeValue = (target, source, overwrite) => {
    for (const [key, value] of Object.entries(source || {})) {
      if (Array.isArray(value)) {
        if (overwrite || !(key in target)) target[key] = clone(value);
      } else if (value && typeof value === 'object') {
        if (!target[key] || typeof target[key] !== 'object' || Array.isArray(target[key])) target[key] = {};
        mergeValue(target[key], value, overwrite);
      } else if (overwrite || !(key in target)) {
        target[key] = clone(value);
      }
    }
    return target;
  };
  const scopeName = option => {
    const value = String(option?.type || 'chat').toLowerCase();
    return value === 'extension' ? 'script' : value;
  };
  const scopeVariables = option => {
    const scope = scopeName(option);
    if (!scopedVariables[scope]) scopedVariables[scope] = {};
    return scopedVariables[scope];
  };
  const rebuildVariables = () => Object.assign(
    {},
    scopedVariables.global || {},
    scopedVariables.preset || {},
    scopedVariables.character || {},
    scopedVariables.persona || {},
    scopedVariables.script || {},
    scopedVariables.chat || {},
    scopedVariables.message || {}
  );
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
  const normalizeMessageId = value => {
    const raw = Number(value);
    return raw < 0 ? chatMessages.length + raw : raw;
  };
  const reindexMessages = () => chatMessages.forEach((message, index) => { message.message_id = index; });
  const nativeWorldbookEntries = entries => entries.map((entry, index) => ({
    ...entry,
    uid: entry.uid ?? index,
    keys: entry.keys || entry.key || [],
    secondaryKeys: entry.secondaryKeys || entry.keysecondary || [],
    isEnabled: entry.enabled ?? !entry.disable
  }));
  const commitWorldbook = (name, entries) => {
    worldbooks[name] = clone(entries || []);
    post({ action: 'replace_worldbook', name, entries: nativeWorldbookEntries(worldbooks[name]) });
  };
  const audioStore = type => audioState[type === 'ambient' ? 'ambient' : 'bgm'];
  const api = {
    getVariables: (option = { type: 'chat' }) => clone(scopeVariables(option)),
    getAllVariables: () => clone(rebuildVariables()),
    replaceVariables: (value, option = { type: 'chat' }) => {
      const scope = scopeName(option);
      scopedVariables[scope] = clone(value || {});
      post({ action: 'replace_variables', scope, value: scopedVariables[scope] });
      return clone(scopedVariables[scope]);
    },
    insertOrAssignVariables: (value, option = { type: 'chat' }) => {
      const scope = scopeName(option);
      const updated = mergeValue(scopeVariables(option), clone(value || {}), true);
      scopedVariables[scope] = updated;
      post({ action: 'replace_variables', scope, value: updated });
      return clone(updated);
    },
    insertVariables: (value, option = { type: 'chat' }) => {
      const scope = scopeName(option);
      const updated = mergeValue(scopeVariables(option), clone(value || {}), false);
      scopedVariables[scope] = updated;
      post({ action: 'replace_variables', scope, value: updated });
      return clone(updated);
    },
    getVariable: (path, fallback = null, option = null) => clone(getPath(option ? scopeVariables(option) : rebuildVariables(), path, fallback)),
    setVariable: (path, value, option = { type: 'chat' }) => {
      const scope = scopeName(option);
      setPath(scopeVariables(option), path, value);
      post({ action: 'set_variable', scope, path, value });
      emitLocal('VARIABLE_UPDATED', path, clone(value));
      return clone(value);
    },
    deleteVariable: (path, option = { type: 'chat' }) => {
      const scope = scopeName(option);
      const delete_occurred = deletePath(scopeVariables(option), path);
      if (delete_occurred) post({ action: 'delete_variable', scope, path });
      return { variables: clone(scopedVariables[scope]), delete_occurred };
    },
    sendMessage: text => post({ action: 'send_message', text: String(text ?? '') }),
    chooseOption: text => post({ action: 'send_message', text: String(text ?? '') }),
    setInput: text => post({ action: 'set_input', text: String(text ?? '') }),
    triggerGeneration: () => post({ action: 'generate' }),
    generate: () => post({ action: 'generate' }),
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
    setChatMessages: async (updates, _options = {}) => {
      const normalized = (updates || []).map(update => ({ ...clone(update), message_id: normalizeMessageId(update.message_id) }));
      for (const update of normalized) {
        const current = chatMessages[update.message_id];
        if (!current) continue;
        Object.assign(current, update);
        if (update.message !== undefined) current.message = String(update.message);
        if (update.data !== undefined) current.data = clone(update.data);
      }
      post({ action: 'set_chat_messages', value: normalized });
    },
    createChatMessages: async (created, options = {}) => {
      const rawIndex = options.insert_at ?? options.insert_before ?? chatMessages.length;
      const insertBefore = rawIndex === 'end' ? chatMessages.length : Math.max(0, Math.min(chatMessages.length, normalizeMessageId(rawIndex)));
      const messages = (created || []).map(item => ({
        name: item.name || (item.role === 'user' ? \(userJSON) : item.role === 'system' ? 'System' : \(characterJSON)),
        role: item.role || 'assistant',
        is_hidden: item.is_hidden || false,
        message: String(item.message ?? ''),
        data: clone(item.data || {}),
        extra: clone(item.extra || {}),
        swipe_id: 0,
        swipes: [String(item.message ?? '')],
        swipes_data: [clone(item.data || {})]
      }));
      chatMessages.splice(insertBefore, 0, ...messages);
      reindexMessages();
      post({ action: 'create_chat_messages', value: messages, insert_before: insertBefore });
      for (let index = insertBefore; index < insertBefore + messages.length; index++) {
        const event = messages[index - insertBefore].role === 'user' ? 'message_sent' : 'message_received';
        await emitLocal(event, index, 'extension');
      }
    },
    deleteChatMessages: async (ids, _options = {}) => {
      const normalized = [...new Set((ids || []).map(normalizeMessageId).filter(index => index >= 0 && index < chatMessages.length))].sort((a, b) => b - a);
      for (const index of normalized) chatMessages.splice(index, 1);
      reindexMessages();
      post({ action: 'delete_chat_messages', value: normalized });
    },
    rotateChatMessages: async (begin, middle, end, _options = {}) => {
      const lower = Math.max(0, Math.min(chatMessages.length, normalizeMessageId(begin)));
      const upper = Math.max(lower, Math.min(chatMessages.length, normalizeMessageId(end)));
      const pivot = Math.max(lower, Math.min(upper, normalizeMessageId(middle)));
      if (lower < pivot && pivot < upper) {
        const range = chatMessages.splice(lower, upper - lower);
        const offset = pivot - lower;
        chatMessages.splice(lower, 0, ...range.slice(offset), ...range.slice(0, offset));
        reindexMessages();
        post({ action: 'rotate_chat_messages', begin: lower, middle: pivot, end: upper });
      }
    },
    setChatMessage: async (value, message_id = -1) => api.setChatMessages([{ message_id, ...(typeof value === 'string' ? { message: value } : value) }]),
    getWorldbookNames: () => Object.keys(worldbooks),
    getWorldbook: async name => {
      if (!(name in worldbooks)) throw new Error(`Worldbook '${name}' was not found`);
      return clone(worldbooks[name]);
    },
    replaceWorldbook: async (name, entries, _options = {}) => {
      if (!(name in worldbooks)) throw new Error(`Worldbook '${name}' was not found`);
      commitWorldbook(name, entries);
    },
    updateWorldbookWith: async (name, updater, options = {}) => {
      const updated = await updater(await api.getWorldbook(name));
      await api.replaceWorldbook(name, updated, options);
      return api.getWorldbook(name);
    },
    createWorldbookEntries: async (name, entries, options = {}) => {
      const existing = await api.getWorldbook(name);
      const created = clone(entries || []);
      await api.replaceWorldbook(name, [...existing, ...created], options);
      const worldbook = await api.getWorldbook(name);
      return { worldbook, new_entries: worldbook.slice(existing.length) };
    },
    deleteWorldbookEntries: async (name, predicate, options = {}) => {
      const existing = await api.getWorldbook(name);
      const deleted_entries = existing.filter(predicate);
      const retained = existing.filter(entry => !deleted_entries.includes(entry));
      await api.replaceWorldbook(name, retained, options);
      return { worldbook: await api.getWorldbook(name), deleted_entries };
    },
    playAudio: (type, audio) => {
      const store = audioStore(type);
      const item = typeof audio === 'string' ? { url: audio } : clone(audio || {});
      if (!item.url) return;
      item.title = item.title || String(item.url).split('/').at(-1)?.split('.')[0] || item.url;
      const index = store.playlist.findIndex(value => value.title === item.title || value.url === item.url);
      if (index >= 0) store.playlist[index] = item; else store.playlist.push(item);
      store.player?.pause();
      store.player = new Audio(item.url);
      store.player.loop = type === 'bgm' || type === 'ambient';
      store.player.muted = store.muted;
      store.player.volume = Math.max(0, Math.min(1, store.volume / 100));
      if (store.enabled) store.player.play().catch(() => {});
    },
    pauseAudio: type => audioStore(type).player?.pause(),
    getAudioList: type => clone(audioStore(type).playlist),
    replaceAudioList: (type, list) => { audioStore(type).playlist = clone(list || []); },
    appendAudioList: (type, list) => { audioStore(type).playlist.push(...clone(list || [])); },
    getAudioSettings: type => {
      const { enabled, muted, volume } = audioStore(type);
      return { enabled, muted, volume };
    },
    setAudioSettings: (type, settings) => {
      const store = audioStore(type);
      Object.assign(store, clone(settings || {}));
      if (store.player) {
        store.player.muted = store.muted;
        store.player.volume = Math.max(0, Math.min(1, store.volume / 100));
        if (!store.enabled) store.player.pause();
      }
    },
    getCharacterName: () => \(characterJSON),
    getUserName: () => \(userJSON),
    userAvatarPath: \(userAvatarJSON),
    charAvatarPath: \(characterAvatarJSON)
  };
  window.etos = api;
  window.TavernHelper = Object.assign(window.TavernHelper || {}, api);
  Object.assign(window, api);
  window.Mvu = window.Mvu || {
    get: path => clone(getPath(rebuildVariables(), path, null)),
    set: (path, value) => api.setVariable(path, value, { type: 'message' }),
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

    private static func encodableJSONLiteral<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let output = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return output
    }
}
