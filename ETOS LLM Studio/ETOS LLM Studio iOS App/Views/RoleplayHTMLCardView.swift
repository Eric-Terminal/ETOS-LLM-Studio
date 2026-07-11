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
                let variables = snapshot.mergedVariables(messageID: messageID, versionIndex: versionIndex)
                let binding = store.binding(sessionID: sessionID)
                let character = binding?.characterIDs.first.flatMap(store.character(id:))
                let persona = binding?.personaID.flatMap(store.persona(id:))
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
                            chatMessages: chatMessages,
                            variableSnapshot: snapshot
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
                let baseVariables = snapshot.mergedVariables(messageID: messageID, versionIndex: versionIndex)
                return characters.flatMap { character in
                    character.helperScripts.filter(\.enabled).map { script in
                        var variables = baseVariables
                        if case .dictionary(let data) = script.metadata["data"] {
                            variables.merge(data) { _, new in new }
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
                                chatMessages: chatMessages,
                                variableSnapshot: snapshot
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
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            messageID: messageID,
            versionIndex: versionIndex,
            height: $height
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "etosRoleplay")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
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
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let sessionID: UUID
        let messageID: UUID
        let versionIndex: Int
        @Binding var height: CGFloat
        var loadedHTML: String?

        init(
            sessionID: UUID,
            messageID: UUID,
            versionIndex: Int,
            height: Binding<CGFloat>
        ) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.versionIndex = versionIndex
            self._height = height
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
