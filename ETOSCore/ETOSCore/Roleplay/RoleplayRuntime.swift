// ============================================================================
// RoleplayRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 将会话绑定解析成提示词、宏上下文、世界书、正则和 MVU 运行状态。
// ============================================================================

import Foundation

struct ResolvedRoleplaySession {
    var binding: SessionRoleplayBinding
    var characters: [RoleplayCharacter]
    var persona: PersonaProfile?
    var variables: RoleplayVariableSnapshot
    var macroContext: RoleplayMacroContext

    var regexRules: [RoleplayRegexRule] {
        characters.flatMap(\.regexRules)
    }

    var worldbookIDs: [UUID] {
        var seen = Set<UUID>()
        return (characters.compactMap(\.embeddedWorldbookID) + binding.additionalWorldbookIDs)
            .filter { seen.insert($0).inserted }
    }
}

enum RoleplayRuntime {
    static func resolve(
        sessionID: UUID,
        messages: [ChatMessage],
        store: RoleplayStore
    ) -> ResolvedRoleplaySession? {
        guard let binding = store.binding(sessionID: sessionID), !binding.characterIDs.isEmpty else { return nil }
        let characters = binding.characterIDs.compactMap(store.character(id:))
        guard !characters.isEmpty else { return nil }
        let variables = store.variableSnapshot(sessionID: sessionID)
        let messageContext = latestVariableMessage(in: messages, variables: variables)
        let lastMessage = messages.last(where: { $0.role == .user || $0.role == .assistant })?.content ?? ""
        let lastUserMessage = messages.last(where: { $0.role == .user })?.content ?? ""
        let lastCharacterMessage = messages.last(where: { $0.role == .assistant })?.content ?? ""
        let persona = binding.personaID.flatMap(store.persona(id:))
        let macroContext = RoleplayMacroContext(
            character: characters.first,
            persona: persona,
            variables: variables,
            messageID: messageContext?.id,
            messageVersionIndex: messageContext?.getCurrentVersionIndex() ?? 0,
            lastMessage: lastMessage,
            lastUserMessage: lastUserMessage,
            lastCharacterMessage: lastCharacterMessage,
            userAvatarPath: persona?.avatarFileName ?? "",
            characterAvatarPath: characters.first?.avatarFileName ?? "",
            currentSwipeID: messageContext.map { $0.getCurrentVersionIndex() },
            lastSwipeID: messageContext.map { max(0, $0.getAllVersions().count - 1) },
            messageCount: messages.count,
            chatSeed: sessionID.uuidString,
            customValues: variables.customMacros
        )
        return ResolvedRoleplaySession(
            binding: binding,
            characters: characters,
            persona: persona,
            variables: variables,
            macroContext: macroContext
        )
    }

    static func roleplaySystemPrompt(_ resolved: ResolvedRoleplaySession) -> String {
        var sections: [String] = []
        if let persona = resolved.persona {
            let description = RoleplayMacroResolver.resolve(persona.description, context: resolved.macroContext)
            sections.append("<roleplay_persona name=\"\(xmlEscaped(persona.name))\">\n\(description)\n</roleplay_persona>")
        }
        for character in resolved.characters {
            let fields: [(String, String)] = [
                ("description", character.description),
                ("personality", character.personality),
                ("scenario", character.scenario),
                ("system_prompt", character.systemPrompt),
                ("message_examples", character.messageExamples)
            ]
            let content = fields.compactMap { tag, raw -> String? in
                let resolvedValue = RoleplayMacroResolver.resolve(raw, context: resolved.macroContext)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolvedValue.isEmpty else { return nil }
                return "<\(tag)>\n\(resolvedValue)\n</\(tag)>"
            }.joined(separator: "\n")
            sections.append("<roleplay_character name=\"\(xmlEscaped(character.name))\">\n\(content)\n</roleplay_character>")
        }
        return sections.joined(separator: "\n\n")
    }

    static func postHistoryPrompt(_ resolved: ResolvedRoleplaySession) -> String? {
        let content = resolved.characters
            .map(\.postHistoryInstructions)
            .map { RoleplayMacroResolver.resolve($0, context: resolved.macroContext) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return content.isEmpty ? nil : content
    }

    static func transformedRequestMessages(
        _ messages: [ChatMessage],
        resolved: ResolvedRoleplaySession
    ) -> [ChatMessage] {
        messages.enumerated().map { index, message in
            let placement: RoleplayRegexPlacement?
            switch message.role {
            case .user: placement = .userInput
            case .assistant: placement = .aiOutput
            case .system, .tool, .error: placement = nil
            }
            var transformed = message
            var content = RoleplayMacroResolver.resolve(message.content, context: resolved.macroContext)
            if let placement {
                let depth = max(0, messages.count - index - 1)
                content = RoleplayRegexTransformer.apply(
                    content,
                    rules: resolved.regexRules,
                    context: .init(
                        placement: placement,
                        depth: depth,
                        macroContext: resolved.macroContext
                    )
                )
                content = RoleplayRegexTransformer.apply(
                    content,
                    rules: resolved.regexRules,
                    context: .init(
                        placement: placement,
                        isPrompt: true,
                        depth: depth,
                        macroContext: resolved.macroContext
                    )
                )
            }
            transformed.content = content
            return transformed
        }
    }

    static func resolvedWorldbooks(
        _ worldbooks: [Worldbook],
        macroContext: RoleplayMacroContext
    ) -> [Worldbook] {
        worldbooks.map { worldbook in
            var updated = worldbook
            updated.entries = worldbook.entries.map { entry in
                var entry = entry
                entry.keys = entry.keys.map { RoleplayMacroResolver.resolve($0, context: macroContext) }
                entry.secondaryKeys = entry.secondaryKeys.map { RoleplayMacroResolver.resolve($0, context: macroContext) }
                entry.content = RoleplayMacroResolver.resolve(entry.content, context: macroContext)
                return entry
            }
            return updated
        }
    }

    static func visualContent(
        _ content: String,
        resolved: ResolvedRoleplaySession,
        depth: Int? = nil
    ) -> String {
        var output = RoleplayRegexTransformer.apply(
            content,
            rules: resolved.regexRules,
            context: .init(
                placement: .aiOutput,
                depth: depth,
                macroContext: resolved.macroContext
            )
        )
        output = RoleplayRegexTransformer.apply(
            output,
            rules: resolved.regexRules,
            context: .init(
                placement: .aiOutput,
                isMarkdown: true,
                depth: depth,
                macroContext: resolved.macroContext
            )
        )
        return RoleplayMVUEngine.strippingUpdateBlock(from: output)
    }

    @discardableResult
    static func processMVU(
        content: String,
        messageID: UUID,
        versionIndex: Int,
        sessionID: UUID,
        previousMessages: [ChatMessage],
        store: RoleplayStore
    ) -> RoleplayMVUResult? {
        guard store.binding(sessionID: sessionID) != nil else { return nil }
        var snapshot = store.variableSnapshot(sessionID: sessionID)
        let existing = snapshot.messageVariables(messageID: messageID, versionIndex: versionIndex)
        if existing.isEmpty,
           let previous = previousMessages.reversed().first(where: {
               !snapshot.messageVariables(
                   messageID: $0.id,
                   versionIndex: $0.getCurrentVersionIndex()
               ).isEmpty
           }) {
            snapshot.replaceMessageVariables(
                snapshot.messageVariables(
                    messageID: previous.id,
                    versionIndex: previous.getCurrentVersionIndex()
                ),
                messageID: messageID,
                versionIndex: versionIndex
            )
        }
        let result = RoleplayMVUEngine.applyUpdates(
            in: content,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: versionIndex
        )
        if result.appliedCommandCount > 0 {
            store.saveVariableSnapshot(result.updatedSnapshot, sessionID: sessionID)
        }
        return result
    }

    private static func latestVariableMessage(
        in messages: [ChatMessage],
        variables: RoleplayVariableSnapshot
    ) -> ChatMessage? {
        messages.reversed().first {
            !variables.messageVariables(
                messageID: $0.id,
                versionIndex: $0.getCurrentVersionIndex()
            ).isEmpty
        } ?? messages.last
    }

    private static func xmlEscaped(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
