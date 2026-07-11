// ============================================================================
// RoleplayPromptTemplateRenderer.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行 Prompt Template EJS，并在世界书扫描前处理 @@preprocessing。
// ============================================================================

import Foundation
import os.log

#if canImport(JavaScriptCore) && !os(watchOS)
import JavaScriptCore
#endif

#if os(watchOS)
import Darwin
#endif

enum RoleplayPromptTemplateRenderer {
    private struct RenderedEnvelope: Decodable {
        struct Activation: Decodable {
            var worldbook: String
            var title: String
            var force: Bool
        }

        var outputs: [String]
        var primaryKeys: [[String]]
        var secondaryKeys: [[String]]
        var activations: [Activation]
        var scopes: [String: [String: JSONValue]]
        var initial: [String: JSONValue]
        var messageScopes: [String: [String: JSONValue]]
        var errors: [String]
    }

    private static let knownDecorators: Set<String> = [
        "@@activate", "@@dont_activate", "@@message_formatting", "@@generate_before",
        "@@generate_after", "@@render_before", "@@render_after", "@@dont_preload",
        "@@initial_variables", "@@always_enabled", "@@only_preload", "@@iframe",
        "@@preprocessing"
    ]
    private static let activationMetadataKey = "__etos_prompt_template_activated"
    private static let logger = Logger(
        subsystem: "com.ETOS.LLM.Studio",
        category: "RoleplayPromptTemplate"
    )

    static func preprocessWorldbooks(
        _ worldbooks: [Worldbook],
        messages: [ChatMessage],
        regexRules: [RoleplayRegexRule] = [],
        macroContext: inout RoleplayMacroContext
    ) async -> [Worldbook] {
        var updated = worldbooks
        var locations: [(bookIndex: Int, entryIndex: Int)] = []
        for bookIndex in updated.indices {
            for entryIndex in updated[bookIndex].entries.indices {
                guard isPreprocessingEntry(updated[bookIndex].entries[entryIndex]) else { continue }
                locations.append((bookIndex, entryIndex))
            }
        }
        guard !locations.isEmpty else { return updated }

        let entries = locations.map { updated[$0.bookIndex].entries[$0.entryIndex] }
        guard let envelope = await render(
            entries.map { parsedDecorators(in: $0.content).content },
            worldbooks: updated,
            messages: messages,
            regexRules: regexRules,
            macroContext: macroContext,
            currentEntries: entries,
            currentWorldbookNames: locations.map { updated[$0.bookIndex].name }
        ) else {
            return updated
        }

        for (offset, location) in locations.enumerated() where envelope.outputs.indices.contains(offset) {
            updated[location.bookIndex].entries[location.entryIndex].content = envelope.outputs[offset]
            if envelope.primaryKeys.indices.contains(offset) {
                updated[location.bookIndex].entries[location.entryIndex].keys = envelope.primaryKeys[offset]
            }
            if envelope.secondaryKeys.indices.contains(offset) {
                updated[location.bookIndex].entries[location.entryIndex].secondaryKeys = envelope.secondaryKeys[offset]
            }
        }
        apply(envelope, to: &macroContext)
        apply(envelope.activations, to: &updated)
        log(envelope.errors)
        return updated
    }

    static func renderMessages(
        _ messagesToRender: [ChatMessage],
        worldbooks: [Worldbook],
        chatHistory: [ChatMessage],
        regexRules: [RoleplayRegexRule] = [],
        macroContext: inout RoleplayMacroContext
    ) async -> [ChatMessage] {
        let indexes = messagesToRender.indices.filter { messagesToRender[$0].content.contains("<%") }
        guard !indexes.isEmpty else { return messagesToRender }
        guard let envelope = await render(
            indexes.map { messagesToRender[$0].content },
            worldbooks: worldbooks,
            messages: chatHistory,
            regexRules: regexRules,
            macroContext: macroContext,
            currentEntries: Array(repeating: nil, count: indexes.count),
            currentWorldbookNames: Array(repeating: nil, count: indexes.count)
        ) else {
            return messagesToRender
        }

        var rendered = messagesToRender
        for (offset, index) in indexes.enumerated() where envelope.outputs.indices.contains(offset) {
            rendered[index].content = envelope.outputs[offset]
        }
        apply(envelope, to: &macroContext)
        log(envelope.errors)
        return rendered
    }

    private static func apply(
        _ envelope: RenderedEnvelope,
        to macroContext: inout RoleplayMacroContext
    ) {
        var snapshot = macroContext.variables
        for scope in [
            RoleplayVariableScope.global,
            .preset,
            .character,
            .persona,
            .chat
        ] {
            guard let values = envelope.scopes[scope.rawValue] else { continue }
            snapshot.replaceVariables(values, scope: scope)
        }
        snapshot.replacePromptTemplateInitialVariables(envelope.initial)
        for (versionKey, values) in envelope.messageScopes {
            snapshot.replaceMessageVariables(values, versionKey: versionKey)
        }
        macroContext.variables = snapshot
    }

    private static func isPreprocessingEntry(_ entry: WorldbookEntry) -> Bool {
        guard entry.isEnabled else { return false }
        if entry.comment.contains("[Preprocessing]") { return true }
        return parsedDecorators(in: entry.content).decorators.contains { decorator in
            decorator.split(separator: " ", maxSplits: 1).first.map(String.init) == "@@preprocessing"
        }
    }

    private static func parsedDecorators(in content: String) -> (decorators: [String], content: String) {
        guard content.hasPrefix("@@") else { return ([], content) }
        let lines = content.components(separatedBy: .newlines)
        var decorators: [String] = []
        var contentStart = 0
        var fallbacked = false
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("@@") else {
                contentStart = index
                break
            }
            if line.hasPrefix("@@@"), !fallbacked {
                contentStart = index
                break
            }
            let normalized = line.hasPrefix("@@@") ? String(line.dropFirst()) : line
            let base = normalized.split(separator: " ", maxSplits: 1).first.map(String.init) ?? normalized
            if knownDecorators.contains(base) {
                decorators.append(normalized)
                fallbacked = false
                contentStart = index + 1
            } else {
                fallbacked = true
            }
        }
        return (decorators, lines.dropFirst(contentStart).joined(separator: "\n"))
    }

    private static func apply(
        _ activations: [RenderedEnvelope.Activation],
        to worldbooks: inout [Worldbook]
    ) {
        for activation in activations {
            guard let bookIndex = worldbooks.firstIndex(where: { $0.name == activation.worldbook }),
                  let entryIndex = worldbooks[bookIndex].entries.firstIndex(where: { entry in
                      entry.comment == activation.title || entry.uid.map(String.init) == activation.title
                  }) else { continue }

            var entry = worldbooks[bookIndex].entries[entryIndex]
            entry.isEnabled = true
            entry.metadata[activationMetadataKey] = .bool(true)
            if activation.force {
                entry.constant = true
                entry.cooldown = 0
                entry.delay = 0
                entry.delayUntilRecursion = false
                entry.group = ""
                entry.metadata["vectorized"] = .bool(false)
                entry.metadata["ignoreBudget"] = .bool(true)
                entry.metadata["delayUntilRecursion"] = .bool(false)
                entry.metadata["delay_until_recursion"] = .bool(false)
                if case .dictionary(var extensions) = entry.metadata["extensions"] {
                    extensions["vectorized"] = .bool(false)
                    extensions["delay_until_recursion"] = .bool(false)
                    entry.metadata["extensions"] = .dictionary(extensions)
                }
                entry.metadata["triggers"] = .array([])
                entry.content = entry.content.replacingOccurrences(of: "@@dont_activate", with: "")
            }
            worldbooks[bookIndex].entries[entryIndex] = entry
        }
    }

    private static func render(
        _ templates: [String],
        worldbooks: [Worldbook],
        messages: [ChatMessage],
        regexRules: [RoleplayRegexRule],
        macroContext: RoleplayMacroContext,
        currentEntries: [WorldbookEntry?],
        currentWorldbookNames: [String?]
    ) async -> RenderedEnvelope? {
        let script: String? = await Task.detached(priority: .userInitiated) {
            let payload = makePayload(
                templates: templates,
                worldbooks: worldbooks,
                messages: messages,
                regexRules: regexRules,
                macroContext: macroContext,
                currentEntries: currentEntries,
                currentWorldbookNames: currentWorldbookNames
            )
            guard let data = try? JSONEncoder().encode(payload),
                  let payloadJSON = String(data: data, encoding: .utf8) else { return nil }
            return javaScript(payloadJSON: payloadJSON)
        }.value
        guard let script else { return nil }

        do {
            guard let result = try await RoleplayPromptTemplateJavaScript.evaluate(script),
                  let data = result.data(using: .utf8) else { return nil }
            let envelope = try JSONDecoder().decode(RenderedEnvelope.self, from: data)
            return envelope.outputs.count == templates.count ? envelope : nil
        } catch {
            logger.error("提示词模板执行失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func makePayload(
        templates: [String],
        worldbooks: [Worldbook],
        messages: [ChatMessage],
        regexRules: [RoleplayRegexRule],
        macroContext: RoleplayMacroContext,
        currentEntries: [WorldbookEntry?],
        currentWorldbookNames: [String?]
    ) -> JSONValue {
        let entries = worldbooks.flatMap { book in
            sortedPromptTemplateEntries(book.entries).map {
                payloadEntry(
                    $0,
                    worldbook: book.name,
                    regexRules: regexRules,
                    macroContext: macroContext
                )
            }
        }
        let chat = messages.enumerated().map { index, message -> JSONValue in
            let versions = message.getAllVersions().indices.map { version -> JSONValue in
                let key = RoleplayVariableSnapshot.messageVersionKey(messageID: message.id, versionIndex: version)
                return .dictionary([
                    "key": .string(key),
                    "initialized": .bool(macroContext.variables.messageVersions[key] != nil),
                    "value": .dictionary(macroContext.variables.messageVariables(
                        messageID: message.id,
                        versionIndex: version
                    ))
                ])
            }
            return .dictionary([
                "message_id": .int(index),
                "role": .string(message.role == .assistant ? "assistant" : message.role == .user ? "user" : "system"),
                "message": .string(RoleplayMacroResolver.resolve(message.content, context: macroContext)),
                "mes": .string(RoleplayMacroResolver.resolve(message.content, context: macroContext)),
                "is_user": .bool(message.role == .user),
                "is_system": .bool(message.role == .system || message.role == .tool || message.role == .error),
                "swipe_id": .int(message.getCurrentVersionIndex()),
                "variables": .array(versions)
            ])
        }
        let current = templates.indices.map { index -> JSONValue in
            guard currentEntries.indices.contains(index), let entry = currentEntries[index] else { return .null }
            return payloadEntry(
                entry,
                worldbook: currentWorldbookNames.indices.contains(index) ? currentWorldbookNames[index] ?? "" : "",
                regexRules: regexRules,
                macroContext: macroContext
            )
        }
        let currentMessageIndex = max(0, messages.count - 1)
        let processedTemplates = templates.enumerated().map { index, template -> JSONValue in
            let resolved = RoleplayMacroResolver.resolve(template, context: macroContext)
            guard currentEntries.indices.contains(index), currentEntries[index] != nil else {
                return .string(resolved)
            }
            return .string(RoleplayRegexTransformer.apply(
                resolved,
                rules: regexRules,
                context: .init(placement: .worldInfo, macroContext: macroContext)
            ))
        }
        return .dictionary([
            "templates": .array(processedTemplates),
            "current": .array(current),
            "entries": .array(entries),
            "chat": .array(chat),
            "currentMessageIndex": .int(currentMessageIndex),
            "defaultWorldbook": .string(worldbooks.first?.name ?? ""),
            "initial": .dictionary(macroContext.variables.promptTemplateInitialVariables),
            "scopes": .dictionary([
                "global": .dictionary(macroContext.variables.global),
                "preset": .dictionary(macroContext.variables.preset),
                "character": .dictionary(macroContext.variables.character),
                "persona": .dictionary(macroContext.variables.persona),
                "chat": .dictionary(macroContext.variables.chat)
            ]),
            "names": .dictionary([
                "userName": .string(macroContext.persona?.name ?? "User"),
                "assistantName": .string(macroContext.character?.name ?? "Assistant"),
                "charName": .string(macroContext.character?.name ?? "Assistant"),
                "lastMessage": .string(macroContext.lastMessage),
                "lastUserMessage": .string(macroContext.lastUserMessage),
                "lastCharMessage": .string(macroContext.lastCharacterMessage),
                "lastMessageId": .int(max(-1, messages.count - 1))
            ])
        ])
    }

    private static func sortedPromptTemplateEntries(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        let topDepth = entries.filter { $0.position == .atDepth }.compactMap(\.depth).max() ?? 4
        func depth(_ entry: WorldbookEntry) -> Int {
            switch entry.position {
            case .before: return topDepth + 4
            case .after: return topDepth + 3
            case .emTop: return topDepth + 2
            case .emBottom, .anTop: return topDepth + 1
            case .anBottom: return topDepth - 1
            case .atDepth, .outlet: return entry.depth ?? 4
            }
        }
        return entries.sorted { lhs, rhs in
            if depth(lhs) != depth(rhs) { return depth(lhs) > depth(rhs) }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return (lhs.uid ?? 0) > (rhs.uid ?? 0)
        }
    }

    private static func payloadEntry(
        _ entry: WorldbookEntry,
        worldbook: String,
        regexRules: [RoleplayRegexRule],
        macroContext: RoleplayMacroContext
    ) -> JSONValue {
        var fields: [String: JSONValue]
        if let data = try? JSONEncoder().encode(entry),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .dictionary(let value) = decoded {
            fields = value
        } else {
            fields = [:]
        }
        let parsed = parsedDecorators(in: entry.content)
        fields["worldbook"] = .string(worldbook)
        fields["world"] = .string(worldbook)
        fields["uid"] = entry.uid.map(JSONValue.int) ?? .null
        fields["comment"] = .string(entry.comment)
        fields["disable"] = .bool(!entry.isEnabled)
        fields["decorators"] = .array(parsed.decorators.map(JSONValue.string))
        func worldInfoText(_ source: String) -> String {
            RoleplayRegexTransformer.apply(
                RoleplayMacroResolver.resolve(source, context: macroContext),
                rules: regexRules,
                context: .init(placement: .worldInfo, macroContext: macroContext)
            )
        }
        fields["content"] = .string(worldInfoText(parsed.content))
        fields["key"] = .array(entry.keys.map { .string(worldInfoText($0)) })
        fields["keysecondary"] = .array(entry.secondaryKeys.map { .string(worldInfoText($0)) })
        return .dictionary(fields)
    }

    private static func log(_ errors: [String]) {
        for error in errors where !error.isEmpty {
            logger.error("提示词模板条目执行失败: \(error, privacy: .public)")
        }
    }

    private static func javaScript(payloadJSON: String) -> String {
        #"""
        (async () => {
          const payload = \#(payloadJSON);
          const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
          const scopes = clone(payload.scopes || {});
          const initial = clone(payload.initial || {});
          const chat = clone(payload.chat || []);
          const activations = new Map();
          const errors = [];
          let traceID = 0;
          let nesting = 0;

          const pathParts = path => {
            if (Array.isArray(path)) return path.map(String);
            const source = String(path ?? '');
            const result = [];
            let index = 0;
            while (index < source.length) {
              if (source[index] === '.') { index += 1; continue; }
              if (source[index] === '[') {
                index += 1;
                while (/\s/.test(source[index] || '')) index += 1;
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
              if (value) result.push(value);
            }
            return result;
          };
          const getPath = (root, path, fallback = undefined) => {
            if (path === null || path === undefined || path === '') return root === undefined ? fallback : root;
            let value = root;
            for (const part of pathParts(path)) {
              if (value == null || !Object.prototype.hasOwnProperty.call(Object(value), part)) return fallback;
              value = value[part];
            }
            return value === undefined ? fallback : value;
          };
          const hasPath = (root, path) => getPath(root, path, undefined) !== undefined;
          const setPath = (root, path, value) => {
            const parts = pathParts(path);
            if (!parts.length) {
              if (value && typeof value === 'object') Object.assign(root, clone(value));
              return value;
            }
            let target = root;
            for (let index = 0; index < parts.length - 1; index += 1) {
              const key = parts[index];
              if (target[key] == null || typeof target[key] !== 'object') target[key] = /^-?\d+$/.test(parts[index + 1]) ? [] : {};
              target = target[key];
            }
            target[parts.at(-1)] = clone(value);
            return value;
          };
          const deletePath = (root, path) => {
            const parts = pathParts(path);
            if (!parts.length) {
              const changed = Object.keys(root || {}).length > 0;
              Object.keys(root || {}).forEach(key => delete root[key]);
              return changed;
            }
            let target = root;
            for (const part of parts.slice(0, -1)) {
              if (target?.[part] == null || typeof target[part] !== 'object') return false;
              target = target[part];
            }
            if (Array.isArray(target) && /^-?\d+$/.test(parts.at(-1))) {
              const index = Number(parts.at(-1));
              if (index < 0 || index >= target.length) return false;
              target.splice(index, 1);
              return true;
            }
            return delete target[parts.at(-1)];
          };
          const mergeValue = (target, source) => {
            for (const [key, value] of Object.entries(source || {})) {
              if (Array.isArray(value)) target[key] = clone(value);
              else if (value && typeof value === 'object') {
                if (!target[key] || typeof target[key] !== 'object' || Array.isArray(target[key])) target[key] = {};
                mergeValue(target[key], value);
              } else target[key] = value;
            }
            return target;
          };
          const optionsOf = option => {
            if (typeof option === 'string') {
              if (['old', 'new', 'fullcache'].includes(option)) return { results: option };
              if (['nx', 'xx', 'nxs', 'xxs', 'n'].includes(option)) return { flags: option };
              if (['cache', 'global', 'local', 'message', 'initial'].includes(option)) return { scope: option, inscope: option, outscope: option };
            }
            if (typeof option === 'boolean') return { dryRun: option };
            return option || {};
          };
          const normalizeMessageIndex = value => {
            const number = Number(value);
            return number < 0 ? chat.length + number : number;
          };
          const selectedMessage = (filter = {}, getter = false) => {
            let messageIndex;
            if (filter.id !== undefined) messageIndex = normalizeMessageIndex(filter.id);
            else if (filter.role) {
              messageIndex = chat.findLastIndex(message => {
                const roleMatches = filter.role === 'any' || message.role === filter.role;
                const swipe = message.swipe_id || 0;
                return roleMatches && (!getter || message.variables?.[swipe]?.initialized);
              });
            } else {
              messageIndex = Math.min(Math.max(payload.currentMessageIndex ?? chat.length - 1, 0), chat.length - 1);
              if (getter) {
                for (let index = messageIndex; index >= 0; index -= 1) {
                  const swipe = chat[index]?.swipe_id || 0;
                  if (chat[index]?.variables?.[swipe]?.initialized) { messageIndex = index; break; }
                }
              }
            }
            const message = chat[messageIndex];
            if (!message) return null;
            let swipe = filter.swipe_id ?? message.swipe_id ?? 0;
            if (swipe < 0) swipe = message.variables.length + swipe;
            message.variables[swipe] ||= { key: '', initialized: false, value: {} };
            return { message, messageIndex, swipe, scope: message.variables[swipe] };
          };
          const currentMessage = () => selectedMessage({}, false);
          const clonePreviousMessage = () => {
            const selected = currentMessage();
            if (!selected || selected.scope.initialized || selected.messageIndex <= 0) return false;
            let previous = {};
            for (let index = selected.messageIndex - 1; index >= 0; index -= 1) {
              const message = chat[index];
              const scope = message?.variables?.[message.swipe_id || 0];
              if (scope?.initialized) { previous = scope.value; break; }
            }
            selected.scope.value = Object.assign({}, clone(previous), selected.scope.value || {});
            selected.scope.initialized = true;
            return true;
          };
          clonePreviousMessage();
          const current = currentMessage();
          let cacheVariables = Object.assign(
            {}, scopes.global || {}, initial, scopes.chat || {}, current?.scope.value || {},
            { _trace_id: traceID++, _modify_id: 0 }
          );
          const scopedRoot = (scope, withMsg = undefined, getter = false) => {
            switch (scope) {
              case 'global': return scopes.global ||= {};
              case 'local': return scopes.chat ||= {};
              case 'initial': return initial;
              case 'message': return (withMsg ? selectedMessage(withMsg, getter) : currentMessage())?.scope.value || {};
              case 'cache': default: return cacheVariables;
            }
          };
          const readIndexed = (root, key, index, fallback) => {
            const stored = getPath(root, key, undefined);
            if (index == null) return stored === undefined ? fallback : stored;
            let decoded = stored;
            if (typeof decoded === 'string') {
              try { decoded = JSON.parse(decoded || '{}'); } catch (_) { decoded = {}; }
            }
            return clone(getPath(decoded || {}, Number.isNaN(Number(index)) ? index : Number(index), fallback));
          };
          const getvar = (key, rawOptions = {}) => {
            const options = optionsOf(rawOptions);
            const scope = options.scope || 'cache';
            const root = scope === 'message' && !options.withMsg
              ? cacheVariables
              : scopedRoot(scope, options.withMsg, true);
            const value = readIndexed(root, key, options.index, options.defaults);
            return options.clone ? clone(value) : value;
          };
          const writeScope = (scope, key, value, options) => {
            const root = scopedRoot(scope, options.withMsg, false);
            if (options.index != null) {
              let decoded = getPath(root, key, '{}');
              try { decoded = typeof decoded === 'string' ? JSON.parse(decoded || '{}') : clone(decoded || {}); }
              catch (_) { decoded = {}; }
              const index = Number.isNaN(Number(options.index)) ? options.index : Number(options.index);
              value === undefined ? deletePath(decoded, index) : setPath(decoded, index, value);
              setPath(root, key, JSON.stringify(decoded));
            } else if (value === undefined) deletePath(root, key);
            else setPath(root, key, value);
            if (scope === 'message') {
              const selected = options.withMsg ? selectedMessage(options.withMsg, false) : currentMessage();
              if (selected) selected.scope.initialized = true;
            }
          };
          const setvar = (key, value, rawOptions = {}) => {
            const options = optionsOf(rawOptions);
            const scope = options.scope || 'message';
            const cacheHas = hasPath(cacheVariables, key);
            const scopedValue = getvar(key, { ...options, scope });
            if ((options.flags === 'nx' && cacheHas) || (options.flags === 'xx' && !cacheHas) ||
                (options.flags === 'nxs' && scopedValue !== undefined) || (options.flags === 'xxs' && scopedValue === undefined)) return undefined;
            const oldValue = options.results === 'old' || options.merge ? clone(getvar(key, { ...options, scope: 'cache' })) : undefined;
            let next = clone(value);
            if (options.merge) {
              if (Array.isArray(next) && (oldValue === undefined || Array.isArray(oldValue))) next = [...(oldValue || []), ...next];
              else if (next && typeof next === 'object') next = mergeValue(clone(oldValue || {}), next);
            }
            writeScope(scope, key, next, options);
            next === undefined ? deletePath(cacheVariables, key) : setPath(cacheVariables, key, next);
            cacheVariables._modify_id = Number(cacheVariables._modify_id || 0) + 1;
            if (options.results === 'old') return oldValue;
            if (options.results === 'fullcache') return cacheVariables;
            return next;
          };
          const delvar = (key, index = undefined, rawOptions = {}) => {
            if (index && typeof index === 'object' && !Array.isArray(index)) { rawOptions = index; index = undefined; }
            if (index == null) return setvar(key, undefined, rawOptions);
            const value = clone(getvar(key, rawOptions));
            if (Array.isArray(value)) {
              const found = value.findIndex(item => JSON.stringify(item) === JSON.stringify(index));
              if (found >= 0) value.splice(found, 1); else return undefined;
            } else if (value && typeof value === 'object') {
              if (!Object.prototype.hasOwnProperty.call(value, String(index))) return undefined;
              delete value[String(index)];
            } else if (typeof value === 'string' && typeof index === 'string') {
              if (!value.includes(index)) return undefined;
              return setvar(key, value.replace(index, ''), rawOptions);
            } else return undefined;
            return setvar(key, value, rawOptions);
          };
          const insvar = (key, value, index = undefined, rawOptions = {}) => {
            const options = optionsOf(rawOptions);
            const currentValue = clone(getvar(key, options));
            if (Array.isArray(currentValue)) {
              const target = index == null ? currentValue.length : Math.max(0, Number(index) < 0 ? currentValue.length + Number(index) : Number(index));
              currentValue.splice(target, 0, value);
            } else if (currentValue && typeof currentValue === 'object' && index != null) {
              const exists = Object.prototype.hasOwnProperty.call(currentValue, String(index));
              if ((options.flags || '').includes('nx') && exists) return undefined;
              if ((options.flags || '').includes('xx') && !exists) return undefined;
              currentValue[String(index)] = value;
            } else if (typeof currentValue === 'string') {
              const text = String(value);
              if (index == null) return setvar(key, currentValue + text, options);
              const target = typeof index === 'string' ? currentValue.indexOf(index) : (Number(index) < 0 ? currentValue.length + Number(index) : Number(index));
              if (target < 0) return undefined;
              return setvar(key, currentValue.slice(0, target) + text + currentValue.slice(target), options);
            } else return undefined;
            return setvar(key, currentValue, options);
          };
          const incvar = (key, amount = 1, rawOptions = {}) => {
            const options = optionsOf(rawOptions);
            const scopedValue = getvar(key, {
              index: options.index, withMsg: options.withMsg, scope: options.inscope, defaults: options.defaults ?? 0
            });
            const cacheHas = hasPath(cacheVariables, key);
            const allowed = options.flags == null || options.flags === 'n' ||
              (options.flags === 'nx' && !cacheHas) ||
              (options.flags === 'xx' && cacheHas) ||
              (options.flags === 'nxs' && scopedValue === undefined) ||
              (options.flags === 'xxs' && scopedValue !== undefined);
            if (!allowed) return undefined;
            const currentValue = Number(scopedValue ?? options.defaults ?? 0);
            let next = currentValue + Number(amount);
            if (options.min != null) next = Math.max(next, Number(options.min));
            if (options.max != null) next = Math.min(next, Number(options.max));
            return setvar(key, next, {
              index: options.index, withMsg: options.withMsg, scope: options.outscope,
              results: options.results, flags: 'n'
            });
          };
          const findVariables = (key = undefined, messageID = chat.length) => {
            for (let index = Math.min(Number(messageID) - 1, chat.length - 1); index >= 0; index -= 1) {
              const message = chat[index];
              const scope = message?.variables?.[message.swipe_id || 0];
              if (scope?.initialized && (key == null || getPath(scope.value, key, null) != null)) return scope.value;
            }
            return {};
          };

          const roleMatches = (message, role) => !role || role === 'any' || message.role === role;
          const getChatMessage = (index, role = undefined) => {
            const messages = chat.filter(message => roleMatches(message, role));
            const normalized = index < 0 ? messages.length + index : index;
            return messages[normalized]?.message || '';
          };
          const getChatMessages = (startOrCount = chat.length, endOrRole = undefined, role = undefined) => {
            let messages = chat;
            let start = 0;
            let end = undefined;
            if (typeof endOrRole === 'string') {
              messages = messages.filter(message => roleMatches(message, endOrRole));
              if (startOrCount < 0) start = startOrCount; else end = startOrCount;
            }
            else if (typeof endOrRole === 'number') { messages = messages.filter(message => roleMatches(message, role)); start = startOrCount; end = endOrRole; }
            else if (startOrCount < 0) start = startOrCount;
            else end = startOrCount;
            return messages.slice(start, end).map(message => message.message);
          };
          const matchChatMessages = (patterns, options = {}) => {
            const values = Array.isArray(patterns) ? patterns : [patterns];
            return getChatMessages(options.start ?? -2, options.end, options.role).some(message =>
              options.and ? values.every(pattern => String(message).match(pattern)) : values.some(pattern => String(message).match(pattern))
            );
          };

          const entryMatches = (entry, worldbook, title) => {
            const worldMatches = !worldbook || (worldbook instanceof RegExp ? worldbook.test(entry.worldbook) : entry.worldbook === String(worldbook));
            if (!worldMatches) return false;
            if (title instanceof RegExp) return title.test(entry.comment);
            return entry.comment === String(title) || String(entry.uid) === String(title);
          };
          const findEntry = (worldbook, title, currentEntry) => {
            const preferred = worldbook || currentEntry?.worldbook || payload.defaultWorldbook;
            return payload.entries.find(entry => entryMatches(entry, preferred, title)) || null;
          };
          const entriesFor = name => clone(payload.entries.filter(entry => !name || entry.worldbook === String(name)));
          const parseRegex = source => {
            const text = String(source || '');
            if (!text.startsWith('/')) return null;
            const closing = text.lastIndexOf('/');
            if (closing <= 0) return null;
            try { return new RegExp(text.slice(1, closing), text.slice(closing + 1)); }
            catch (_) { return null; }
          };
          const keywordMatches = (entry, haystack, keyword) => {
            const regex = parseRegex(keyword);
            if (regex) return regex.test(haystack);
            const caseSensitive = Boolean(entry.caseSensitive ?? entry.case_sensitive ?? false);
            const wholeWords = Boolean(entry.matchWholeWords ?? entry.match_whole_words ?? false);
            const source = caseSensitive ? String(haystack) : String(haystack).toLowerCase();
            const needle = caseSensitive ? String(keyword) : String(keyword).toLowerCase();
            if (!wholeWords || /\s/.test(needle)) return source.includes(needle);
            const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            return new RegExp(`(?:^|\\W)${escaped}(?:$|\\W)`).test(source);
          };
          const entryScore = (entry, trigger) => [...(entry.key || []), ...(entry.keysecondary || [])]
            .filter(keyword => keywordMatches(entry, trigger, keyword)).length;
          const selectActivatedEntries = (rawEntries, keywords, condition = {}) => {
            const trigger = (Array.isArray(keywords) ? keywords : [keywords]).join('\n\n');
            const activated = [];
            for (const entry of rawEntries || []) {
              const vectorized = Boolean(entry.vectorized ?? entry.metadata?.vectorized ?? entry.metadata?.extensions?.vectorized);
              if (condition.constant != null && Boolean(entry.constant) !== Boolean(condition.constant)) continue;
              if (condition.disabled != null && Boolean(entry.disable) !== Boolean(condition.disabled)) continue;
              if (condition.vectorized != null && vectorized !== Boolean(condition.vectorized)) continue;
              if (entry.useProbability && Number(entry.probability ?? 100) < Math.floor(Math.random() * 100) + 1) continue;
              if (entry.constant || (entry.decorators || []).some(value => value.startsWith('@@activate'))) { activated.push(entry); continue; }
              if ((entry.decorators || []).some(value => value.startsWith('@@dont_activate') || value.startsWith('@@only_preload'))) continue;
              const primary = (entry.key || []).some(keyword => keywordMatches(entry, trigger, keyword));
              if (!primary) continue;
              const secondary = entry.keysecondary || [];
              if (!secondary.length) { activated.push(entry); continue; }
              const matches = secondary.map(keyword => keywordMatches(entry, trigger, keyword));
              const logic = String(entry.selectiveLogic || entry.selective_logic || 'AND_ANY').toUpperCase();
              if ((logic === 'AND_ANY' && matches.some(Boolean)) ||
                  (logic === 'AND_ALL' && matches.every(Boolean)) ||
                  (logic === 'NOT_ANY' && !matches.some(Boolean)) ||
                  (logic === 'NOT_ALL' && !matches.every(Boolean))) activated.push(entry);
            }
            const ungrouped = activated.filter(entry => !String(entry.group || '').trim());
            const grouped = Object.groupBy
              ? Object.groupBy(activated.filter(entry => String(entry.group || '').trim()), entry => String(entry.group).trim())
              : activated.filter(entry => String(entry.group || '').trim()).reduce((result, entry) => {
                  const name = String(entry.group).trim();
                  (result[name] ||= []).push(entry);
                  return result;
                }, {});
            for (const entries of Object.values(grouped || {})) {
              if (entries.length === 1) { ungrouped.push(entries[0]); continue; }
              const prioritized = entries.filter(entry => entry.groupOverride);
              if (prioritized.length) {
                ungrouped.push(prioritized.sort((lhs, rhs) => Number(lhs.order || 0) - Number(rhs.order || 0))[0]);
                continue;
              }
              if (entries.some(entry => entry.useGroupScoring)) {
                ungrouped.push(entries.sort((lhs, rhs) => entryScore(rhs, trigger) - entryScore(lhs, trigger))[0]);
                continue;
              }
              const total = entries.reduce((sum, entry) => sum + Number(entry.groupWeight || 1), 0);
              let roll = Math.random() * total;
              ungrouped.push(entries.find(entry => (roll -= Number(entry.groupWeight || 1)) <= 0) || entries[0]);
            }
            return clone(ungrouped);
          };
          const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
          const normalizeTemplate = template => String(template ?? '')
            .replace(/[ \t]*<%_/g, '<%')
            .replace(/_%>[ \t]*(?:\r?\n)?/g, '%>')
            .replace(/-%>\r?\n/g, '%>');
          const compile = template => {
            template = normalizeTemplate(template);
            const matcher = /<%([=\-#%]?)([\s\S]*?)%>/g;
            let cursor = 0;
            let body = '';
            const literal = value => { if (value) body += `__out += ${JSON.stringify(value)};\n`; };
            let match;
            while ((match = matcher.exec(template)) !== null) {
              literal(template.slice(cursor, match.index));
              if (match[1] === '%') literal(`<%${match[2]}%>`);
              else if (match[1] === '=' || match[1] === '-') body += `__out += __string(await (${match[2]}));\n`;
              else if (match[1] !== '#') body += `${match[2]}\n`;
              cursor = match.index + match[0].length;
            }
            literal(template.slice(cursor));
            return new AsyncFunction('__ctx', `let __out = ''; const __string = value => value == null ? '' : String(value); const print = (...args) => { __out += args.join(' '); }; with (__ctx) { ${body} } return __out;`);
          };
          const renderOne = async (template, currentEntry = null, overrides = {}) => {
            if (!String(template ?? '').includes('<%')) return String(template ?? '');
            if (nesting >= 20) throw new Error('Prompt Template nesting limit exceeded');
            nesting += 1;
            const context = {
              ...payload.names,
              ...overrides,
              chat,
              world_info: currentEntry,
              get variables() { return cacheVariables; },
              getvar,
              setvar,
              delvar,
              insvar,
              incvar,
              decvar: (key, value = 1, options = {}) => incvar(key, -Number(value), options),
              getLocalVar: (key, options = {}) => getvar(key, { ...optionsOf(options), scope: 'local' }),
              setLocalVar: (key, value, options = {}) => setvar(key, value, { ...optionsOf(options), scope: 'local' }),
              delLocalVar: (key, index, options = {}) => index && typeof index === 'object'
                ? delvar(key, undefined, { ...optionsOf(index), scope: 'local' })
                : delvar(key, index, { ...optionsOf(options), scope: 'local' }),
              insertLocalVar: (key, value, index, options = {}) => insvar(key, value, index, { ...optionsOf(options), scope: 'local' }),
              incLocalVar: (key, value = 1, options = {}) => incvar(key, value, { ...optionsOf(options), inscope: 'local', outscope: 'local' }),
              decLocalVar: (key, value = 1, options = {}) => incvar(key, -Number(value), { ...optionsOf(options), inscope: 'local', outscope: 'local' }),
              getGlobalVar: (key, options = {}) => getvar(key, { ...optionsOf(options), scope: 'global' }),
              setGlobalVar: (key, value, options = {}) => setvar(key, value, { ...optionsOf(options), scope: 'global' }),
              delGlobalVar: (key, index, options = {}) => index && typeof index === 'object'
                ? delvar(key, undefined, { ...optionsOf(index), scope: 'global' })
                : delvar(key, index, { ...optionsOf(options), scope: 'global' }),
              insertGlobalVar: (key, value, index, options = {}) => insvar(key, value, index, { ...optionsOf(options), scope: 'global' }),
              incGlobalVar: (key, value = 1, options = {}) => incvar(key, value, { ...optionsOf(options), inscope: 'global', outscope: 'global' }),
              decGlobalVar: (key, value = 1, options = {}) => incvar(key, -Number(value), { ...optionsOf(options), inscope: 'global', outscope: 'global' }),
              getMessageVar: (key, options = {}) => getvar(key, { ...optionsOf(options), scope: 'message' }),
              setMessageVar: (key, value, options = {}) => setvar(key, value, { ...optionsOf(options), scope: 'message' }),
              delMessageVar: (key, index, options = {}) => index && typeof index === 'object'
                ? delvar(key, undefined, { ...optionsOf(index), scope: 'message' })
                : delvar(key, index, { ...optionsOf(options), scope: 'message' }),
              insertMessageVar: (key, value, index, options = {}) => insvar(key, value, index, { ...optionsOf(options), scope: 'message' }),
              incMessageVar: (key, value = 1, options = {}) => incvar(key, value, { ...optionsOf(options), inscope: 'message', outscope: 'message' }),
              decMessageVar: (key, value = 1, options = {}) => incvar(key, -Number(value), { ...optionsOf(options), inscope: 'message', outscope: 'message' }),
              findVariables,
              getChatMessage,
              getChatMessages,
              matchChatMessages,
              getWorldInfoData: entriesFor,
              getWorldInfoComments: name => entriesFor(name).map(entry => entry.comment),
              getEnabledLoreBooks: () => [...new Set(payload.entries.map(entry => entry.worldbook))],
              getEnabledWorldInfoEntries: () => clone(payload.entries),
              selectActivatedEntries,
              getWorldInfoActivatedData: (name, keywords, condition = {}) => selectActivatedEntries(entriesFor(name), keywords, condition),
              loadWorldInfoJSON: name => ({ entries: Object.fromEntries(entriesFor(name).map(entry => [String(entry.uid), entry])) }),
              _: {
                get: getPath, set: setPath, unset: deletePath, has: hasPath, cloneDeep: clone,
                isArray: Array.isArray,
                isPlainObject: value => value != null && typeof value === 'object' && !Array.isArray(value),
                merge: (...items) => items.reduce((result, item) => mergeValue(result, item), {}),
                mergeWith: (...items) => items.filter(item => typeof item !== 'function').reduce((result, item) => mergeValue(result, item), {}),
                castArray: value => Array.isArray(value) ? value : [value],
                entries: Object.entries,
                hasIn: hasPath,
                random: (min, max) => Math.floor(Math.random() * (Number(max) - Number(min) + 1)) + Number(min)
              }
            };
            context.getwi = context.getWorldInfo = async (first, second = {}, data = {}) => {
              const secondIsData = second == null || (typeof second === 'object' && !(second instanceof RegExp));
              const worldbook = secondIsData ? (currentEntry?.worldbook || payload.defaultWorldbook) : first;
              const title = secondIsData ? first : second;
              const childData = secondIsData ? (second || {}) : (data || {});
              const entry = findEntry(worldbook, title, currentEntry);
              return entry ? renderOne(entry.content, entry, childData) : '';
            };
            context.activewi = context.activateWorldInfo = async (first, second = undefined, third = false) => {
              const shorthand = typeof second === 'boolean' || second === undefined;
              const worldbook = shorthand ? (currentEntry?.worldbook || payload.defaultWorldbook) : first;
              const title = shorthand ? first : second;
              const force = Boolean(shorthand ? second : third);
              const entry = findEntry(worldbook, title, currentEntry);
              if (!entry) return null;
              activations.set(`${entry.worldbook}.${entry.uid}`, {
                worldbook: entry.worldbook,
                title: entry.uid == null ? entry.comment : String(entry.uid),
                force
              });
              return clone(entry);
            };
            context.activateWorldInfoByKeywords = async (keywords, condition = {}) => {
              const entries = selectActivatedEntries(payload.entries, keywords, condition);
              for (const entry of entries) {
                await context.activewi(entry.worldbook, entry.uid, Boolean(condition.force));
              }
              return entries;
            };
            context.evalTemplate = async (content, data = {}) => renderOne(content, currentEntry, data);
            try { return await compile(template)(context); }
            finally { nesting -= 1; }
          };

          const outputs = [];
          const primaryKeys = [];
          const secondaryKeys = [];
          for (let index = 0; index < payload.templates.length; index += 1) {
            const currentEntry = payload.current[index] || null;
            try {
              outputs.push(await renderOne(payload.templates[index], currentEntry));
              primaryKeys.push(currentEntry ? await Promise.all((currentEntry.key || []).map(key => renderOne(key, currentEntry))) : []);
              secondaryKeys.push(currentEntry ? await Promise.all((currentEntry.keysecondary || []).map(key => renderOne(key, currentEntry))) : []);
            } catch (error) {
              outputs.push(payload.templates[index]);
              primaryKeys.push(currentEntry?.key || []);
              secondaryKeys.push(currentEntry?.keysecondary || []);
              errors.push(error?.stack || error?.message || String(error));
            }
          }
          const messageScopes = {};
          for (const message of chat) {
            for (const scope of message.variables || []) {
              if (scope.initialized && scope.key) messageScopes[scope.key] = clone(scope.value || {});
            }
          }
          return JSON.stringify({
            outputs,
            primaryKeys,
            secondaryKeys,
            activations: [...activations.values()],
            scopes,
            initial,
            messageScopes,
            errors
          });
        })()
        """#
    }
}

private enum RoleplayPromptTemplateJavaScript {
    private final class EvaluationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<String?, Error>
        private var retainedObject: AnyObject?

        init(continuation: CheckedContinuation<String?, Error>, retainedObject: AnyObject?) {
            self.continuation = continuation
            self.retainedObject = retainedObject
        }

        func finish(_ result: Result<String?, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            retainedObject = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    enum EvaluationError: LocalizedError {
        case unavailable
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: return "当前平台没有可用的提示词模板 JavaScript 运行时。"
            case .failed(let message): return message
            case .timedOut: return "提示词模板执行超时。"
            }
        }
    }

    static func evaluate(_ script: String) async throws -> String? {
        #if canImport(JavaScriptCore) && !os(watchOS)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let context = JSContext() else {
                    continuation.resume(throwing: EvaluationError.unavailable)
                    return
                }
                let gate = EvaluationGate(continuation: continuation, retainedObject: context)
                let resolve: @convention(block) (String) -> Void = { value in
                    gate.finish(.success(value))
                }
                let reject: @convention(block) (String) -> Void = { message in
                    gate.finish(.failure(EvaluationError.failed(message)))
                }
                context.setObject(resolve, forKeyedSubscript: "__etosTemplateResolve" as NSString)
                context.setObject(reject, forKeyedSubscript: "__etosTemplateReject" as NSString)
                context.evaluateScript("""
                Promise.resolve(\(script)).then(
                  value => __etosTemplateResolve(String(value)),
                  error => __etosTemplateReject(String(error?.stack || error?.message || error))
                );
                """)
                if let exception = context.exception?.toString() {
                    gate.finish(.failure(EvaluationError.failed(exception)))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                    gate.finish(.failure(EvaluationError.timedOut))
                }
            }
        }
        #elseif os(watchOS)
        return try await evaluateWithWatchWebKit(script)
        #else
        throw EvaluationError.unavailable
        #endif
    }

    #if os(watchOS)
    @MainActor
    private static func evaluateWithWatchWebKit(_ script: String) async throws -> String? {
        _ = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY)
        guard let webViewClass = NSClassFromString("WKWebView") as? NSObject.Type else {
            throw EvaluationError.unavailable
        }
        let webView = webViewClass.init()
        _ = try await evaluateRaw(
            """
            window.__etosTemplateState = { done: false, value: null, error: null };
            Promise.resolve(\(script)).then(
              value => { window.__etosTemplateState = { done: true, value: String(value), error: null }; },
              error => { window.__etosTemplateState = { done: true, value: null, error: String(error?.stack || error?.message || error) }; }
            );
            'started';
            """,
            webView: webView
        )
        for _ in 0..<1_000 {
            try await Task.sleep(for: .milliseconds(10))
            guard let stateJSON = try await evaluateRaw(
                "JSON.stringify(window.__etosTemplateState)",
                webView: webView
            ) as? String,
            let data = stateJSON.data(using: .utf8),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            state["done"] as? Bool == true else { continue }
            if let error = state["error"] as? String, !error.isEmpty {
                throw EvaluationError.failed(error)
            }
            return state["value"] as? String
        }
        throw EvaluationError.timedOut
    }

    @MainActor
    private static func evaluateRaw(_ script: String, webView: NSObject) async throws -> Any? {
        let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard webView.responds(to: selector) else { throw EvaluationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (Any?, Error?) -> Void = { value, error in
                if let error {
                    continuation.resume(throwing: EvaluationError.failed(error.localizedDescription))
                } else {
                    continuation.resume(returning: value)
                }
            }
            let completionObject = unsafeBitCast(completion, to: AnyObject.self)
            webView.perform(selector, with: script as NSString, with: completionObject)
        }
    }
    #endif
}
