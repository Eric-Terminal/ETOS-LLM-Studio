// ============================================================================
// RoleplayPromptTemplateRenderer.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行 Prompt Template 常用 EJS 语法，并在世界书扫描前处理 @@preprocessing。
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
            var worldbook: String?
            var title: String
            var force: Bool
        }

        var outputs: [String]
        var activations: [Activation]
        var scopes: [String: [String: JSONValue]]
    }

    private static let logger = Logger(
        subsystem: "com.ETOS.LLM.Studio",
        category: "RoleplayPromptTemplate"
    )

    static func preprocessWorldbooks(
        _ worldbooks: [Worldbook],
        messages: [ChatMessage],
        macroContext: inout RoleplayMacroContext
    ) async -> [Worldbook] {
        var updated = worldbooks
        var locations: [(bookIndex: Int, entryIndex: Int)] = []
        var templates: [String] = []

        for bookIndex in updated.indices {
            for entryIndex in updated[bookIndex].entries.indices {
                let entry = updated[bookIndex].entries[entryIndex]
                guard isPreprocessingEntry(entry) else { continue }
                locations.append((bookIndex, entryIndex))
                templates.append(strippingPreprocessingDecorator(entry.content))
            }
        }
        guard !templates.isEmpty else { return updated }

        guard let envelope = await render(
            templates,
            worldbooks: updated,
            messages: messages,
            macroContext: macroContext,
            currentEntries: locations.map { Optional(updated[$0.bookIndex].entries[$0.entryIndex]) },
            currentWorldbookNames: locations.map { Optional(updated[$0.bookIndex].name) }
        ) else {
            return updated
        }

        for (offset, location) in locations.enumerated() where envelope.outputs.indices.contains(offset) {
            updated[location.bookIndex].entries[location.entryIndex].content = envelope.outputs[offset]
        }
        apply(envelope.scopes, to: &macroContext)
        apply(envelope.activations, to: &updated)
        return updated
    }

    static func renderMessages(
        _ messagesToRender: [ChatMessage],
        worldbooks: [Worldbook],
        chatHistory: [ChatMessage],
        macroContext: inout RoleplayMacroContext
    ) async -> [ChatMessage] {
        let indexes = messagesToRender.indices.filter { messagesToRender[$0].content.contains("<%") }
        guard !indexes.isEmpty else { return messagesToRender }
        let templates = indexes.map { messagesToRender[$0].content }
        guard let envelope = await render(
            templates,
            worldbooks: worldbooks,
            messages: chatHistory,
            macroContext: macroContext,
            currentEntries: Array(repeating: nil, count: templates.count),
            currentWorldbookNames: Array(repeating: nil, count: templates.count)
        ) else {
            return messagesToRender
        }

        var rendered = messagesToRender
        for (offset, index) in indexes.enumerated() where envelope.outputs.indices.contains(offset) {
            rendered[index].content = envelope.outputs[offset]
        }
        apply(envelope.scopes, to: &macroContext)
        return rendered
    }

    private static func apply(
        _ scopes: [String: [String: JSONValue]],
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
            guard let values = scopes[scope.rawValue] else { continue }
            snapshot.replaceVariables(values, scope: scope)
        }
        if let values = scopes[RoleplayVariableScope.message.rawValue],
           let messageID = macroContext.messageID {
            snapshot.replaceMessageVariables(
                values,
                messageID: messageID,
                versionIndex: macroContext.messageVersionIndex
            )
        }
        macroContext.variables = snapshot
    }

    private static func isPreprocessingEntry(_ entry: WorldbookEntry) -> Bool {
        entry.comment.localizedCaseInsensitiveContains("[Preprocessing]")
            || entry.content.lines.contains { $0.trimmingCharacters(in: .whitespaces) == "@@preprocessing" }
    }

    private static func strippingPreprocessingDecorator(_ content: String) -> String {
        content.lines
            .filter { $0.trimmingCharacters(in: .whitespaces) != "@@preprocessing" }
            .joined(separator: "\n")
    }

    private static func apply(_ activations: [RenderedEnvelope.Activation], to worldbooks: inout [Worldbook]) {
        for activation in activations {
            for bookIndex in worldbooks.indices {
                if let requestedBook = activation.worldbook,
                   !requestedBook.isEmpty,
                   requestedBook != worldbooks[bookIndex].name {
                    continue
                }
                guard let entryIndex = worldbooks[bookIndex].entries.firstIndex(where: { entry in
                    entry.comment == activation.title || entry.uid.map(String.init) == activation.title
                }) else { continue }

                var entry = worldbooks[bookIndex].entries[entryIndex]
                entry.isEnabled = true
                if activation.force {
                    entry.constant = true
                    entry.cooldown = nil
                    entry.delay = nil
                    entry.delayUntilRecursion = false
                    entry.group = nil
                    entry.metadata["vectorized"] = .bool(false)
                    entry.metadata["ignoreBudget"] = .bool(true)
                    entry.content = entry.content.replacingOccurrences(of: "@@dont_activate", with: "")
                }
                worldbooks[bookIndex].entries[entryIndex] = entry
            }
        }
    }

    private static func render(
        _ templates: [String],
        worldbooks: [Worldbook],
        messages: [ChatMessage],
        macroContext: RoleplayMacroContext,
        currentEntries: [WorldbookEntry?],
        currentWorldbookNames: [String?]
    ) async -> RenderedEnvelope? {
        let script: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let payload = makePayload(
                templates: templates,
                worldbooks: worldbooks,
                messages: messages,
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
        macroContext: RoleplayMacroContext,
        currentEntries: [WorldbookEntry?],
        currentWorldbookNames: [String?]
    ) -> JSONValue {
        let entries = worldbooks.flatMap { book in
            book.entries.map { entry in
                JSONValue.dictionary([
                    "worldbook": .string(book.name),
                    "uid": entry.uid.map(JSONValue.int) ?? .null,
                    "comment": .string(entry.comment),
                    "content": .string(entry.content)
                ])
            }
        }
        let chat = messages.enumerated().map { index, message in
            JSONValue.dictionary([
                "message_id": .int(index),
                "role": .string(message.role.rawValue),
                "message": .string(message.content),
                "mes": .string(message.content),
                "is_user": .bool(message.role == .user),
                "is_system": .bool(message.role == .system)
            ])
        }
        let current = templates.indices.map { index -> JSONValue in
            guard currentEntries.indices.contains(index), let entry = currentEntries[index] else { return .null }
            return .dictionary([
                "worldbook": .string(currentWorldbookNames[index] ?? ""),
                "uid": entry.uid.map(JSONValue.int) ?? .null,
                "comment": .string(entry.comment),
                "content": .string(entry.content)
            ])
        }
        let messageVariables: [String: JSONValue]
        if let messageID = macroContext.messageID {
            messageVariables = macroContext.variables.messageVariables(
                messageID: messageID,
                versionIndex: macroContext.messageVersionIndex
            )
        } else {
            messageVariables = [:]
        }
        return .dictionary([
            "templates": .array(templates.map(JSONValue.string)),
            "current": .array(current),
            "entries": .array(entries),
            "chat": .array(chat),
            "scopes": .dictionary([
                "global": .dictionary(macroContext.variables.global),
                "preset": .dictionary(macroContext.variables.preset),
                "character": .dictionary(macroContext.variables.character),
                "persona": .dictionary(macroContext.variables.persona),
                "chat": .dictionary(macroContext.variables.chat),
                "message": .dictionary(messageVariables)
            ]),
            "names": .dictionary([
                "user": .string(macroContext.persona?.name ?? "User"),
                "char": .string(macroContext.character?.name ?? "Assistant"),
                "lastMessage": .string(macroContext.lastMessage),
                "lastUserMessage": .string(macroContext.lastUserMessage),
                "lastCharMessage": .string(macroContext.lastCharacterMessage)
            ])
        ])
    }

    private static func javaScript(payloadJSON: String) -> String {
        #"""
        (() => {
          const payload = #(payloadJSON);
          const activations = [];
          const scopes = payload.scopes || {};
          const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
          const pathParts = path => String(path ?? '').replace(/\[([^\]]+)\]/g, '.$1').split('.').filter(Boolean);
          const getPath = (root, path, fallback) => {
            let value = root;
            for (const part of pathParts(path)) {
              if (value == null || !Object.prototype.hasOwnProperty.call(Object(value), part)) return fallback;
              value = value[part];
            }
            return value === undefined ? fallback : value;
          };
          const setPath = (root, path, value) => {
            const parts = pathParts(path);
            if (!parts.length) return value;
            let target = root;
            for (let index = 0; index < parts.length - 1; index += 1) {
              const key = parts[index];
              if (!target[key] || typeof target[key] !== 'object') target[key] = /^\d+$/.test(parts[index + 1]) ? [] : {};
              target = target[key];
            }
            target[parts[parts.length - 1]] = value;
            return value;
          };
          const mergedVariables = () => Object.assign({}, scopes.global || {}, scopes.preset || {}, scopes.character || {}, scopes.persona || {}, scopes.chat || {}, scopes.message || {});
          let variables = mergedVariables();
          const scopeFor = name => name === 'global' ? (scopes.global ||= {}) : name === 'message' ? (scopes.message ||= {}) : (scopes.chat ||= {});
          const getvar = (path, options = {}) => {
            const option = typeof options === 'string' ? { scope: options } : (options || {});
            const root = option.scope ? scopeFor(option.scope) : variables;
            return clone(getPath(root, path, option.defaults));
          };
          const setvar = (path, value, options = {}) => {
            const option = typeof options === 'string' ? { scope: options } : (options || {});
            setPath(scopeFor(option.scope || 'chat'), path, clone(value));
            variables = mergedVariables();
            return value;
          };
          const removevar = (path, options = {}) => {
            const option = typeof options === 'string' ? { scope: options } : (options || {});
            const parts = pathParts(path); const root = scopeFor(option.scope || 'chat');
            const parent = getPath(root, parts.slice(0, -1).join('.'), null);
            if (parent && parts.length) delete parent[parts[parts.length - 1]];
            variables = mergedVariables();
          };
          const findEntry = (worldbook, title, current) => payload.entries.find(entry => {
            const bookMatches = !worldbook || entry.worldbook === worldbook;
            return bookMatches && (String(entry.uid) === String(title) || entry.comment === String(title));
          }) || null;
          const sanitizeCode = code => code.replace(/\bawait\s+/g, '').replace(/\basync\s+/g, '');
          const compile = template => {
            template = String(template ?? '')
              .replace(/[ \t]*<%_/g, '<%')
              .replace(/_%>[ \t]*/g, '%>')
              .replace(/-%>\r?\n/g, '%>');
            const matcher = /<%([=\-#]?)([\s\S]*?)%>/g;
            let cursor = 0; let body = '';
            const appendLiteral = value => { if (value) body += `__out += ${JSON.stringify(value)};\n`; };
            let match;
            while ((match = matcher.exec(template)) !== null) {
              appendLiteral(template.slice(cursor, match.index));
              const code = sanitizeCode(match[2]);
              if (match[1] === '=' || match[1] === '-') body += `__out += __string((${code}));\n`;
              else if (match[1] !== '#') body += `${code}\n`;
              cursor = match.index + match[0].length;
            }
            appendLiteral(template.slice(cursor));
            return new Function('__ctx', `let __out = ''; const __string = value => value == null ? '' : String(value); const print = (...args) => { __out += args.join(' '); }; with (__ctx) { ${body} } return __out;`);
          };
          let nesting = 0;
          const renderOne = (template, current) => {
            if (!String(template).includes('<%')) return String(template ?? '');
            if (nesting > 20) throw new Error('Prompt Template nesting limit exceeded');
            nesting += 1;
            const ctx = {
              ...payload.names,
              variables,
              chat: payload.chat,
              world_info: current,
              getvar,
              setvar,
              delvar: removevar,
              getLocalVar: (path, options = {}) => getvar(path, { ...options, scope: 'chat' }),
              setLocalVar: (path, value, options = {}) => setvar(path, value, { ...options, scope: 'chat' }),
              getGlobalVar: (path, options = {}) => getvar(path, { ...options, scope: 'global' }),
              setGlobalVar: (path, value, options = {}) => setvar(path, value, { ...options, scope: 'global' }),
              getMessageVar: (path, options = {}) => getvar(path, { ...options, scope: 'message' }),
              setMessageVar: (path, value, options = {}) => setvar(path, value, { ...options, scope: 'message' }),
              incvar: (path, value = 1, options = {}) => setvar(path, Number(getvar(path, { ...options, defaults: 0 })) + Number(value), options),
              decvar: (path, value = 1, options = {}) => setvar(path, Number(getvar(path, { ...options, defaults: 0 })) - Number(value), options),
              getChatMessages: () => clone(payload.chat),
              loadWorldInfoJSON: name => ({ entries: clone(payload.entries.filter(entry => entry.worldbook === name)) }),
              getwi: (first, second = undefined) => {
                const hasBook = second !== undefined && (typeof second !== 'object' || second instanceof RegExp);
                const entry = findEntry(hasBook ? first : current?.worldbook, hasBook ? second : first, current);
                return entry ? renderOne(entry.content, entry) : '';
              },
              activewi: (...args) => {
                const [first, second = undefined, third = false] = args;
                const hasBook = args.length >= 3 || (second !== undefined && typeof second !== 'boolean');
                const worldbook = hasBook ? first : current?.worldbook;
                const title = hasBook ? second : first;
                const force = Boolean(hasBook ? third : second);
                activations.push({ worldbook: worldbook == null ? null : String(worldbook), title: String(title), force });
                return findEntry(worldbook, title, current);
              },
              getWorldInfo: null,
              activateWorldInfo: null,
              _: {
                get: getPath,
                set: setPath,
                has: (root, path) => getPath(root, path, undefined) !== undefined,
                cloneDeep: clone,
                isArray: Array.isArray,
                isPlainObject: value => value != null && typeof value === 'object' && !Array.isArray(value),
                merge: (...items) => Object.assign({}, ...items),
                random: (min, max) => Math.floor(Math.random() * (Number(max) - Number(min) + 1)) + Number(min)
              }
            };
            ctx.getWorldInfo = ctx.getwi;
            ctx.activateWorldInfo = ctx.activewi;
            try { return compile(template)(ctx); }
            finally { nesting -= 1; }
          };
          const outputs = payload.templates.map((template, index) => {
            try { return renderOne(template, payload.current[index]); }
            catch (error) { return template; }
          });
          return JSON.stringify({ outputs, activations, scopes });
        })()
        """#
    }
}

private enum RoleplayPromptTemplateJavaScript {
    enum EvaluationError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "当前平台没有可用的提示词模板 JavaScript 运行时。"
            case .failed(let message): return message
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
                let value = context.evaluateScript(script)
                if let exception = context.exception?.toString() {
                    continuation.resume(throwing: EvaluationError.failed(exception))
                } else {
                    continuation.resume(returning: value?.toString())
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
        let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard webView.responds(to: selector) else { throw EvaluationError.unavailable }

        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (Any?, Error?) -> Void = { value, error in
                if let error {
                    continuation.resume(throwing: EvaluationError.failed(error.localizedDescription))
                } else {
                    continuation.resume(returning: value as? String)
                }
            }
            let completionObject = unsafeBitCast(completion, to: AnyObject.self)
            webView.perform(selector, with: script as NSString, with: completionObject)
        }
    }
    #endif
}

private extension String {
    var lines: [String] {
        components(separatedBy: .newlines)
    }
}
