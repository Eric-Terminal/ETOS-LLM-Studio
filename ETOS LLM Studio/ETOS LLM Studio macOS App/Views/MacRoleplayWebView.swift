import AppKit
import ETOSCore
import SwiftUI
import WebKit

struct MacRoleplayWebView: NSViewRepresentable {
    let document: RoleplayPreparedDocument
    let runtime: MacRoleplayRuntime
    let content: InlineHTMLContent?
    @Binding var height: CGFloat
    @Binding var error: String?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> MacRoleplayWebCoordinator {
        MacRoleplayWebCoordinator(document: document, runtime: runtime, height: $height, error: $error)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "etosRoleplay")
        controller.addUserScript(WKUserScript(source: RoleplayHTMLAdaptiveHeightRuntime.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        if let content {
            context.coordinator.inlineContent = content
            MacInlineHTMLWebViewSupport.connect(content, to: view)
        }
        runtime.register(context.coordinator, owner: context.coordinator.owner, documentID: document.id)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if let content {
            content.messageID = document.messageID
            content.versionIndex = document.versionIndex
            content.title = document.title
            content.code = document.source
            content.html = document.html
        }
        context.coordinator.update(document)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: MacRoleplayWebCoordinator) {
        coordinator.invalidate()
        coordinator.runtime?.unregister(coordinator.owner)
        if let content = coordinator.inlineContent { InlineHTMLContentRegistry.shared.remove(content) }
    }
}

@MainActor
final class MacRoleplayWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, MacRoleplayEndpoint {
    let owner = UUID()
    weak var runtime: MacRoleplayRuntime?
    weak var webView: WKWebView?
    var inlineContent: InlineHTMLContent?
    private var document: RoleplayPreparedDocument
    private var loaded = false
    private var ready = false
    private var invalidated = false
    private var variableRevision: Int?
    private var pendingVariableUpdate: String?
    private var pendingCalls: [String] = []
    private var delivery: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    @Binding private var height: CGFloat
    @Binding private var error: String?

    init(document: RoleplayPreparedDocument, runtime: MacRoleplayRuntime, height: Binding<CGFloat>, error: Binding<String?>) {
        self.document = document
        self.runtime = runtime
        _height = height
        _error = error
        super.init()
        for name in [RoleplayScriptButtonNotification.requested, RoleplayBridgeNotification.completedRequest,
                     RoleplayMacroExpansionNotification.requested, RoleplayPromptMutationNotification.requested, RoleplayEventBridge.didEmitNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.receive(notification) }
            })
        }
    }

    private var active: Bool { !invalidated && runtime?.isActive(owner: owner, documentID: document.id) == true }

    func update(_ document: RoleplayPreparedDocument) {
        guard active else { return }
        self.document = document
        if !loaded {
            loaded = true
            variableRevision = document.variableRevision
            webView?.loadHTMLString(document.html, baseURL: document.baseURL)
        } else if variableRevision != document.variableRevision {
            variableRevision = document.variableRevision
            if ready { webView?.evaluateJavaScript(document.variableUpdate) }
            else { pendingVariableUpdate = document.variableUpdate }
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        delivery?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        pendingCalls = []
        pendingVariableUpdate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "etosRoleplay")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        // 已加载页面的定时器也必须停止，不能仅取消尚未完成的资源下载。
        webView?.loadHTMLString("", baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard active, message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
        if payload["action"] as? String == "height" {
            guard document.scriptID == nil else { return }
            guard let value = (payload["value"] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, active else { return }
                height = CGFloat(value)
            }
        } else { runtime?.handle(payload, owner: owner, document: document) }
    }

    private func receive(_ notification: Notification) {
        guard active, let info = notification.userInfo,
              info[RoleplayBridgeNotification.sessionIDKey] as? UUID == document.sessionID else { return }
        let call: MacRoleplayJavaScriptCall
        switch notification.name {
        case RoleplayScriptButtonNotification.requested:
            guard let scriptID = document.scriptID, info[RoleplayScriptButtonNotification.scriptIDKey] as? UUID == scriptID,
                  let name = info[RoleplayScriptButtonNotification.buttonNameKey] as? String else { return }
            call = .init(function: "__etosEmitScriptButton", arguments: [name])
        case RoleplayBridgeNotification.completedRequest:
            guard let id = info[RoleplayBridgeNotification.requestIDKey] as? String else { return }
            call = .init(function: "__etosResolveRequest", arguments: [id, info[RoleplayBridgeNotification.resultKey] ?? NSNull(), info[RoleplayBridgeNotification.errorKey] ?? NSNull()])
        case RoleplayMacroExpansionNotification.requested:
            guard let scriptID = document.scriptID, info[RoleplayMacroExpansionNotification.scriptIDKey] as? UUID == scriptID,
                  let id = info[RoleplayMacroExpansionNotification.requestIDKey] as? String,
                  let text = info[RoleplayMacroExpansionNotification.textKey] as? String else { return }
            call = .init(function: "__etosExpandMacros", arguments: [id, text])
        case RoleplayPromptMutationNotification.requested:
            guard let scriptID = document.scriptID, info[RoleplayPromptMutationNotification.scriptIDKey] as? UUID == scriptID,
                  let id = info[RoleplayPromptMutationNotification.requestIDKey] as? String,
                  let prompt = info[RoleplayPromptMutationNotification.promptKey] as? [[String: String]] else { return }
            call = .init(function: "__etosMutatePrompt", arguments: [id, prompt])
        case RoleplayEventBridge.didEmitNotification:
            guard let name = info[RoleplayBridgeNotification.eventNameKey] as? String,
                  let args = info[RoleplayEventBridge.argumentsKey] as? [Any], let source = info[RoleplayEventBridge.sourceKey] as? String else { return }
            call = .init(function: "__etosReceiveEvent", arguments: [name, args, source])
        default: return
        }
        let previous = delivery
        delivery = Task { [weak self] in
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            let javaScript = await Task.detached(priority: .utility) { call.source() }.value
            guard let self, !Task.isCancelled, active, let javaScript else { return }
            if ready { webView?.evaluateJavaScript(javaScript) }
            else { pendingCalls.append(javaScript) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active else { return }
        ready = true
        if let pendingVariableUpdate { webView.evaluateJavaScript(pendingVariableUpdate); self.pendingVariableUpdate = nil }
        for call in pendingCalls { webView.evaluateJavaScript(call) }
        pendingCalls = []
        webView.evaluateJavaScript("window.__etosReportHeight?.();")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if active { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if active { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard active, let url = action.request.url else { decisionHandler(.cancel); return }
        switch MacRoleplayNavigationPolicy.decision(url: url, isLink: action.navigationType == .linkActivated,
                                                   isMainFrame: action.targetFrame?.isMainFrame, baseURL: document.baseURL) {
        case .allow: decisionHandler(.allow)
        case .cancel: decisionHandler(.cancel)
        case .external: NSWorkspace.shared.open(url); decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if active, let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        return nil
    }
}

enum MacRoleplayNavigationPolicy {
    enum Decision: Equatable { case allow, external, cancel }
    static func decision(url: URL, isLink: Bool, isMainFrame: Bool?, baseURL: URL) -> Decision {
        let webURL = url.scheme == "https" || url.scheme == "http"
        if isLink && webURL { return .external }
        var source = URLComponents(url: url, resolvingAgainstBaseURL: true)
        source?.fragment = nil
        let localDocument = url.absoluteString == "about:blank" || (url.isFileURL && source?.url?.standardizedFileURL == baseURL.standardizedFileURL)
        if localDocument { return .allow }
        if isMainFrame == false && (webURL || url.absoluteString == "about:srcdoc" || url.scheme == "blob") { return .allow }
        return .cancel
    }
}

/// 通知仅携带 JSON 值，转发期间保持只读；编码在后台进行。
struct MacRoleplayJavaScriptCall: @unchecked Sendable {
    let function: String
    let arguments: [Any]
    func source() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments), let text = String(data: data, encoding: .utf8) else { return nil }
        return "window.\(function)?.(...\(text));"
    }
}
