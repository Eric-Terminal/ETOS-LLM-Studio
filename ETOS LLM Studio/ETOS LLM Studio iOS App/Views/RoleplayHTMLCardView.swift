// ============================================================================
// RoleplayHTMLCardView.swift
// ============================================================================
// ETOS LLM Studio
//
// 在聊天气泡内自动承载酒馆助手风格 HTML，并转发变量与消息动作。
// ============================================================================

import ETOSCore
import SwiftUI
import WebKit

struct RoleplayHTMLCardView: View {
    let extraction: RoleplayHTMLExtraction
    let sessionID: UUID
    let messageID: UUID
    let versionIndex: Int

    @State private var documents: [PreparedRoleplayHTMLDocument] = []
    @State private var heights: [Int: CGFloat] = [:]
    @State private var variableRevision = 0

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(documents) { document in
                RoleplayHTMLWebView(
                    html: document.html,
                    sessionID: sessionID,
                    messageID: messageID,
                    versionIndex: versionIndex,
                    scriptID: nil,
                    height: Binding(
                        get: { heights[document.id] ?? 180 },
                        set: { heights[document.id] = max(1, $0) }
                    )
                )
                .frame(height: heights[document.id] ?? 180)
            }
        }
        .task(id: preparationKey) {
            let extraction = extraction
            let sessionID = sessionID
            let messageID = messageID
            let versionIndex = versionIndex
            documents = await Task.detached(priority: .utility) {
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
                return extraction.documents.map { document in
                    PreparedRoleplayHTMLDocument(
                        id: document.id,
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
        }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            variableRevision &+= 1
        }
    }

    private var preparationKey: String {
        "\(sessionID.uuidString)|\(messageID.uuidString)|\(versionIndex)|\(extraction.hashValue)|\(variableRevision)"
    }
}

struct RoleplaySessionScriptHost: View {
    let sessionID: UUID?
    let messageID: UUID?
    let versionIndex: Int

    @State private var documents: [PreparedRoleplayScriptDocument] = []
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var revision = 0

    var body: some View {
        ZStack {
            ForEach(documents) { document in
                RoleplayHTMLWebView(
                    html: document.html,
                    sessionID: document.sessionID,
                    messageID: document.messageID,
                    versionIndex: versionIndex,
                    scriptID: document.id,
                    height: Binding(
                        get: { heights[document.id] ?? 1 },
                        set: { heights[document.id] = $0 }
                    )
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
                        return PreparedRoleplayScriptDocument(
                            id: script.id,
                            sessionID: sessionID,
                            messageID: messageID,
                            html: RoleplayHTMLDocumentFactory.makeDocument(
                                source: Self.scriptSource(script.content),
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

    private static func scriptSource(_ content: String) -> String {
        let encoded = Data(content.utf8).base64EncodedString()
        return """
<script>
(async function () {
  const binary = atob('\(encoded)');
  const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
  const source = new TextDecoder().decode(bytes);
  (0, eval)(source);
})();
</script>
"""
    }
}

struct RoleplayScriptButtonBar: View {
    let sessionID: UUID?

    @State private var actions: [RoleplayScriptButtonAction] = []
    @State private var revision = 0

    var body: some View {
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(actions) { action in
                        Button(action.name) {
                            NotificationCenter.default.post(
                                name: RoleplayScriptButtonNotification.requested,
                                object: nil,
                                userInfo: [
                                    RoleplayScriptButtonNotification.sessionIDKey: action.sessionID,
                                    RoleplayScriptButtonNotification.scriptIDKey: action.scriptID,
                                    RoleplayScriptButtonNotification.buttonNameKey: action.name
                                ]
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: preparationKey) { await loadActions() }
            .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { notification in
                if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind {
                    revision &+= 1
                }
            }
    }

    private var preparationKey: String {
        "\(sessionID?.uuidString ?? "none")|\(revision)"
    }

    @MainActor
    private func loadActions() async {
        guard let sessionID else {
            actions = []
            return
        }
        actions = await Task.detached(priority: .utility) {
            let store = RoleplayStore.shared
            guard let binding = store.binding(sessionID: sessionID), binding.helperScriptsEnabled else { return [] }
            return binding.characterIDs.compactMap(store.character(id:)).flatMap { character in
                character.helperScripts.filter(\.enabled).flatMap { script in
                    script.buttons.filter(\.visible).map {
                        RoleplayScriptButtonAction(
                            sessionID: sessionID,
                            scriptID: script.id,
                            buttonID: $0.id,
                            name: $0.name
                        )
                    }
                }
            }
        }.value
    }
}

private struct RoleplayScriptButtonAction: Identifiable, Sendable {
    var id: String { "\(scriptID.uuidString):\(buttonID.uuidString)" }
    let sessionID: UUID
    let scriptID: UUID
    let buttonID: UUID
    let name: String
}

private struct PreparedRoleplayHTMLDocument: Identifiable, Sendable {
    let id: Int
    let html: String
}

private struct PreparedRoleplayScriptDocument: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let messageID: UUID
    let html: String
}

struct RoleplayHTMLWebView: UIViewRepresentable {
    let html: String
    let sessionID: UUID
    let messageID: UUID
    let versionIndex: Int
    let scriptID: UUID?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            messageID: messageID,
            versionIndex: versionIndex,
            scriptID: scriptID,
            height: $height
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "etosRoleplay")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: Persistence.getImageDirectory())
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "etosRoleplay")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let sessionID: UUID
        let messageID: UUID
        let versionIndex: Int
        let scriptID: UUID?
        @Binding var height: CGFloat
        var loadedHTML: String?
        weak var webView: WKWebView?
        private var buttonObserver: NSObjectProtocol? = nil
        private var requestObserver: NSObjectProtocol? = nil
        private var macroObserver: NSObjectProtocol? = nil
        private var eventObserver: NSObjectProtocol? = nil

        init(
            sessionID: UUID,
            messageID: UUID,
            versionIndex: Int,
            scriptID: UUID?,
            height: Binding<CGFloat>
        ) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.versionIndex = versionIndex
            self.scriptID = scriptID
            self._height = height
            super.init()
            buttonObserver = NotificationCenter.default.addObserver(
                forName: RoleplayScriptButtonNotification.requested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleScriptButton(notification)
            }
            requestObserver = NotificationCenter.default.addObserver(
                forName: RoleplayBridgeNotification.completedRequest,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleCompletedRequest(notification)
            }
            macroObserver = NotificationCenter.default.addObserver(
                forName: RoleplayMacroExpansionNotification.requested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleMacroExpansion(notification)
            }
            eventObserver = NotificationCenter.default.addObserver(
                forName: RoleplayEventBridge.didEmitNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleRoleplayEvent(notification)
            }
        }

        deinit {
            if let buttonObserver { NotificationCenter.default.removeObserver(buttonObserver) }
            if let requestObserver { NotificationCenter.default.removeObserver(requestObserver) }
            if let macroObserver { NotificationCenter.default.removeObserver(macroObserver) }
            if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let action = payload["action"] as? String else { return }
            if action == "height" {
                let value = (payload["value"] as? NSNumber)?.doubleValue ?? 1
                DispatchQueue.main.async { self.height = max(1, value) }
                return
            }
            RoleplayBridgeDispatcher.handle(
                payload,
                sessionID: sessionID,
                messageID: messageID,
                versionIndex: versionIndex
            )
        }

        private func handleScriptButton(_ notification: Notification) {
            guard let scriptID,
                  notification.userInfo?[RoleplayScriptButtonNotification.sessionIDKey] as? UUID == sessionID,
                  notification.userInfo?[RoleplayScriptButtonNotification.scriptIDKey] as? UUID == scriptID,
                  let name = notification.userInfo?[RoleplayScriptButtonNotification.buttonNameKey] as? String,
                  let data = try? JSONEncoder().encode(name),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__etosEmitScriptButton?.(\(literal));")
        }

        private func handleCompletedRequest(_ notification: Notification) {
            guard notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID == sessionID,
                  let requestID = notification.userInfo?[RoleplayBridgeNotification.requestIDKey] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: [
                    requestID,
                    notification.userInfo?[RoleplayBridgeNotification.resultKey] ?? NSNull(),
                    notification.userInfo?[RoleplayBridgeNotification.errorKey] ?? NSNull()
                  ]),
                  let arguments = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__etosResolveRequest?.(...\(arguments));")
        }

        private func handleMacroExpansion(_ notification: Notification) {
            guard let scriptID,
                  notification.userInfo?[RoleplayMacroExpansionNotification.sessionIDKey] as? UUID == sessionID,
                  notification.userInfo?[RoleplayMacroExpansionNotification.scriptIDKey] as? UUID == scriptID,
                  let requestID = notification.userInfo?[RoleplayMacroExpansionNotification.requestIDKey] as? String,
                  let text = notification.userInfo?[RoleplayMacroExpansionNotification.textKey] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: [requestID, text]),
                  let arguments = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__etosExpandMacros?.(...\(arguments));")
        }

        private func handleRoleplayEvent(_ notification: Notification) {
            guard notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID == sessionID,
                  let name = notification.userInfo?[RoleplayBridgeNotification.eventNameKey] as? String,
                  let arguments = notification.userInfo?[RoleplayEventBridge.argumentsKey] as? [Any],
                  let source = notification.userInfo?[RoleplayEventBridge.sourceKey] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: [name, arguments, source]),
                  let payload = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__etosReceiveEvent?.(...\(payload));")
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
