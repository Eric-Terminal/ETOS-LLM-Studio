// ============================================================================
// WatchRoleplayHTMLCardView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 聊天气泡中的酒馆助手 HTML 入口与后台脚本承载层。
// ============================================================================

import ETOSCore
import SwiftUI

struct WatchRoleplayHTMLCardView: View {
    let extraction: RoleplayHTMLExtraction
    let sessionID: UUID
    let messageID: UUID
    let versionIndex: Int
    let onOpenDocument: (WatchWebHTMLPageItem) -> Void

    @State private var documents: [WatchPreparedRoleplayHTMLDocument] = []
    @State private var variableRevision = 0

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(documents) { document in
                Button {
                    onOpenDocument(WatchWebHTMLPageItem(
                        title: document.title,
                        html: document.html,
                        sessionID: sessionID,
                        messageID: messageID,
                        versionIndex: versionIndex
                    ))
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(document.title)
                                .etFont(.caption2.weight(.semibold))
                            Text(NSLocalizedString("点按在手表上查看完整渲染。", comment: "Open complete roleplay HTML rendering on watch"))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .etFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: preparationKey) {
            let key = preparationKey
            let extraction = extraction
            let sessionID = sessionID
            let messageID = messageID
            let versionIndex = versionIndex
            let prepared = await Task.detached(priority: .utility) {
                let store = RoleplayStore.shared
                let snapshot = store.variableSnapshot(sessionID: sessionID)
                let chatMessages = Persistence.loadMessages(for: sessionID)
                let worldbooks = ChatService.shared.loadWorldbooks()
                let variables = snapshot.mergedVariables(messageID: messageID, versionIndex: versionIndex)
                let binding = store.binding(sessionID: sessionID)
                let character = binding?.characterIDs.first.flatMap(store.character(id:))
                let persona = binding?.personaID.flatMap(store.persona(id:))
                let primaryWorldbookName = character?.embeddedWorldbookID.flatMap { id in
                    worldbooks.first(where: { $0.id == id })?.name
                }
                let additionalWorldbookNames = binding?.additionalWorldbookIDs.compactMap { id in
                    worldbooks.first(where: { $0.id == id })?.name
                } ?? []
                let hasMultipleDocuments = extraction.documents.count > 1
                return extraction.documents.enumerated().map { offset, document in
                    WatchPreparedRoleplayHTMLDocument(
                        id: document.id,
                        title: hasMultipleDocuments
                            ? String(
                                format: NSLocalizedString("角色卡 HTML %d", comment: "Numbered roleplay HTML page title"),
                                offset + 1
                            )
                            : NSLocalizedString("角色卡 HTML", comment: "Roleplay HTML page title"),
                        html: RoleplayHTMLDocumentFactory.makeDocument(
                            source: document.source,
                            variables: variables,
                            userName: persona?.name ?? "User",
                            characterName: character?.name ?? "Assistant",
                            userAvatarPath: persona?.avatarFileName ?? "",
                            characterAvatarPath: character?.avatarFileName ?? "",
                            characterAssets: character?.assets ?? [],
                            regexRules: character?.regexRules ?? [],
                            chatMessages: chatMessages,
                            variableSnapshot: snapshot,
                            messageID: messageID,
                            messageVersionIndex: versionIndex,
                            documentID: document.id,
                            worldbooks: worldbooks,
                            primaryWorldbookName: primaryWorldbookName,
                            additionalWorldbookNames: additionalWorldbookNames
                        )
                    )
                }
            }.value
            guard !Task.isCancelled, key == preparationKey else { return }
            documents = prepared
        }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            variableRevision &+= 1
        }
    }

    private var preparationKey: String {
        "\(sessionID.uuidString)|\(messageID.uuidString)|\(versionIndex)|\(extraction.hashValue)|\(variableRevision)"
    }
}

struct WatchRoleplaySessionScriptHost: View {
    let sessionID: UUID?
    let messageID: UUID?
    let versionIndex: Int

    @State private var documents: [WatchPreparedRoleplayScriptDocument] = []
    @State private var revision = 0

    var body: some View {
        ZStack {
            ForEach(documents) { document in
                WatchRuntimeHTMLWebView(
                    html: document.html,
                    sessionID: document.sessionID,
                    messageID: document.messageID,
                    versionIndex: versionIndex,
                    scriptID: document.id
                )
                .frame(width: 1, height: 1)
                .opacity(0.001)
            }
        }
        .allowsHitTesting(false)
        .task(id: preparationKey) {
            guard let sessionID, let messageID else {
                documents = []
                return
            }
            documents = await Task.detached(priority: .utility) {
                let store = RoleplayStore.shared
                guard let binding = store.binding(sessionID: sessionID), binding.helperScriptsEnabled else { return [] }
                let characters = binding.characterIDs.compactMap(store.character(id:))
                let persona = binding.personaID.flatMap(store.persona(id:))
                let snapshot = store.variableSnapshot(sessionID: sessionID)
                let chatMessages = Persistence.loadMessages(for: sessionID)
                let worldbooks = ChatService.shared.loadWorldbooks()
                let additionalWorldbookNames = binding.additionalWorldbookIDs.compactMap { id in
                    worldbooks.first(where: { $0.id == id })?.name
                }
                let baseVariables = snapshot.mergedVariables(messageID: messageID, versionIndex: versionIndex)
                return characters.flatMap { character in
                    character.helperScripts.filter(\.enabled).map { script in
                        var variables = baseVariables
                        let scriptInitialVariables: [String: JSONValue]
                        if case .dictionary(let data) = script.metadata["data"] {
                            scriptInitialVariables = data
                            variables.merge(data) { _, new in new }
                        } else {
                            scriptInitialVariables = [:]
                        }
                        return WatchPreparedRoleplayScriptDocument(
                            id: script.id,
                            sessionID: sessionID,
                            messageID: messageID,
                            html: RoleplayHTMLDocumentFactory.makeDocument(
                                source: RoleplayHelperScriptDocument.source(script.content),
                                variables: variables,
                                userName: persona?.name ?? "User",
                                characterName: character.name,
                                userAvatarPath: persona?.avatarFileName ?? "",
                                characterAvatarPath: character.avatarFileName ?? "",
                                characterAssets: character.assets ?? [],
                                regexRules: character.regexRules,
                                chatMessages: chatMessages,
                                variableSnapshot: snapshot,
                                messageID: messageID,
                                messageVersionIndex: versionIndex,
                                worldbooks: worldbooks,
                                primaryWorldbookName: character.embeddedWorldbookID.flatMap { id in
                                    worldbooks.first(where: { $0.id == id })?.name
                                },
                                additionalWorldbookNames: additionalWorldbookNames,
                                scriptID: script.id,
                                scriptName: script.name,
                                scriptInfo: script.info,
                                scriptButtons: script.buttons,
                                scriptInitialVariables: scriptInitialVariables
                            )
                        )
                    }
                }
            }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { notification in
            if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind {
                revision &+= 1
            }
        }
    }

    private var preparationKey: String {
        "\(sessionID?.uuidString ?? "none")|\(messageID?.uuidString ?? "none")|\(versionIndex)|\(revision)"
    }

}

private struct WatchPreparedRoleplayHTMLDocument: Identifiable, Sendable {
    let id: Int
    let title: String
    let html: String
}

private struct WatchPreparedRoleplayScriptDocument: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let messageID: UUID
    let html: String
}
