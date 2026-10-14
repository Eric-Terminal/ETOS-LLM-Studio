import Foundation

/// 仅在后台准备；界面使用已生成的 HTML、变量更新脚本和稳定文档标识。
public struct RoleplayPreparedDocument: Identifiable, Sendable {
    public let id: String
    public let sessionID: UUID
    public let messageID: UUID
    public let versionIndex: Int
    public let scriptID: UUID?
    public let title: String
    public let source: String
    public let html: String
    public let variableUpdate: String
    public let variableRevision: Int
    public let baseURL: URL
    public let bridgeSource: RoleplayBridgeSourceSnapshot
}

public struct RoleplayPreparedButton: Identifiable, Sendable {
    public var id: String { "\(sessionID)|\(scriptID)|\(buttonID)" }
    public let sessionID: UUID
    public let scriptID: UUID
    public let buttonID: UUID
    public let name: String
}

public struct RoleplayPresentationSnapshot: Sendable {
    public let sessionID: UUID
    public let binding: SessionRoleplayBinding?
    public let variables: RoleplayVariableSnapshot
    private let resolved: ResolvedRoleplaySession?
    private let messages: [ChatMessage]
    private let worldbooks: [Worldbook]
    private let baseURL: URL
    private let contentIdentity: Int
    private let historyIdentity: Int
    private let depths: [UUID: Int]

    public init(sessionID: UUID, messages: [ChatMessage], worldbooks: [Worldbook], store: RoleplayStore = .shared) {
        self.sessionID = sessionID
        self.messages = messages
        self.worldbooks = worldbooks
        binding = store.binding(sessionID: sessionID)
        resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: messages, store: store, migrateLegacyValues: false)
        variables = resolved?.variables ?? store.variableSnapshot(sessionID: sessionID, migrateLegacyValues: false)
        baseURL = Persistence.getImageDirectory()
        depths = messages.enumerated().reduce(into: [:]) { $0[$1.element.id] = messages.count - $1.offset - 1 }
        var hasher = Hasher()
        hasher.combine(binding)
        hasher.combine(resolved?.characters)
        hasher.combine(resolved?.persona)
        hasher.combine(worldbooks)
        contentIdentity = hasher.finalize()
        // 完成的消息内容、版本和索引变化会重建文档，流式占位的逐字变化不会反复重启脚本。
        historyIdentity = messages.filter { !$0.isReceivingStream }.hashValue
    }

    public func visualContent(_ message: ChatMessage, rules: [MessageRegexRule]) -> String {
        let content = ChatService.visualMessage(from: message, rules: rules).content
        guard let resolved, message.role == .user || message.role == .assistant else { return content }
        return RoleplayRuntime.visualContent(content, resolved: resolved,
                                            placement: message.role == .user ? .userInput : .aiOutput, depth: depths[message.id])
    }

    public func extraction(for message: ChatMessage, content: String) -> RoleplayHTMLExtraction? {
        guard binding?.htmlRenderingEnabled == true,
              message.role == .user || message.role == .assistant,
              !message.isReceivingStream else { return nil }
        if case .string(let html) = variables.value(scope: .message, path: RoleplayDisplayedMessageBridge.variableKey,
                                                    messageID: message.id, versionIndex: message.getCurrentVersionIndex()) {
            return RoleplayHTMLExtraction(remainingText: "", documents: [.init(id: 0, source: html)])
        }
        return RoleplayHTMLExtractor.extract(from: content)
    }

    public func documents(for message: ChatMessage, extraction: RoleplayHTMLExtraction) -> [RoleplayPreparedDocument] {
        extraction.documents.enumerated().map { index, document in
            makeDocument(source: document.source, title: String(format: NSLocalizedString("角色卡 HTML %d", comment: ""), index + 1),
                         message: message, documentID: document.id, character: resolved?.characters.first, script: nil)
        }
    }

    public func scriptDocuments() -> [RoleplayPreparedDocument] {
        guard binding?.helperScriptsEnabled == true, let resolved,
              let message = messages.last(where: { !$0.isReceivingStream }) else { return [] }
        // 流式占位消息不重启脚本；完整回复到达后才用新消息上下文重新加载。
        return resolved.characters.flatMap { character in
            character.helperScripts.filter(\.enabled).map { script in
                makeDocument(source: RoleplayHelperScriptDocument.source(script.content), title: script.name,
                             message: message, documentID: 0, character: character, script: script)
            }
        }
    }

    public func buttons() -> [RoleplayPreparedButton] {
        guard binding?.helperScriptsEnabled == true else { return [] }
        return (resolved?.characters ?? []).flatMap { character in
            character.helperScripts.filter(\.enabled).flatMap { script in
                script.buttons.filter(\.visible).map {
                    RoleplayPreparedButton(sessionID: sessionID, scriptID: script.id, buttonID: $0.id, name: $0.name)
                }
            }
        }
    }

    private func makeDocument(source: String, title: String, message: ChatMessage, documentID: Int,
                              character: RoleplayCharacter?, script: RoleplayHelperScript?) -> RoleplayPreparedDocument {
        let version = message.getCurrentVersionIndex()
        let initial: [String: JSONValue]
        if case .dictionary(let data) = script?.metadata["data"] { initial = data } else { initial = [:] }
        var merged = variables.mergedVariables(messageID: message.id, versionIndex: version)
        merged.merge(initial) { _, value in value }
        let persona = resolved?.persona
        let html = RoleplayHTMLDocumentFactory.makeDocument(
            source: source, variables: merged, userName: persona?.name ?? "User", characterName: character?.name ?? "Assistant",
            userAvatarPath: persona?.avatarFileName ?? "", characterAvatarPath: character?.avatarFileName ?? "",
            characterAssets: character?.assets ?? [], regexRules: character?.regexRules ?? [], chatMessages: messages,
            variableSnapshot: variables, messageID: message.id, messageVersionIndex: version, documentID: documentID,
            worldbooks: worldbooks, primaryWorldbookName: character?.embeddedWorldbookID.flatMap { id in worldbooks.first { $0.id == id }?.name },
            additionalWorldbookNames: binding?.additionalWorldbookIDs.compactMap { id in worldbooks.first { $0.id == id }?.name } ?? [],
            scriptID: script?.id, scriptName: script?.name ?? "", scriptInfo: script?.info ?? "", scriptButtons: script?.buttons ?? [],
            scriptInitialVariables: initial)
        let variableUpdate = RoleplayHTMLDocumentFactory.makeVariableUpdateScript(variableSnapshot: variables, messageID: message.id,
                                                                                messageVersionIndex: version, scriptID: script?.id, scriptInitialVariables: initial)
        return RoleplayPreparedDocument(
            id: "\(sessionID)|\(message.id)|\(version)|\(script?.id.uuidString ?? "html")|\(documentID)|\(contentIdentity)|\(historyIdentity)|\(source.hashValue)",
            sessionID: sessionID, messageID: message.id, versionIndex: version, scriptID: script?.id, title: title,
            source: source, html: html,
            variableUpdate: variableUpdate, variableRevision: variableUpdate.hashValue,
            baseURL: baseURL,
            bridgeSource: RoleplayBridgeSourceSnapshot(sessionID: sessionID, binding: binding, characters: resolved?.characters ?? [], messages: messages))
    }
}
