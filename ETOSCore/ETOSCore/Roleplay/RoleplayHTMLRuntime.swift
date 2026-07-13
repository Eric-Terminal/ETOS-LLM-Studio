// ============================================================================
// RoleplayHTMLRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 识别酒馆助手前端代码块，并生成含 ETOS/TavernHelper 兼容桥的 HTML 文档。
// ============================================================================

import Foundation

public enum RoleplayScriptButtonNotification {
    public static let requested = Notification.Name("com.ETOS.roleplayScriptButton.requested")
    public static let sessionIDKey = "sessionID"
    public static let scriptIDKey = "scriptID"
    public static let buttonNameKey = "buttonName"
}

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

/// 从显示变换结果中提取本地 Widget；不创建模型工具调用，也不改写持久化消息。
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
        let remaining = NSMutableString()
        var cursor = 0

        // 酒馆正则经常在同一条回复中混合裸 HTML 与 HTML 围栏；两者都应由 App 本地承载，不能留给 Markdown。
        func appendOutsideFence(_ range: NSRange) {
            guard range.length > 0 else { return }
            let segment = source.substring(with: range)
            guard let frontendRange = firstFrontendRange(in: segment) else {
                remaining.append(segment)
                return
            }
            let segmentSource = segment as NSString
            remaining.append(segmentSource.substring(to: frontendRange.location))
            documents.append(RoleplayHTMLDocument(
                id: range.location + frontendRange.location,
                source: segmentSource.substring(from: frontendRange.location)
            ))
        }

        for match in matches {
            guard match.numberOfRanges > 2 else { continue }
            appendOutsideFence(NSRange(location: cursor, length: match.range.location - cursor))
            let languageIsHTML = match.range(at: 1).location != NSNotFound
            let candidate = source.substring(with: match.range(at: 2))
            if languageIsHTML || isFrontend(candidate) {
                documents.append(.init(id: match.range.location, source: candidate))
            } else {
                remaining.append(source.substring(with: match.range))
            }
            cursor = NSMaxRange(match.range)
        }
        appendOutsideFence(NSRange(location: cursor, length: source.length - cursor))
        documents.sort { $0.id < $1.id }
        return .init(
            remainingText: (remaining as String).trimmingCharacters(in: .whitespacesAndNewlines),
            documents: documents
        )
    }

    public static func isFrontend(_ content: String) -> Bool {
        firstFrontendRange(in: content) != nil
    }

    private static func firstFrontendRange(in content: String) -> NSRange? {
        let fullRange = NSRange(location: 0, length: (content as NSString).length)
        let tagPattern = #"(?:<!doctype\s+html\b|<(?:html|head|body|style|script|div|section|article|main|details|table|form|img|svg|canvas|video|audio|iframe)\b)"#
        let classPattern = #"class\s*=\s*['\"][^'\"]*\bTH-render\b"#
        let tagRange = (try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]))?
            .firstMatch(in: content, range: fullRange)?.range
        let classRange = (try? NSRegularExpression(pattern: classPattern, options: [.caseInsensitive]))?
            .firstMatch(in: content, range: fullRange)?.range

        var classTagRange: NSRange?
        if let classRange {
            let prefix = (content as NSString).substring(to: classRange.location) as NSString
            let openingTag = prefix.range(of: "<", options: .backwards)
            if openingTag.location != NSNotFound {
                classTagRange = NSRange(location: openingTag.location, length: 1)
            }
        }
        return [tagRange, classTagRange]
            .compactMap { $0 }
            .min { $0.location < $1.location }
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
        characterAssets: [RoleplayCardAsset] = [],
        regexRules: [RoleplayRegexRule] = [],
        chatMessages: [ChatMessage] = [],
        variableSnapshot: RoleplayVariableSnapshot? = nil,
        messageID: UUID? = nil,
        messageVersionIndex: Int = 0,
        documentID: Int = 0,
        worldbooks: [Worldbook] = [],
        primaryWorldbookName: String? = nil,
        additionalWorldbookNames: [String] = [],
        scriptID: UUID? = nil,
        scriptName: String = "",
        scriptInfo: String = "",
        scriptButtons: [RoleplayScriptButton] = [],
        scriptInitialVariables: [String: JSONValue] = [:]
    ) -> String {
        let resolvedSource = RoleplayAssetStore.replacingAssetURIs(in: source, assets: characterAssets)
        let body: String
        if resolvedSource.range(of: #"<html\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            body = resolvedSource
        } else {
            body = "<!doctype html><html><head></head><body>\(resolvedSource)</body></html>"
        }
        let bootstrap = bridgeBootstrap(
            variables: variables,
            userName: userName,
            characterName: characterName,
            userAvatarPath: userAvatarPath,
            characterAvatarPath: characterAvatarPath,
            characterAssets: characterAssets,
            regexRules: regexRules,
            chatMessages: chatMessages,
            variableSnapshot: variableSnapshot,
            messageID: messageID,
            messageVersionIndex: messageVersionIndex,
            documentID: documentID,
            worldbooks: worldbooks,
            primaryWorldbookName: primaryWorldbookName,
            additionalWorldbookNames: additionalWorldbookNames,
            scriptID: scriptID,
            scriptName: scriptName,
            scriptInfo: scriptInfo,
            scriptButtons: scriptButtons,
            scriptInitialVariables: scriptInitialVariables
        ) + "\n" + RoleplayHTMLCompatibilityRuntime.source
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
        characterAssets: [RoleplayCardAsset],
        regexRules: [RoleplayRegexRule],
        chatMessages: [ChatMessage],
        variableSnapshot: RoleplayVariableSnapshot?,
        messageID: UUID?,
        messageVersionIndex: Int,
        documentID: Int,
        worldbooks: [Worldbook],
        primaryWorldbookName: String?,
        additionalWorldbookNames: [String],
        scriptID: UUID?,
        scriptName: String,
        scriptInfo: String,
        scriptButtons: [RoleplayScriptButton],
        scriptInitialVariables: [String: JSONValue]
    ) -> String {
        var scopedVariables = Dictionary(uniqueKeysWithValues: RoleplayVariableScope.allCases.map { scope in
            if scope == .script, let scriptID, let variableSnapshot {
                var stored = variableSnapshot.scriptVariables(scriptID: scriptID)
                stored.merge(scriptInitialVariables) { existing, _ in existing }
                return (scope.rawValue, JSONValue.dictionary(stored))
            }
            return (
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
        let scriptScopesJSON = jsonLiteral(.dictionary(
            (variableSnapshot?.allScriptVariables ?? [:]).mapValues(JSONValue.dictionary)
        ))
        let extensionScopesJSON = jsonLiteral(.dictionary(
            (variableSnapshot?.extensionScopes ?? [:]).mapValues(JSONValue.dictionary)
        ))
        let userJSON = jsonString(userName)
        let characterJSON = jsonString(characterName)
        let userAvatarJSON = jsonString(userAvatarPath)
        let characterAvatarJSON = jsonString(characterAvatarPath)
        let resolvedCharacterAssets = characterAssets.map { asset in
            var value = asset
            if asset.localFileName != nil, let url = RoleplayAssetStore.resolvedURL(for: asset) {
                value.uri = url.absoluteString
            }
            return value
        }
        let characterAssetsJSON = encodableJSONLiteral(resolvedCharacterAssets, fallback: "[]")
        let regexRulesJSON = encodableJSONLiteral(regexRules, fallback: "[]")
        let worldbooksJSON = encodableJSONLiteral(worldbooks, fallback: "[]")
        let primaryWorldbookJSON = primaryWorldbookName.map(jsonString) ?? "null"
        let additionalWorldbooksJSON = encodableJSONLiteral(additionalWorldbookNames, fallback: "[]")
        let scriptIDJSON = jsonString(scriptID?.uuidString ?? "")
        let scriptNameJSON = jsonString(scriptName)
        let scriptInfoJSON = jsonString(scriptInfo)
        let scriptButtonsJSON = encodableJSONLiteral(scriptButtons, fallback: "[]")
        let currentMessageIndex = messageID.flatMap { id in chatMessages.firstIndex(where: { $0.id == id }) }
            ?? max(-1, chatMessages.count - 1)
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
            var fields: [String: JSONValue] = [
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
            ]
            if case .string(let displayedHTML) = variableSnapshot?.value(
                scope: .message,
                path: RoleplayDisplayedMessageBridge.variableKey,
                messageID: message.id,
                versionIndex: currentVersion
            ) {
                fields["displayed_html"] = .string(displayedHTML)
            }
            return .dictionary(fields)
        }))
        return """
(function () {
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  let scopedVariables = \(scopedVariablesJSON);
  let scriptVariableScopes = \(scriptScopesJSON);
  let extensionVariableScopes = \(extensionScopesJSON);
  let chatMessages = \(chatMessagesJSON);
  const worldbookList = \(worldbooksJSON);
  let currentCharacterWorldbooks = {
    primary: \(primaryWorldbookJSON),
    additional: \(additionalWorldbooksJSON)
  };
  const currentScriptID = \(scriptIDJSON);
  if (currentScriptID && !scriptVariableScopes[currentScriptID]) {
    scriptVariableScopes[currentScriptID] = clone(scopedVariables.script || {});
  }
  const currentMessageIndex = \(currentMessageIndex);
  const currentScriptName = \(scriptNameJSON);
  const currentIframeName = currentScriptID
    ? `TH-script--${String(currentScriptName || 'ETOS').replace(/[^a-z0-9_-]/gi, '_')}--${currentScriptID}`
    : `TH-message--${Math.max(0, currentMessageIndex)}--\(documentID)`;
  let currentScriptInfo = \(scriptInfoJSON);
  let currentScriptButtons = \(scriptButtonsJSON);
  let roleplayRegexRules = \(regexRulesJSON);
  const helperPosition = value => ({
    before: 'before_character_definition', after: 'after_character_definition',
    anTop: 'before_author_note', anBottom: 'after_author_note',
    emTop: 'before_example_messages', emBottom: 'after_example_messages',
    atDepth: 'at_depth', outlet: 'at_depth'
  })[value] || 'after_character_definition';
  const helperLogic = value => ({ AND_ANY: 'and_any', AND_ALL: 'and_all', NOT_ANY: 'not_any', NOT_ALL: 'not_all' })[value] || 'and_any';
  const helperWorldbookEntry = (entry, index) => ({
    uid: entry.uid ?? index,
    name: entry.comment || entry.name || '',
    enabled: entry.isEnabled ?? entry.enabled ?? !entry.disable,
    strategy: {
      type: entry.constant ? 'constant' : (entry.metadata?.extensions?.vectorized || entry.metadata?.vectorized) ? 'vectorized' : 'selective',
      keys: clone(entry.keys || entry.key || []),
      keys_secondary: {
        logic: helperLogic(entry.selectiveLogic),
        keys: clone(entry.secondaryKeys || entry.keysecondary || [])
      },
      scan_depth: entry.scanDepth ?? 'same_as_global'
    },
    position: {
      type: helperPosition(entry.position),
      role: String(entry.role || 'SYSTEM').toLowerCase(),
      depth: entry.depth ?? 0,
      order: entry.order ?? 100
    },
    content: String(entry.content || ''),
    probability: entry.useProbability === false ? 100 : (entry.probability ?? 100),
    recursion: {
      prevent_incoming: !!entry.excludeRecursion,
      prevent_outgoing: !!entry.preventRecursion,
      delay_until: entry.metadata?.extensions?.delay_until_recursion ?? (entry.delayUntilRecursion ? 1 : null)
    },
    effect: { sticky: entry.sticky ?? null, cooldown: entry.cooldown ?? null, delay: entry.delay ?? null },
    extra: clone(entry.metadata || {})
  });
  const completeHelperWorldbookEntry = (entry, uid) => ({
    uid,
    name: '',
    enabled: true,
    content: '',
    probability: 100,
    extra: {},
    ...(clone(entry || {})),
    strategy: {
      type: 'selective', keys: [],
      keys_secondary: { logic: 'and_any', keys: [] },
      scan_depth: 'same_as_global',
      ...(clone(entry?.strategy || {})),
      keys_secondary: {
        logic: 'and_any', keys: [],
        ...(clone(entry?.strategy?.keys_secondary || {}))
      }
    },
    position: { type: 'after_character_definition', role: 'system', depth: 0, order: 100, ...(clone(entry?.position || {})) },
    recursion: { prevent_incoming: false, prevent_outgoing: false, delay_until: null, ...(clone(entry?.recursion || {})) },
    effect: { sticky: null, cooldown: null, delay: null, ...(clone(entry?.effect || {})) },
    uid
  });
  const worldbooks = Object.fromEntries(worldbookList.map(book => [
    book.name,
    (book.entries || []).map(helperWorldbookEntry)
  ]));
  const listeners = new Map();
  const macroLikeRules = [];
  const audioState = {
    bgm: { playlist: [], player: null, enabled: true, muted: false, volume: 100 },
    ambient: { playlist: [], player: null, enabled: true, muted: false, volume: 100 }
  };
  const post = payload => {
    try { window.webkit?.messageHandlers?.etosRoleplay?.postMessage(payload); } catch (_) {}
  };
  const pathParts = path => {
    if (Array.isArray(path)) return path.map(String);
    const source = String(path || '');
    const result = [];
    let index = 0;
    while (index < source.length) {
      if (source[index] === '.') { index += 1; continue; }
      if (source[index] === '[') {
        index += 1;
        while (/\\s/.test(source[index] || '')) index += 1;
        let value = '';
        const quote = source[index] === '"' || source[index] === "'" ? source[index++] : null;
        while (index < source.length) {
          const character = source[index++];
          if (quote && character === '\\' && index < source.length) { value += source[index++]; continue; }
          if ((quote && character === quote) || (!quote && character === ']')) break;
          value += character;
        }
        while (index < source.length && source[index] !== ']') index += 1;
        if (source[index] === ']') index += 1;
        if (value.trim()) result.push(value.trim());
        continue;
      }
      let value = '';
      while (index < source.length && source[index] !== '.' && source[index] !== '[') value += source[index++];
      value = value.trim().replace(/^(["'])(.*)\\1$/, '$2');
      if (value) result.push(value);
    }
    return result;
  };
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
    if (!parts.length) {
      if (value && typeof value === 'object') Object.assign(root, clone(value));
      return;
    }
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
    const key = parts.at(-1);
    if (Array.isArray(target) && /^\\d+$/.test(key)) {
      const index = Number(key);
      if (index < 0 || index >= target.length) return false;
      target.splice(index, 1);
      return true;
    }
    return delete target[key];
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
    return value;
  };
  const messageIndex = option => {
    if (option?.message_id === undefined || option?.message_id === 'latest') {
      for (let index = chatMessages.length - 1; index >= 0; index--) {
        if (chatMessages[index]?.role !== 'system') return index;
      }
      return chatMessages.length - 1;
    }
    const raw = Number(option.message_id);
    if (!Number.isInteger(raw) || raw < -chatMessages.length || raw >= chatMessages.length) {
      throw new Error(`Message '${option.message_id}' is outside [-${chatMessages.length}, ${chatMessages.length})`);
    }
    return normalizeMessageId(raw);
  };
  const scopeVariables = option => {
    const scope = scopeName(option);
    if (scope === 'message') {
      const index = messageIndex(option);
      const message = chatMessages[index];
      if (!message) return {};
      const swipe = message.swipe_id || 0;
      message.swipes_data = message.swipes_data || [];
      message.swipes_data[swipe] = message.swipes_data[swipe] || message.data || {};
      message.data = message.swipes_data[swipe];
      return message.data;
    }
    if (scope === 'script') {
      const scriptID = String(option?.script_id || currentScriptID || '');
      if (!scriptID) throw new Error('Script variables require script_id');
      scriptVariableScopes[scriptID] ||= {};
      if (scriptID === currentScriptID) scopedVariables.script = scriptVariableScopes[scriptID];
      return scriptVariableScopes[scriptID];
    }
    if (scope === 'extension') {
      const extensionID = String(option?.extension_id || '');
      if (!extensionID) throw new Error('Extension variables require extension_id');
      extensionVariableScopes[extensionID] ||= {};
      return extensionVariableScopes[extensionID];
    }
    if (!scopedVariables[scope]) scopedVariables[scope] = {};
    return scopedVariables[scope];
  };
  const rebuildVariables = () => {
    const layers = [scopedVariables.global || {}, scopedVariables.character || {}];
    if (currentScriptID) layers.push(scopeVariables({ type: 'script' }));
    layers.push(scopedVariables.chat || {});
    if (!currentScriptID) {
      const end = Math.min(Math.max(currentMessageIndex, 0), chatMessages.length - 1);
      for (let index = 0; index <= end; index += 1) {
        const message = chatMessages[index];
        layers.push(message?.swipes_data?.[message.swipe_id || 0] || message?.data || {});
      }
    }
    return Object.assign({}, ...layers);
  };
  const emitLocal = async (type, ...args) => {
    for (const listener of [...(listeners.get(type) || [])]) await listener(...args);
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
  const nativePosition = value => ({
    before_character_definition: 'before', after_character_definition: 'after',
    before_author_note: 'anTop', after_author_note: 'anBottom',
    before_example_messages: 'emTop', after_example_messages: 'emBottom',
    at_depth: 'atDepth'
  })[value] || value || 'after';
  const nativeLogic = value => ({ and_any: 'AND_ANY', and_all: 'AND_ALL', not_any: 'NOT_ANY', not_all: 'NOT_ALL' })[value] || 'AND_ANY';
  const nativeWorldbookEntries = entries => entries.map((entry, index) => {
    const strategy = entry.strategy || {};
    const secondary = strategy.keys_secondary || {};
    const position = entry.position && typeof entry.position === 'object' ? entry.position : {};
    const recursion = entry.recursion || {};
    const effect = entry.effect || {};
    const metadata = clone(entry.extra || entry.metadata || {});
    metadata.extensions = { ...(metadata.extensions || {}) };
    metadata.extensions.vectorized = strategy.type === 'vectorized';
    if (recursion.delay_until != null) metadata.extensions.delay_until_recursion = recursion.delay_until;
    const result = {
      uid: entry.uid ?? index,
      comment: entry.name || entry.comment || '',
      content: String(entry.content || ''),
      keys: clone(strategy.keys || entry.keys || entry.key || []),
      secondaryKeys: clone(secondary.keys || entry.secondaryKeys || entry.keysecondary || []),
      selectiveLogic: nativeLogic(secondary.logic || entry.selectiveLogic),
      isEnabled: entry.enabled ?? entry.isEnabled ?? !entry.disable,
      constant: strategy.type === 'constant' || !!entry.constant,
      position: nativePosition(position.type || entry.position),
      order: position.order ?? entry.order ?? 100,
      depth: position.depth ?? entry.depth ?? null,
      scanDepth: typeof strategy.scan_depth === 'number' ? strategy.scan_depth : (entry.scanDepth ?? null),
      caseSensitive: !!(entry.caseSensitive ?? metadata.caseSensitive ?? metadata.case_sensitive),
      matchWholeWords: !!(entry.matchWholeWords ?? metadata.matchWholeWords ?? metadata.match_whole_words),
      useRegex: !!entry.useRegex,
      useProbability: (entry.probability ?? 100) < 100,
      probability: entry.probability ?? 100,
      group: entry.group ?? metadata.group ?? null,
      groupOverride: !!(entry.groupOverride ?? metadata.groupOverride ?? metadata.group_override),
      groupWeight: entry.groupWeight ?? metadata.groupWeight ?? metadata.group_weight ?? 1,
      useGroupScoring: !!(entry.useGroupScoring ?? metadata.useGroupScoring ?? metadata.use_group_scoring),
      role: String(position.role || entry.role || 'system').toUpperCase(),
      sticky: effect.sticky ?? entry.sticky ?? null,
      cooldown: effect.cooldown ?? entry.cooldown ?? null,
      delay: effect.delay ?? entry.delay ?? null,
      excludeRecursion: !!(recursion.prevent_incoming ?? entry.excludeRecursion),
      preventRecursion: !!(recursion.prevent_outgoing ?? entry.preventRecursion),
      delayUntilRecursion: recursion.delay_until != null || !!entry.delayUntilRecursion,
      metadata
    };
    if (/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(String(entry.id || ''))) result.id = entry.id;
    return result;
  });
  const commitWorldbook = (name, entries) => {
    worldbooks[name] = clone(entries || []);
    post({ action: 'replace_worldbook', name, entries: nativeWorldbookEntries(worldbooks[name]) });
  };
  const helperRegex = rule => ({
    id: rule.id || '',
    script_name: rule.script_name || rule.scriptName || '',
    enabled: rule.enabled ?? !rule.disabled,
    scope: rule.scope === 'global' ? 'global' : 'character',
    find_regex: rule.find_regex || rule.findRegex || '',
    replace_string: rule.replace_string ?? rule.replaceString ?? '',
    trim_strings: clone(rule.trim_strings || rule.trimStrings || []),
    source: rule.source || {
      user_input: (rule.placements || []).includes(1),
      ai_output: (rule.placements || []).includes(2),
      slash_command: (rule.placements || []).includes(3),
      world_info: (rule.placements || []).includes(5),
      reasoning: (rule.placements || []).includes(6)
    },
    destination: rule.destination || {
      display: !!rule.markdownOnly,
      prompt: !!rule.promptOnly
    },
    run_on_edit: rule.run_on_edit ?? rule.runOnEdit ?? false,
    min_depth: rule.min_depth ?? rule.minDepth ?? null,
    max_depth: rule.max_depth ?? rule.maxDepth ?? null
  });
  let tavernRegexes = roleplayRegexRules.map(helperRegex);
  const commitTavernRegexes = value => {
    tavernRegexes = clone(value || []);
    post({ action: 'replace_regex_rules', value: tavernRegexes });
    return clone(tavernRegexes);
  };
  const commitVariables = (value, option = { type: 'chat' }) => {
    const scope = scopeName(option);
    if (scope === 'message') {
      const index = messageIndex(option);
      const message = chatMessages[index];
      if (!message) throw new Error(`Message '${option?.message_id ?? 'latest'}' was not found`);
      const swipe = message.swipe_id || 0;
      message.data = clone(value || {});
      message.swipes_data = message.swipes_data || [];
      message.swipes_data[swipe] = message.data;
      if (index === chatMessages.length - 1) scopedVariables.message = clone(message.data);
      post({ action: 'replace_message_variables', message_id: index, swipe_id: swipe, value: message.data });
      return clone(message.data);
    }
    const replacement = clone(value || {});
    if (scope === 'script') {
      const scriptID = String(option?.script_id || currentScriptID || '');
      if (!scriptID) throw new Error('Script variables require script_id');
      scriptVariableScopes[scriptID] = replacement;
      if (scriptID === currentScriptID) scopedVariables.script = replacement;
      post({ action: 'replace_variables', scope, script_id: scriptID, value: replacement });
      return clone(replacement);
    }
    if (scope === 'extension') {
      const extensionID = String(option?.extension_id || '');
      if (!extensionID) throw new Error('Extension variables require extension_id');
      extensionVariableScopes[extensionID] = replacement;
      post({ action: 'replace_variables', scope, extension_id: extensionID, value: replacement });
      return clone(replacement);
    }
    scopedVariables[scope] = replacement;
    post({ action: 'replace_variables', scope, value: replacement });
    return clone(replacement);
  };
  const applyMacroLikes = (text, context = {}) => {
    let output = String(text ?? '');
    output = output.replace(/\\{\\{\\{?user\\}?\\}\\}/gi, \(userJSON)).replace(/\\{\\{\\{?char\\}?\\}\\}/gi, \(characterJSON));
    output = output.replace(/\\{\\{\\{?get_(message|chat|character|preset|global)_variable::(.*?)\\}?\\}\\}/gi, (_match, type, path) => {
      const option = type === 'message' ? { type, message_id: context.message_id ?? 'latest' } : { type };
      const value = getPath(scopeVariables(option), path, null);
      return typeof value === 'string' ? value : JSON.stringify(value);
    });
    output = output.replace(/\\{\\{\\{?(?:getvar|get_variable)::(.*?)\\}?\\}\\}/gi, (_match, path) => {
      const value = getPath(rebuildVariables(), path, null);
      return typeof value === 'string' ? value : JSON.stringify(value);
    });
    for (const item of [...macroLikeRules]) output = output.replace(item.regex, (...args) => item.replace(context, ...args));
    return output;
  };
  const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[character]);
  const formatDisplayed = text => {
    const source = applyMacroLikes(text);
    const blocks = [];
    const body = source.replace(/```(?:html|htm|xml)?\\s*\\n?([\\s\\S]*?)```/gi, (_match, code) => {
      const token = `__ETOS_CODE_${blocks.length}__`;
      blocks.push(`<pre><code>${escapeHTML(code)}</code></pre>`);
      return token;
    });
    let html = escapeHTML(body).replace(/\\n/g, '<br>');
    blocks.forEach((block, index) => { html = html.replace(`__ETOS_CODE_${index}__`, block); });
    return html;
  };
  const parsedRoleplayRegex = raw => {
    const source = String(raw || '');
    if (!source.startsWith('/')) return new RegExp(source, 'g');
    const closing = source.lastIndexOf('/');
    if (closing <= 0) return new RegExp(source, 'g');
    const flags = source.slice(closing + 1).replace(/[^dgimsuvy]/g, '');
    return new RegExp(source.slice(1, closing), flags || 'g');
  };
  const formatAsTavernRegexedString = (text, source = 'ai_output', destination = 'display', options = {}) => {
    const placement = source === 'user_input' ? 1 : source === 'slash_command' ? 3 : source === 'world_info' ? 5 : source === 'reasoning' ? 6 : 2;
    let output = String(text ?? '');
    for (const rawRule of tavernRegexes) {
      const rule = helperRegex(rawRule);
      if (!rule.enabled || !rule.source?.[source]) continue;
      if (rule.destination?.display && destination !== 'display') continue;
      if (rule.destination?.prompt && destination !== 'prompt') continue;
      if (options.depth !== undefined && rule.min_depth != null && rule.min_depth >= -1 && options.depth < rule.min_depth) continue;
      if (options.depth !== undefined && rule.max_depth != null && rule.max_depth >= 0 && options.depth > rule.max_depth) continue;
      try {
        const trims = Array.isArray(rule.trim_strings) ? rule.trim_strings : [rule.trim_strings].filter(Boolean);
        for (const trimmed of trims) output = output.split(trimmed).join('');
        output = output.replace(parsedRoleplayRegex(rule.find_regex), applyMacroLikes(rule.replace_string || ''));
      } catch (error) { console.error(error); }
    }
    return output;
  };
  const displayedContainer = messageID => {
    const index = normalizeMessageId(messageID);
    const message = chatMessages[index];
    const existing = document.querySelector?.(`#chat > .mes[mesid="${index}"] .mes_text`);
    if (existing) return existing;
    const container = document.createElement('div');
    container.className = 'mes_text';
    container.innerHTML = message?.displayed_html || formatDisplayed(message?.message || '');
    let initialized = false;
    const observer = new MutationObserver(() => {
      if (!initialized || !chatMessages[index]) return;
      chatMessages[index].displayed_html = container.innerHTML;
      post({ action: 'set_displayed_message', message_id: index, html: container.innerHTML });
    });
    observer.observe(container, { subtree: true, childList: true, characterData: true, attributes: true });
    initialized = true;
    return container;
  };
  const installVirtualChatDOM = () => {
    if (!document.body || document.querySelector?.('#chat')) return;
    const chat = document.createElement('div');
    chat.id = 'chat';
    chat.hidden = true;
    chat.setAttribute('aria-hidden', 'true');
    for (const message of chatMessages) {
      const row = document.createElement('div');
      row.className = 'mes';
      row.setAttribute('mesid', String(message.message_id));
      row.setAttribute('is_user', String(message.role === 'user'));
      row.setAttribute('is_system', String(message.role === 'system'));
      const text = document.createElement('div');
      text.className = 'mes_text';
      text.innerHTML = message.displayed_html || formatDisplayed(message.message || '');
      const observer = new MutationObserver(() => {
        message.displayed_html = text.innerHTML;
        post({ action: 'set_displayed_message', message_id: message.message_id, html: text.innerHTML });
      });
      observer.observe(text, { subtree: true, childList: true, characterData: true, attributes: true });
      row.appendChild(text);
      chat.appendChild(row);
    }
    document.body.appendChild(chat);
  };
  const audioStore = type => audioState[type === 'ambient' ? 'ambient' : 'bgm'];
  const api = {
    getVariables: (option = { type: 'chat' }) => clone(scopeVariables(option)),
    getAllVariables: () => clone(rebuildVariables()),
    replaceVariables: (value, option = { type: 'chat' }) => commitVariables(value, option),
    updateVariablesWith: (updater, option = { type: 'chat' }) => {
      const result = updater(clone(scopeVariables(option)));
      if (result && typeof result.then === 'function') {
        return result.then(value => commitVariables(value, option));
      }
      return commitVariables(result, option);
    },
    insertOrAssignVariables: (value, option = { type: 'chat' }) => {
      const updated = mergeValue(scopeVariables(option), clone(value || {}), true);
      return commitVariables(updated, option);
    },
    insertVariables: (value, option = { type: 'chat' }) => {
      const updated = mergeValue(scopeVariables(option), clone(value || {}), false);
      return commitVariables(updated, option);
    },
    getVariable: (path, fallback = null, option = null) => clone(getPath(option ? scopeVariables(option) : rebuildVariables(), path, fallback)),
    setVariable: (path, value, option = { type: 'chat' }) => {
      setPath(scopeVariables(option), path, value);
      commitVariables(scopeVariables(option), option);
      emitLocal('VARIABLE_UPDATED', path, clone(value));
      return clone(value);
    },
    deleteVariable: (path, option = { type: 'chat' }) => {
      const delete_occurred = deletePath(scopeVariables(option), path);
      if (delete_occurred) commitVariables(scopeVariables(option), option);
      return { variables: clone(scopeVariables(option)), delete_occurred };
    },
    sendMessage: text => post({ action: 'send_message', text: String(text ?? '') }),
    chooseOption: text => post({ action: 'send_message', text: String(text ?? '') }),
    setInput: text => post({ action: 'set_input', text: String(text ?? '') }),
    triggerGeneration: () => post({ action: 'generate' }),
    generate: () => post({ action: 'generate' }),
    triggerSlash: async command => {
      let result = '';
      let sent = false;
      const commands = String(command || '').split(/\\|(?=\\/)/).map(value => value.trim()).filter(Boolean);
      for (const item of commands) {
        const space = item.indexOf(' ');
        const name = (space < 0 ? item : item.slice(0, space)).toLowerCase();
        const argument = space < 0 ? '' : item.slice(space + 1).trim();
        if (name === '/send') {
          api.sendMessage(argument);
          sent = true;
        } else if (name === '/sendas') {
          api.sendMessage(argument.replace(/^name=(?:"[^"]*"|'[^']*'|\\S+)\\s*/i, ''));
          sent = true;
        } else if (name === '/setinput') {
          api.setInput(argument);
          result = argument;
        } else if (name === '/trigger') {
          if (!sent) api.triggerGeneration();
        } else if (name === '/getvar') {
          const key = argument.match(/(?:^|\\s)key=(?:"([^"]*)"|'([^']*)'|(\\S+))/i);
          result = clone(getPath(api.getVariables({ type: 'chat' }), key?.[1] ?? key?.[2] ?? key?.[3] ?? '', ''));
        } else if (name === '/setvar' || name === '/addvar') {
          const key = argument.match(/(?:^|\\s)key=(?:"([^"]*)"|'([^']*)'|(\\S+))/i);
          const path = key?.[1] ?? key?.[2] ?? key?.[3];
          if (path) {
            const rawValue = argument.slice((key.index || 0) + key[0].length).trim().replace(/^['"]|['"]$/g, '');
            const current = api.getVariables({ type: 'chat' });
            const next = name === '/addvar' ? Number(getPath(current, path, 0)) + (Number(rawValue) || 0) : rawValue;
            setPath(current, path, next);
            api.replaceVariables(current, { type: 'chat' });
            result = next;
          }
        }
      }
      return result == null ? '' : String(result);
    },
    eventOn: (type, listener) => {
      const values = listeners.get(type) || [];
      if (!values.includes(listener)) values.push(listener);
      listeners.set(type, values);
      return { stop: () => listeners.set(type, (listeners.get(type) || []).filter(item => item !== listener)) };
    },
    eventOnButton: (name, listener) => api.eventOn(api.getButtonEvent(name), listener),
    eventOnce: (type, listener) => {
      const wrapped = async (...args) => { try { return await listener(...args); } finally { api.eventOff(type, wrapped); } };
      return api.eventOn(type, wrapped);
    },
    eventMakeFirst: (type, listener) => {
      const values = (listeners.get(type) || []).filter(item => item !== listener);
      values.unshift(listener);
      listeners.set(type, values);
      return { stop: () => api.eventOff(type, listener) };
    },
    eventMakeLast: (type, listener) => {
      api.eventOff(type, listener);
      return api.eventOn(type, listener);
    },
    eventOff: (type, listener) => listeners.set(type, (listeners.get(type) || []).filter(item => item !== listener)),
    eventEmit: async (type, ...args) => {
      await emitLocal(type, ...args);
      post({ action: 'event', name: type, value: args, source: currentIframeName });
    },
    eventEmitAndWait: async (type, ...args) => emitLocal(type, ...args),
    eventRemoveListener: (type, listener) => api.eventOff(type, listener),
    eventClearEvent: type => listeners.delete(type),
    eventClearListener: listener => listeners.forEach((values, type) => listeners.set(type, values.filter(item => item !== listener))),
    eventClearAll: () => listeners.clear(),
    getIframeName: () => currentIframeName,
    getScriptId: () => currentScriptID,
    getCurrentMessageId: () => currentMessageIndex,
    getLastMessageId: () => Math.max(-1, chatMessages.length - 1),
    getMessageId: iframeName => {
      const match = String(iframeName || '').match(/^TH-message--(\\d+)--/);
      if (!match) throw new Error(`Cannot resolve message id from '${iframeName}'`);
      return Number(match[1]);
    },
    reloadIframe: () => window.location?.reload?.(),
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
    formatAsDisplayedMessage: (text, option = {}) => {
      let index;
      if (option.message_id === 'last_user') index = chatMessages.findLastIndex(message => message.role === 'user');
      else if (option.message_id === 'last_char') index = chatMessages.findLastIndex(message => message.role === 'assistant');
      else if (typeof option.message_id === 'number') index = normalizeMessageId(option.message_id);
      else index = Math.max(0, chatMessages.length - 1);
      const source = chatMessages[index]?.role === 'user' ? 'user_input' : 'ai_output';
      const regexed = formatAsTavernRegexedString(text, source, 'display', {
        depth: Math.max(0, chatMessages.length - index - 1)
      });
      return formatDisplayed(regexed);
    },
    formatAsTavernRegexedString,
    retrieveDisplayedMessage: messageID => {
      const element = displayedContainer(messageID);
      return window.jQuery ? window.jQuery(element) : element;
    },
    setChatMessages: async (updates, _options = {}) => {
      const normalized = (updates || []).map(update => ({ ...clone(update), message_id: normalizeMessageId(update.message_id) }));
      for (const update of normalized) {
        const current = chatMessages[update.message_id];
        if (!current) continue;
        Object.assign(current, update);
        if (update.message !== undefined) {
          current.message = String(update.message);
          delete current.displayed_html;
        }
        if (update.data !== undefined) current.data = clone(update.data);
      }
      post({ action: 'set_chat_messages', value: normalized });
      for (const update of normalized) await emitLocal('message_updated', update.message_id);
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
      for (const index of normalized) {
        chatMessages.splice(index, 1);
        await emitLocal('message_deleted', index);
      }
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
    getLorebookNames: () => Object.keys(worldbooks),
    getLorebooks: () => Object.keys(worldbooks),
    getCharWorldbookNames: (_name = 'current') => clone(currentCharacterWorldbooks),
    getCharLorebooks: () => clone(currentCharacterWorldbooks),
    getCurrentCharPrimaryLorebook: () => currentCharacterWorldbooks.primary,
    rebindCharWorldbooks: async (_name, binding) => {
      currentCharacterWorldbooks = {
        primary: binding?.primary || null,
        additional: clone(binding?.additional || [])
      };
      post({ action: 'rebind_character_worldbooks', value: currentCharacterWorldbooks });
    },
    setCurrentCharLorebooks: async binding => api.rebindCharWorldbooks('current', binding),
    createWorldbook: async name => {
      const key = String(name || '').trim();
      if (!key || key in worldbooks) return false;
      worldbooks[key] = [];
      post({ action: 'create_worldbook', name: key });
      return true;
    },
    createLorebook: async name => api.createWorldbook(name),
    deleteWorldbook: async name => {
      if (!(name in worldbooks)) return false;
      delete worldbooks[name];
      post({ action: 'delete_worldbook', name });
      return true;
    },
    deleteLorebook: async name => api.deleteWorldbook(name),
    getWorldbook: async name => {
      if (!(name in worldbooks)) throw new Error(`Worldbook '${name}' was not found`);
      return clone(worldbooks[name]);
    },
    replaceWorldbook: async (name, entries, _options = {}) => {
      if (!(name in worldbooks)) throw new Error(`Worldbook '${name}' was not found`);
      commitWorldbook(name, (entries || []).map((entry, index) => completeHelperWorldbookEntry(entry, entry.uid ?? index)));
    },
    getLorebookEntries: async name => api.getWorldbook(name),
    replaceLorebookEntries: async (name, entries, options = {}) => api.replaceWorldbook(name, entries, options),
    updateLorebookEntriesWith: async (name, updater, options = {}) => api.updateWorldbookWith(name, updater, options),
    createLorebookEntries: async (name, entries, options = {}) => {
      const result = await api.createWorldbookEntries(name, entries, options);
      return { entries: result.worldbook, new_uids: result.new_entries.map(entry => entry.uid) };
    },
    setLorebookEntries: async (name, updates, options = {}) => {
      const byUID = new Map((updates || []).map(entry => [entry.uid, entry]));
      const next = (await api.getWorldbook(name)).map(entry => byUID.has(entry.uid)
        ? completeHelperWorldbookEntry({ ...entry, ...clone(byUID.get(entry.uid)) }, entry.uid)
        : entry);
      await api.replaceWorldbook(name, next, options);
      return api.getWorldbook(name);
    },
    updateWorldbookWith: async (name, updater, options = {}) => {
      const updated = await updater(await api.getWorldbook(name));
      await api.replaceWorldbook(name, updated, options);
      return api.getWorldbook(name);
    },
    createWorldbookEntries: async (name, entries, options = {}) => {
      const existing = await api.getWorldbook(name);
      const used = new Set(existing.map(entry => Number(entry.uid)).filter(Number.isInteger));
      let nextUID = used.size ? Math.max(...used) + 1 : 0;
      const created = clone(entries || []).map(entry => {
        while (used.has(nextUID)) nextUID += 1;
        const uid = Number.isInteger(Number(entry.uid)) && !used.has(Number(entry.uid)) ? Number(entry.uid) : nextUID++;
        used.add(uid);
        return completeHelperWorldbookEntry(entry, uid);
      });
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
    deleteLorebookEntries: async (name, uids, options = {}) => {
      const targets = new Set((uids || []).map(Number));
      const result = await api.deleteWorldbookEntries(name, entry => targets.has(Number(entry.uid)), options);
      return { entries: result.worldbook, delete_occurred: result.deleted_entries.length > 0 };
    },
    isCharacterTavernRegexesEnabled: () => true,
    getTavernRegexes: ({ scope = 'all', enable_state = 'all' } = {}) => clone(tavernRegexes.filter(rule => {
      if (scope !== 'all' && rule.scope !== scope) return false;
      if (enable_state === 'enabled' && !rule.enabled) return false;
      if (enable_state === 'disabled' && rule.enabled) return false;
      return true;
    })),
    replaceTavernRegexes: async (rules, _options = {}) => commitTavernRegexes(rules),
    updateTavernRegexesWith: async (updater, options = {}) => {
      const updated = await updater(api.getTavernRegexes({ scope: options.scope || 'all' }));
      return commitTavernRegexes(updated);
    },
    registerMacroLike: (regex, replace) => {
      if (!macroLikeRules.some(item => item.regex.source === regex.source)) macroLikeRules.push({ regex, replace });
      return { unregister: () => api.unregisterMacroLike(regex) };
    },
    unregisterMacroLike: regex => {
      const index = macroLikeRules.findIndex(item => item.regex.source === regex.source);
      if (index >= 0) macroLikeRules.splice(index, 1);
    },
    substitudeMacros: (text, context = {}) => applyMacroLikes(text, context),
    substituteMacros: (text, context = {}) => applyMacroLikes(text, context),
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
    getButtonEvent: name => `etos_script_button:${currentScriptID}:${String(name)}`,
    getScriptButtons: () => clone(currentScriptButtons),
    replaceScriptButtons: buttons => {
      currentScriptButtons = clone(buttons || []);
      post({ action: 'replace_script_buttons', script_id: currentScriptID, buttons: currentScriptButtons });
    },
    updateScriptButtonsWith: async updater => {
      const updated = await updater(clone(currentScriptButtons));
      api.replaceScriptButtons(updated || []);
      return clone(currentScriptButtons);
    },
    appendInexistentScriptButtons: buttons => {
      for (const button of buttons || []) {
        if (!currentScriptButtons.some(existing => existing.name === button.name)) currentScriptButtons.push(clone(button));
      }
      api.replaceScriptButtons(currentScriptButtons);
      return clone(currentScriptButtons);
    },
    getScriptName: () => currentScriptName,
    getScriptInfo: () => currentScriptInfo,
    replaceScriptInfo: info => { currentScriptInfo = String(info ?? ''); },
    getCharacterName: () => \(characterJSON),
    getCurrentCharacterName: () => \(characterJSON),
    getUserName: () => \(userJSON),
    userAvatarPath: \(userAvatarJSON),
    charAvatarPath: \(characterAvatarJSON),
    getCharacterAssets: () => clone(\(characterAssetsJSON))
  };
  api.triggerSlashWithResult = api.triggerSlash;
  api.builtin = { saveSettings: async () => undefined };
  window.etos = api;
  window.TavernHelper = Object.assign(window.TavernHelper || {}, api);
  Object.assign(window, api);
  window.Mvu = window.Mvu || {
    get: path => clone(getPath(rebuildVariables(), path, null)),
    set: (path, value) => api.setVariable(path, value, { type: 'message' }),
    variables: () => api.getAllVariables()
  };
  const sillyChat = chatMessages.map((message, index) => new Proxy({}, {
    get: (_target, key) => {
      if (key === 'mes') return message.message;
      if (key === 'is_user') return message.role === 'user';
      if (key === 'is_system') return message.role === 'system';
      if (key === 'name') return message.name;
      if (key === 'swipe_id') return message.swipe_id || 0;
      if (key === 'swipes') return message.swipes || [message.message];
      if (key === 'variables') return new Proxy(message.swipes_data || [message.data || {}], {
        set: (values, variableKey, value) => {
          values[variableKey] = value;
          message.swipes_data = values;
          const swipe = message.swipe_id || 0;
          message.data = values[swipe] || {};
          post({ action: 'replace_message_variables', message_id: index, swipe_id: swipe, value: message.data });
          return true;
        }
      });
      if (key === 'extra') return message.extra || {};
      return message[key];
    },
    set: (_target, key, value) => {
      if (key === 'mes') {
        message.message = String(value ?? '');
        api.setChatMessages([{ message_id: index, message: message.message }]);
      } else if (key === 'variables') {
        message.swipes_data = value || [];
        const swipe = message.swipe_id || 0;
        message.data = message.swipes_data[swipe] || {};
        post({ action: 'replace_message_variables', message_id: index, swipe_id: swipe, value: message.data });
      } else message[key] = value;
      return true;
    }
  }));
  window.SillyTavern = Object.assign(window.SillyTavern || {}, {
    chat: sillyChat,
    characters: [{ name: \(characterJSON), avatar: \(characterAvatarJSON) }],
    characterId: 0,
    extensionSettings: { character_allowed_regex: [\(characterAvatarJSON)] },
    powerUserSettings: {},
    getContext: () => ({
      name1: \(userJSON), name2: \(characterJSON), chat: sillyChat,
      characters: window.SillyTavern.characters,
      characterId: 0,
      extensionSettings: window.SillyTavern.extensionSettings
    }),
    updateMessageBlock: (messageID, update = {}) => {
      const index = normalizeMessageId(messageID);
      if (update.mes !== undefined) api.setChatMessages([{ message_id: index, message: String(update.mes) }]);
      if (update.message !== undefined) {
        chatMessages[index].displayed_html = String(update.message);
        post({ action: 'set_displayed_message', message_id: index, html: String(update.message) });
      }
    },
    saveChat: async () => undefined,
    saveSettingsDebounced: () => undefined,
    reloadCurrentChat: async () => emitLocal('chat_id_changed')
  });
  window.name = window.name || currentIframeName;
  window.characters = window.SillyTavern.characters;
  window.saveChat = window.SillyTavern.saveChat;
  window.saveSettingsDebounced = window.SillyTavern.saveSettingsDebounced;
  window.reloadCurrentChat = window.SillyTavern.reloadCurrentChat;
  window.translate = text => String(text ?? '');
  window.getContext = window.SillyTavern.getContext;
  window.__etosEmitScriptButton = name => emitLocal(api.getButtonEvent(name));
  window.__etosReceiveEvent = (name, args, source) => {
    if (source === currentIframeName) return undefined;
    const values = Array.isArray(args) ? args : [];
    if ([
      'mag_variable_initiailized', 'mag_variable_initialized',
      'mag_variable_update_started', 'mag_command_parsed', 'mag_variable_update_ended'
    ].includes(name) && values[0] && typeof values[0] === 'object') {
      const index = messageIndex({ type: 'message', message_id: 'latest' });
      const message = chatMessages[index];
      if (message) {
        const swipe = message.swipe_id || 0;
        message.data = clone(values[0]);
        message.swipes_data ||= [];
        message.swipes_data[swipe] = message.data;
        if (index === chatMessages.length - 1) scopedVariables.message = message.data;
      }
    }
    return emitLocal(name, ...values);
  };
  window.__etosExpandMacros = (requestID, text) => post({
    action: 'macro_expansion_response',
    request_id: requestID,
    text: api.substitudeMacros(String(text ?? ''), {})
  });
  const activePromptMutationRequests = new Set();
  window.__etosMutatePrompt = async (requestID, prompt) => {
    if (activePromptMutationRequests.has(requestID)) return;
    activePromptMutationRequests.add(requestID);
    const data = { prompt: Array.isArray(prompt) ? clone(prompt) : [] };
    try {
      await emitLocal(window.tavern_events?.GENERATE_AFTER_DATA || 'generate_after_data', data, false);
    } catch (error) {
      console.error(error);
    }
    post({ action: 'prompt_mutation_response', request_id: requestID, prompt: data.prompt });
    setTimeout(() => activePromptMutationRequests.delete(requestID), 5000);
  };
  const reportHeight = () => post({ action: 'height', value: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 1) });
  window.addEventListener('DOMContentLoaded', () => {
    installVirtualChatDOM();
    reportHeight();
    new ResizeObserver(reportHeight).observe(document.documentElement);
    emitLocal('message_iframe_render_started', currentIframeName);
    requestAnimationFrame(() => emitLocal('message_iframe_render_ended', currentIframeName));
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
