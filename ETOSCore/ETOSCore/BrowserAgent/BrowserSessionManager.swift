// iOS Browser Agent 使用公开 WKWebView。每个聊天会话持有独立标签页集合，
// Agent 和用户接管共享同一个 WKWebView，但不同会话不会共享标签页引用。

import Foundation
import Combine
#if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
import WebKit
import UIKit
@MainActor
public final class BrowserSessionManager: NSObject, ObservableObject {
    public static let shared = BrowserSessionManager()

    private final class Tab {
        let id: UUID
        var webView: WKWebView
        var lastNavigationError: Error?
        /// nil 表示用户手动浏览；非 nil 时只允许本次 Agent 已获批的跨域目标。
        var allowedAgentNavigationHosts: Set<String>?
        var domRevision = 0
        var userAgentProfile: BrowserAgentUserAgentProfile?
        var viewportWidth: Int?
        var viewportHeight: Int?
        var lastActivityAt = Date()
        var wasRestoredByReload = false
        var recoverableURL: URL?
        var recoverableTitle: String?
        var needsReload = false

        init(id: UUID = UUID(), webView: WKWebView) {
            self.id = id
            self.webView = webView
        }
    }

    @MainActor
    private final class Session {
        var tabs: [UUID: Tab] = [:]
        var order: [UUID] = []
        var selectedTabID: UUID?
        var isUserControlling = false
        var controlState = BrowserAgentControlState.idle
        let isolatedDataStore = WKWebsiteDataStore.nonPersistent()
    }

    private var sessions: [UUID: Session] = [:]
    private var webViewLocations: [ObjectIdentifier: (sessionID: UUID, tabID: UUID)] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []

    public override init() {
        super.init()
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reclaimBackgroundTabs(olderThan: nil) }
        })
    }

    public func capabilities() -> BrowserAgentCapabilities {
        BrowserAgentCapabilities(
            platform: "iOS",
            isExperimental: false,
            supportsNavigation: true,
            supportsSnapshot: true,
            supportsClick: true,
            supportsTyping: true,
            supportsScrolling: true,
            supportsJavaScript: true,
            supportsScreenshot: true,
            supportsDownload: true,
            supportsUserTakeover: true,
            supportsIPhoneDelegation: false,
            notes: [
                NSLocalizedString("标签页按聊天会话隔离。", comment: "Browser Agent iOS capability note"),
                NSLocalizedString("用户接管和 Agent 操作共享同一个网页状态。", comment: "Browser Agent takeover capability note")
            ]
        )
    }

    public func tabs(sessionID: UUID) -> [BrowserAgentTabSummary] {
        guard let session = sessions[sessionID] else { return [] }
        return session.order.compactMap { id in
            guard let tab = session.tabs[id] else { return nil }
            return summary(for: tab)
        }
    }

    public func isUserControlling(sessionID: UUID) -> Bool {
        sessions[sessionID]?.isUserControlling == true
    }

    public func setUserControlling(_ isControlling: Bool, sessionID: UUID) {
        if isControlling {
            beginUserTakeover(sessionID: sessionID)
        } else {
            Task { @MainActor [weak self] in
                await self?.releaseUserTakeover(sessionID: sessionID)
            }
        }
    }

    public func controlState(sessionID: UUID) -> BrowserAgentControlState {
        sessions[sessionID]?.controlState ?? .idle
    }

    public func beginUserTakeover(sessionID: UUID) {
        let session = session(for: sessionID)
        session.isUserControlling = true
        session.controlState = BrowserAgentControlState(
            controller: .user,
            status: .running,
            tabID: session.selectedTabID,
            domain: selectedWebView(sessionID: sessionID)?.url?.host,
            detail: NSLocalizedString("用户正在控制浏览器", comment: "Browser Agent user control state"),
            startedAt: Date()
        )
        Task { await BrowserAgentToolExecutor.shared.cancel(sessionID: sessionID) }
        objectWillChange.send()
    }

    public func beginAgentAction(sessionID: UUID, tabID: UUID?, action: BrowserAgentAction) {
        reclaimBackgroundTabs(olderThan: Date().addingTimeInterval(-30 * 60))
        let session = session(for: sessionID)
        let resolvedTabID = tabID ?? session.selectedTabID
        let domain = resolvedTabID.flatMap { session.tabs[$0]?.webView.url?.host }
        session.controlState = BrowserAgentControlState(
            controller: .agent,
            status: .running,
            action: action,
            tabID: resolvedTabID,
            domain: domain,
            detail: action.rawValue,
            startedAt: Date()
        )
        objectWillChange.send()
    }

    public func finishAgentAction(
        sessionID: UUID,
        action: BrowserAgentAction,
        status: BrowserAgentControlStatus,
        detail: String?
    ) {
        guard let session = sessions[sessionID], session.controlState.controller == .agent else { return }
        session.controlState = BrowserAgentControlState(
            controller: .idle,
            status: status,
            action: action,
            tabID: session.selectedTabID,
            domain: selectedWebView(sessionID: sessionID)?.url?.host,
            detail: detail
        )
        objectWillChange.send()
    }

    @discardableResult
    public func openTab(
        sessionID: UUID,
        url: URL? = nil,
        dataProfile: BrowserAgentDataProfile? = nil,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        reclaimBackgroundTabs(olderThan: Date().addingTimeInterval(-30 * 60))
        let session = session(for: sessionID)
        let configuration = WKWebViewConfiguration()
        let resolvedProfile = dataProfile ?? Persistence.browserAgentDataProfile(sessionID: sessionID)
        // 隔离 profile 在同一聊天的标签页之间共享 Cookie，但不会跨会话或跨进程保留。
        configuration.websiteDataStore = resolvedProfile == .persistentShared
            ? .default()
            : session.isolatedDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        webView.allowsBackForwardNavigationGestures = true
        let tab = Tab(webView: webView)
        webView.navigationDelegate = self
        session.tabs[tab.id] = tab
        session.order.append(tab.id)
        session.selectedTabID = tab.id
        webViewLocations[ObjectIdentifier(webView)] = (sessionID, tab.id)
        objectWillChange.send()

        if let url {
            try await navigate(
                sessionID: sessionID,
                tabID: tab.id,
                url: url,
                allowedAgentNavigationHosts: allowedAgentNavigationHosts
            )
        }
        return summary(for: tab)
    }

    public func closeTab(sessionID: UUID, tabID: UUID?) throws -> BrowserAgentTabSummary {
        let session = try existingSession(sessionID)
        let resolvedID = try resolvedTabID(tabID, session: session)
        guard let tab = session.tabs.removeValue(forKey: resolvedID) else {
            throw BrowserAgentError.tabNotFound
        }
        webViewLocations.removeValue(forKey: ObjectIdentifier(tab.webView))
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        session.order.removeAll { $0 == resolvedID }
        if session.selectedTabID == resolvedID {
            session.selectedTabID = session.order.last
        }
        objectWillChange.send()
        return summary(for: tab)
    }

    @discardableResult
    public func navigate(
        sessionID: UUID,
        tabID: UUID?,
        url: URL,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("浏览器仅接受 http 或 https URL。", comment: "Browser Agent invalid URL scheme")
            )
        }
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        tab.needsReload = false
        tab.recoverableURL = nil
        tab.recoverableTitle = nil
        beginAgentNavigationGuard(tab, allowedHosts: allowedAgentNavigationHosts)
        defer { tab.allowedAgentNavigationHosts = nil }
        tab.lastNavigationError = nil
        tab.webView.load(URLRequest(url: url))
        try await waitForNavigation(tab)
        objectWillChange.send()
        return summary(for: tab)
    }

    public func snapshot(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentSnapshot {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        let value = try await evaluate(BrowserDOMAutomation.snapshot(), in: tab.webView)
        guard let object = value as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("页面快照没有返回可解析的数据。", comment: "Browser Agent invalid snapshot")
            )
        }
        let snapshot = try BrowserDOMResultParser.snapshot(object)
        tab.domRevision = snapshot.domRevision
        tab.lastActivityAt = Date()
        return snapshot
    }

    public func click(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        beginAgentNavigationGuard(tab, allowedHosts: allowedAgentNavigationHosts)
        defer { tab.allowedAgentNavigationHosts = nil }
        let value = try await evaluate(
            BrowserDOMAutomation.click(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        try await waitForTriggeredNavigation(tab)
    }

    public func type(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        text: String,
        submit: Bool,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        beginAgentNavigationGuard(tab, allowedHosts: allowedAgentNavigationHosts)
        defer { tab.allowedAgentNavigationHosts = nil }
        let value = try await evaluate(
            BrowserDOMAutomation.type(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision,
                text: text,
                submit: submit
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        if submit { try await waitForTriggeredNavigation(tab) }
    }

    public func scroll(
        sessionID: UUID,
        tabID: UUID?,
        deltaX: Double,
        deltaY: Double,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        try await performGuardedInteraction(
            sessionID: sessionID,
            tabID: tabID,
            script: "window.scrollBy(\(deltaX), \(deltaY)); true",
            allowedAgentNavigationHosts: allowedAgentNavigationHosts
        )
    }

    public func evaluateJavaScript(
        sessionID: UUID,
        tabID: UUID?,
        script: String,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> JSONValue {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        beginAgentNavigationGuard(tab, allowedHosts: allowedAgentNavigationHosts)
        defer { tab.allowedAgentNavigationHosts = nil }
        let value = try await evaluate(script, in: tab.webView)
        try await waitForTriggeredNavigation(tab)
        return browserAgentJSONValue(from: value)
    }

    public func download(
        sessionID: UUID,
        tabID: UUID?,
        url: URL,
        filename: String?,
        destinationDirectory: URL? = nil
    ) async throws -> BrowserAgentDownloadResult {
        try await saveResource(
            sessionID: sessionID,
            url: url,
            filename: filename,
            destinationDirectory: destinationDirectory,
            cookies: []
        )
    }

    public func fetch(
        sessionID: UUID,
        tabID: UUID?,
        url: URL,
        filename: String?,
        destinationDirectory: URL? = nil
    ) async throws -> BrowserAgentDownloadResult {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let cookies = await tab.webView.configuration.websiteDataStore.httpCookieStore.browserAgentAllCookies()
            .filter { Self.cookieApplies($0, to: url) }
        return try await saveResource(
            sessionID: sessionID,
            url: url,
            filename: filename,
            destinationDirectory: destinationDirectory,
            cookies: cookies
        )
    }

    private func saveResource(
        sessionID: UUID,
        url: URL,
        filename: String?,
        destinationDirectory: URL?,
        cookies: [HTTPCookie]
    ) async throws -> BrowserAgentDownloadResult {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("下载仅接受 http 或 https URL。", comment: "Browser Agent invalid download URL")
            )
        }
        var request = URLRequest(url: url)
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in fields {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let sourceHost = url.host?.lowercased()
        let redirectDelegate = BrowserDownloadRedirectDelegate(
            allowedHosts: sourceHost.map { [$0] } ?? []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let networkSession = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { networkSession.finishTasksAndInvalidate() }
        let (temporaryURL, response) = try await networkSession.download(for: request)
        if let blockedHost = redirectDelegate.blockedHost {
            throw BrowserAgentError.crossDomainApprovalRequired(
                sourceHost: sourceHost,
                targetHost: blockedHost
            )
        }
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw BrowserAgentError.navigationFailed(
                NSLocalizedString("下载服务器返回无效状态。", comment: "Browser Agent invalid download status")
            )
        }
        let proposed = filename ?? response.suggestedFilename ?? url.lastPathComponent
        let destination = try await Task.detached(priority: .utility) {
            try BrowserAgentStorage.destinationURL(
                sessionID: sessionID,
                directoryName: "Downloads",
                proposedFilename: proposed.isEmpty ? "download" : proposed,
                destinationDirectory: destinationDirectory
            )
        }.value
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }.value
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return BrowserAgentDownloadResult(
            uri: try BrowserAgentStorage.appURI(for: destination),
            finalURL: response.url?.absoluteString ?? url.absoluteString,
            mimeType: response.mimeType,
            filename: destination.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }

    public func webView(sessionID: UUID, tabID: UUID?) throws -> WKWebView {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        startReloadIfNeeded(tab)
        return tab.webView
    }

    func preparedWebView(sessionID: UUID, tabID: UUID?) async throws -> WKWebView {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        tab.lastActivityAt = Date()
        return tab.webView
    }

    func recordOverrides(
        sessionID: UUID,
        tabID: UUID?,
        userAgentProfile: BrowserAgentUserAgentProfile? = nil,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        resetViewport: Bool = false
    ) throws -> BrowserAgentTabSummary {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        if let userAgentProfile { tab.userAgentProfile = userAgentProfile == .reset ? nil : userAgentProfile }
        if resetViewport {
            tab.viewportWidth = nil
            tab.viewportHeight = nil
        } else if let viewportWidth, let viewportHeight {
            tab.viewportWidth = viewportWidth
            tab.viewportHeight = viewportHeight
        }
        tab.lastActivityAt = Date()
        return summary(for: tab)
    }

    public func selectedTabID(sessionID: UUID) -> UUID? {
        sessions[sessionID]?.selectedTabID
    }

    public func selectedWebView(sessionID: UUID) -> WKWebView? {
        guard let session = sessions[sessionID],
              let selectedTabID = session.selectedTabID else { return nil }
        guard let tab = session.tabs[selectedTabID] else { return nil }
        startReloadIfNeeded(tab)
        return tab.webView
    }

    public func currentURL(sessionID: UUID, tabID: UUID?) throws -> URL? {
        try resolvedTab(sessionID: sessionID, tabID: tabID).webView.url
    }

    public func interactionDestination(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        submittingForm: Bool
    ) async throws -> URL? {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        let value = try await evaluate(
            BrowserDOMAutomation.interactionDestination(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision,
                submittingForm: submittingForm
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        guard let value = value as? String else { return nil }
        return URL(string: value)
    }

    func performGuardedInteraction(
        sessionID: UUID,
        tabID: UUID?,
        script: String,
        allowedAgentNavigationHosts: Set<String>?
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        try await restoreIfNeeded(tab)
        beginAgentNavigationGuard(tab, allowedHosts: allowedAgentNavigationHosts)
        defer { tab.allowedAgentNavigationHosts = nil }
        let value = try await evaluate(script, in: tab.webView)
        try BrowserDOMResultParser.interactionError(value)
        try await waitForTriggeredNavigation(tab)
    }

    public func selectTab(sessionID: UUID, tabID: UUID) throws {
        let session = try existingSession(sessionID)
        guard session.tabs[tabID] != nil else { throw BrowserAgentError.tabNotFound }
        session.selectedTabID = tabID
        if let tab = session.tabs[tabID] { startReloadIfNeeded(tab) }
        objectWillChange.send()
    }

    private func session(for sessionID: UUID) -> Session {
        if let existing = sessions[sessionID] { return existing }
        let created = Session()
        sessions[sessionID] = created
        return created
    }

    private func existingSession(_ sessionID: UUID) throws -> Session {
        guard let session = sessions[sessionID] else { throw BrowserAgentError.tabNotFound }
        return session
    }

    private func resolvedTab(sessionID: UUID, tabID: UUID?) throws -> Tab {
        let session = try existingSession(sessionID)
        let resolvedID = try resolvedTabID(tabID, session: session)
        guard let tab = session.tabs[resolvedID] else { throw BrowserAgentError.tabNotFound }
        session.selectedTabID = resolvedID
        tab.lastActivityAt = Date()
        return tab
    }

    private func resolvedTabID(_ tabID: UUID?, session: Session) throws -> UUID {
        guard let resolvedID = tabID ?? session.selectedTabID else {
            throw BrowserAgentError.tabNotFound
        }
        return resolvedID
    }

    private func summary(for tab: Tab) -> BrowserAgentTabSummary {
        BrowserAgentTabSummary(
            id: tab.id,
            title: tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).browserNonEmptyValue
                ?? tab.recoverableTitle?.browserNonEmptyValue
                ?? NSLocalizedString("新标签页", comment: "Browser Agent untitled tab"),
            url: tab.webView.url?.absoluteString ?? tab.recoverableURL?.absoluteString,
            isLoading: tab.webView.isLoading,
            domRevision: tab.domRevision,
            userAgentProfile: tab.userAgentProfile,
            viewportWidth: tab.viewportWidth,
            viewportHeight: tab.viewportHeight,
            lastActivityAt: tab.lastActivityAt,
            wasRestoredByReload: tab.wasRestoredByReload
        )
    }

    private func releaseUserTakeover(sessionID: UUID) async {
        guard let session = sessions[sessionID], session.isUserControlling else { return }
        session.controlState = BrowserAgentControlState(
            controller: .returningToAgent,
            status: .waiting,
            tabID: session.selectedTabID,
            domain: selectedWebView(sessionID: sessionID)?.url?.host,
            detail: NSLocalizedString("正在刷新页面快照", comment: "Browser Agent refreshing after takeover")
        )
        objectWillChange.send()
        if session.selectedTabID != nil {
            _ = try? await snapshot(sessionID: sessionID, tabID: session.selectedTabID)
        }
        session.isUserControlling = false
        session.controlState = .idle
        objectWillChange.send()
    }

    private func reclaimBackgroundTabs(olderThan cutoff: Date?) {
        for (sessionID, session) in sessions where !session.isUserControlling {
            for tabID in session.order where tabID != session.selectedTabID {
                guard let tab = session.tabs[tabID], !tab.webView.isLoading, let url = tab.webView.url else { continue }
                if let cutoff, tab.lastActivityAt >= cutoff { continue }
                let oldWebView = tab.webView
                tab.recoverableURL = url
                tab.recoverableTitle = oldWebView.title
                tab.needsReload = true
                oldWebView.stopLoading()
                oldWebView.navigationDelegate = nil
                webViewLocations.removeValue(forKey: ObjectIdentifier(oldWebView))
                let configuration = oldWebView.configuration.copy() as! WKWebViewConfiguration
                let replacement = WKWebView(frame: oldWebView.frame, configuration: configuration)
                replacement.navigationDelegate = self
                replacement.allowsBackForwardNavigationGestures = true
                tab.webView = replacement
                webViewLocations[ObjectIdentifier(replacement)] = (sessionID, tabID)
            }
        }
        objectWillChange.send()
    }

    private func startReloadIfNeeded(_ tab: Tab) {
        guard tab.needsReload, let url = tab.recoverableURL else { return }
        tab.needsReload = false
        tab.wasRestoredByReload = true
        tab.lastNavigationError = nil
        tab.webView.load(URLRequest(url: url))
    }

    private func restoreIfNeeded(_ tab: Tab) async throws {
        guard tab.needsReload else { return }
        startReloadIfNeeded(tab)
        try await waitForNavigation(tab)
    }

    private func waitForNavigation(_ tab: Tab) async throws {
        let deadline = Date().addingTimeInterval(60)
        while tab.webView.isLoading {
            try Task.checkCancellation()
            if Date() >= deadline {
                tab.webView.stopLoading()
                throw BrowserAgentError.navigationFailed(
                    NSLocalizedString("等待网页加载超时。", comment: "Browser Agent navigation timeout")
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let error = tab.lastNavigationError {
            throw BrowserAgentError.navigationFailed(error.localizedDescription)
        }
    }

    private func beginAgentNavigationGuard(_ tab: Tab, allowedHosts: Set<String>?) {
        tab.lastNavigationError = nil
        tab.allowedAgentNavigationHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
    }

    nonisolated static func cookieApplies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expiresDate = cookie.expiresDate, expiresDate <= Date() { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return requestPath.count == cookiePath.count
            || cookiePath.hasSuffix("/")
            || requestPath.dropFirst(cookiePath.count).first == "/"
    }

    private func waitForTriggeredNavigation(_ tab: Tab) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        if tab.webView.isLoading {
            try await waitForNavigation(tab)
        } else if let error = tab.lastNavigationError {
            throw BrowserAgentError.navigationFailed(error.localizedDescription)
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            throw BrowserAgentError.javaScriptFailed(error.localizedDescription)
        }
    }

}

extension BrowserSessionManager: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        objectWillChange.send()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let location = webViewLocations[ObjectIdentifier(webView)],
              let tab = sessions[location.sessionID]?.tabs[location.tabID],
              let allowedHosts = tab.allowedAgentNavigationHosts else {
            decisionHandler(.allow)
            return
        }
        guard let targetURL = navigationAction.request.url,
              let scheme = targetURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let targetHost = targetURL.host?.lowercased() else {
            tab.lastNavigationError = BrowserAgentError.invalidArguments(
                NSLocalizedString("Agent 浏览器跳转只允许 http 或 https 地址。", comment: "Browser Agent blocked navigation scheme")
            )
            decisionHandler(.cancel)
            return
        }
        let sourceHost = webView.url?.host?.lowercased()
        guard sourceHost == targetHost || allowedHosts.contains(targetHost) else {
            tab.lastNavigationError = BrowserAgentError.crossDomainApprovalRequired(
                sourceHost: sourceHost,
                targetHost: targetHost
            )
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        objectWillChange.send()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error, for: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error, for: webView)
    }

    private func recordNavigationFailure(_ error: Error, for webView: WKWebView) {
        guard let location = webViewLocations[ObjectIdentifier(webView)],
              let tab = sessions[location.sessionID]?.tabs[location.tabID] else { return }
        tab.lastNavigationError = error
        objectWillChange.send()
    }
}

#elseif os(watchOS)

import Darwin

@MainActor
public final class BrowserSessionManager: ObservableObject {
    public static let shared = BrowserSessionManager()

    private final class Tab {
        let id: UUID
        let webView: NSObject
        var domRevision = 0
        var userAgentProfile: BrowserAgentUserAgentProfile?
        var viewportWidth: Int?
        var viewportHeight: Int?
        var lastActivityAt = Date()

        init(id: UUID = UUID(), webView: NSObject) {
            self.id = id
            self.webView = webView
        }
    }

    private final class Session {
        var tabs: [UUID: Tab] = [:]
        var order: [UUID] = []
        var selectedTabID: UUID?
        var isUserControlling = false
        var controlState = BrowserAgentControlState.idle
    }

    private var sessions: [UUID: Session] = [:]

    public func capabilities() -> BrowserAgentCapabilities {
        let probe = Self.runtimeProbe()
        return BrowserAgentCapabilities(
            platform: "watchOS",
            isExperimental: true,
            supportsNavigation: probe.canLoadRequest,
            supportsSnapshot: probe.canEvaluateJavaScript,
            supportsClick: probe.canEvaluateJavaScript,
            supportsTyping: probe.canEvaluateJavaScript,
            supportsScrolling: probe.canEvaluateJavaScript,
            supportsJavaScript: probe.canEvaluateJavaScript,
            supportsScreenshot: false,
            supportsDownload: false,
            supportsUserTakeover: probe.hasWebView,
            supportsIPhoneDelegation: true,
            notes: [
                NSLocalizedString("watchOS 浏览器使用运行时 WebKit bridge，系统升级后能力可能变化。", comment: "Browser Agent watch experimental note"),
                NSLocalizedString("截图和下载在手表本机不声明支持，可由用户选择委托给 iPhone。", comment: "Browser Agent watch delegation note")
            ],
            supportedActions: BrowserAgentAction.allCases.filter {
                ![.screenshot, .fetch, .download, .scrollAndCollect, .waitForDOMStable, .setViewport].contains($0)
            }
        )
    }

    public func tabs(sessionID: UUID) -> [BrowserAgentTabSummary] {
        guard let session = sessions[sessionID] else { return [] }
        return session.order.compactMap { id in
            guard let tab = session.tabs[id] else { return nil }
            return summary(for: tab)
        }
    }

    public func isUserControlling(sessionID: UUID) -> Bool {
        sessions[sessionID]?.isUserControlling == true
    }

    public func setUserControlling(_ isControlling: Bool, sessionID: UUID) {
        if isControlling {
            let session = session(for: sessionID)
            session.isUserControlling = true
            session.controlState = BrowserAgentControlState(
                controller: .user,
                status: .running,
                tabID: session.selectedTabID,
                detail: NSLocalizedString("用户正在控制浏览器", comment: "Browser Agent user control state"),
                startedAt: Date()
            )
            Task { await BrowserAgentToolExecutor.shared.cancel(sessionID: sessionID) }
            objectWillChange.send()
        } else {
            Task { @MainActor [weak self] in
                await self?.releaseUserTakeover(sessionID: sessionID)
            }
        }
    }

    public func controlState(sessionID: UUID) -> BrowserAgentControlState {
        sessions[sessionID]?.controlState ?? .idle
    }

    public func beginUserTakeover(sessionID: UUID) {
        setUserControlling(true, sessionID: sessionID)
    }

    public func beginAgentAction(sessionID: UUID, tabID: UUID?, action: BrowserAgentAction) {
        let session = session(for: sessionID)
        session.controlState = BrowserAgentControlState(
            controller: .agent,
            status: .running,
            action: action,
            tabID: tabID ?? session.selectedTabID,
            detail: action.rawValue,
            startedAt: Date()
        )
        objectWillChange.send()
    }

    public func finishAgentAction(
        sessionID: UUID,
        action: BrowserAgentAction,
        status: BrowserAgentControlStatus,
        detail: String?
    ) {
        guard let session = sessions[sessionID], session.controlState.controller == .agent else { return }
        session.controlState = BrowserAgentControlState(
            controller: .idle,
            status: status,
            action: action,
            tabID: session.selectedTabID,
            detail: detail
        )
        objectWillChange.send()
    }

    @discardableResult
    public func openTab(
        sessionID: UUID,
        url: URL? = nil,
        dataProfile: BrowserAgentDataProfile? = nil,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        let session = session(for: sessionID)
        let webView = try Self.makeWebView()
        let tab = Tab(webView: webView)
        session.tabs[tab.id] = tab
        session.order.append(tab.id)
        session.selectedTabID = tab.id
        objectWillChange.send()
        if let url {
            try await navigate(
                sessionID: sessionID,
                tabID: tab.id,
                url: url,
                allowedAgentNavigationHosts: allowedAgentNavigationHosts
            )
        }
        return summary(for: tab)
    }

    public func closeTab(sessionID: UUID, tabID: UUID?) throws -> BrowserAgentTabSummary {
        let session = try existingSession(sessionID)
        let resolvedID = try resolvedTabID(tabID, session: session)
        guard let tab = session.tabs.removeValue(forKey: resolvedID) else {
            throw BrowserAgentError.tabNotFound
        }
        session.order.removeAll { $0 == resolvedID }
        if session.selectedTabID == resolvedID {
            session.selectedTabID = session.order.last
        }
        objectWillChange.send()
        return summary(for: tab)
    }

    @discardableResult
    public func navigate(
        sessionID: UUID,
        tabID: UUID?,
        url: URL,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> BrowserAgentTabSummary {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("浏览器仅接受 http 或 https URL。", comment: "Browser Agent invalid URL scheme")
            )
        }
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let selector = NSSelectorFromString("loadRequest:")
        guard tab.webView.responds(to: selector) else {
            throw BrowserAgentError.unsupported("loadRequest:")
        }
        let sourceHost = (tab.webView.value(forKey: "URL") as? URL)?.host?.lowercased()
        tab.webView.perform(selector, with: URLRequest(url: url) as NSURLRequest)
        try await waitForNavigation(tab.webView)
        try validateFinalNavigation(
            tab.webView,
            sourceHost: sourceHost,
            allowedHosts: allowedAgentNavigationHosts
        )
        objectWillChange.send()
        return summary(for: tab)
    }

    public func snapshot(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentSnapshot {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let value = try await evaluate(
            BrowserDOMAutomation.snapshot(),
            in: tab.webView
        )
        guard let object = value as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("页面快照没有返回可解析的数据。", comment: "Browser Agent invalid snapshot")
            )
        }
        let snapshot = try BrowserDOMResultParser.snapshot(object)
        tab.domRevision = snapshot.domRevision
        tab.lastActivityAt = Date()
        return snapshot
    }

    public func click(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let sourceHost = (tab.webView.value(forKey: "URL") as? URL)?.host?.lowercased()
        let value = try await evaluate(
            try BrowserDOMAutomation.click(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        try await waitForTriggeredNavigation(tab.webView)
        try validateFinalNavigation(
            tab.webView,
            sourceHost: sourceHost,
            allowedHosts: allowedAgentNavigationHosts
        )
    }

    public func type(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        text: String,
        submit: Bool,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let sourceHost = (tab.webView.value(forKey: "URL") as? URL)?.host?.lowercased()
        let value = try await evaluate(
            try BrowserDOMAutomation.type(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision,
                text: text,
                submit: submit
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        try await waitForTriggeredNavigation(tab.webView)
        try validateFinalNavigation(
            tab.webView,
            sourceHost: sourceHost,
            allowedHosts: allowedAgentNavigationHosts
        )
    }

    public func scroll(
        sessionID: UUID,
        tabID: UUID?,
        deltaX: Double,
        deltaY: Double,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        try await performGuardedInteraction(
            sessionID: sessionID,
            tabID: tabID,
            script: "window.scrollBy(\(deltaX), \(deltaY)); true",
            allowedAgentNavigationHosts: allowedAgentNavigationHosts
        )
    }

    public func evaluateJavaScript(
        sessionID: UUID,
        tabID: UUID?,
        script: String,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> JSONValue {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let sourceHost = (tab.webView.value(forKey: "URL") as? URL)?.host?.lowercased()
        let value = try await evaluate(script, in: tab.webView)
        try await waitForTriggeredNavigation(tab.webView)
        try validateFinalNavigation(
            tab.webView,
            sourceHost: sourceHost,
            allowedHosts: allowedAgentNavigationHosts
        )
        return browserAgentJSONValue(from: value)
    }

    public func webView(sessionID: UUID, tabID: UUID?) throws -> NSObject {
        try resolvedTab(sessionID: sessionID, tabID: tabID).webView
    }

    public func selectedTabID(sessionID: UUID) -> UUID? {
        sessions[sessionID]?.selectedTabID
    }

    func recordOverrides(
        sessionID: UUID,
        tabID: UUID?,
        userAgentProfile: BrowserAgentUserAgentProfile? = nil,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        resetViewport: Bool = false
    ) throws -> BrowserAgentTabSummary {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        if let userAgentProfile { tab.userAgentProfile = userAgentProfile == .reset ? nil : userAgentProfile }
        if resetViewport {
            tab.viewportWidth = nil
            tab.viewportHeight = nil
        } else if let viewportWidth, let viewportHeight {
            tab.viewportWidth = viewportWidth
            tab.viewportHeight = viewportHeight
        }
        tab.lastActivityAt = Date()
        return summary(for: tab)
    }

    public func currentURL(sessionID: UUID, tabID: UUID?) throws -> URL? {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        return tab.webView.value(forKey: "URL") as? URL
    }

    public func interactionDestination(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        submittingForm: Bool
    ) async throws -> URL? {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let value = try await evaluate(
            BrowserDOMAutomation.interactionDestination(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision,
                submittingForm: submittingForm
            ),
            in: tab.webView
        )
        try BrowserDOMResultParser.interactionError(value)
        guard let value = value as? String else { return nil }
        return URL(string: value)
    }

    func performGuardedInteraction(
        sessionID: UUID,
        tabID: UUID?,
        script: String,
        allowedAgentNavigationHosts: Set<String>?
    ) async throws {
        let tab = try resolvedTab(sessionID: sessionID, tabID: tabID)
        let sourceHost = (tab.webView.value(forKey: "URL") as? URL)?.host?.lowercased()
        let value = try await evaluate(script, in: tab.webView)
        try BrowserDOMResultParser.interactionError(value)
        try await waitForTriggeredNavigation(tab.webView)
        try validateFinalNavigation(
            tab.webView,
            sourceHost: sourceHost,
            allowedHosts: allowedAgentNavigationHosts
        )
    }

    public func selectTab(sessionID: UUID, tabID: UUID) throws {
        let session = try existingSession(sessionID)
        guard session.tabs[tabID] != nil else { throw BrowserAgentError.tabNotFound }
        session.selectedTabID = tabID
        objectWillChange.send()
    }

    private func session(for sessionID: UUID) -> Session {
        if let existing = sessions[sessionID] { return existing }
        let created = Session()
        sessions[sessionID] = created
        return created
    }

    private func existingSession(_ sessionID: UUID) throws -> Session {
        guard let session = sessions[sessionID] else { throw BrowserAgentError.tabNotFound }
        return session
    }

    private func resolvedTab(sessionID: UUID, tabID: UUID?) throws -> Tab {
        let session = try existingSession(sessionID)
        let resolvedID = try resolvedTabID(tabID, session: session)
        guard let tab = session.tabs[resolvedID] else { throw BrowserAgentError.tabNotFound }
        session.selectedTabID = resolvedID
        tab.lastActivityAt = Date()
        return tab
    }

    private func resolvedTabID(_ tabID: UUID?, session: Session) throws -> UUID {
        guard let resolvedID = tabID ?? session.selectedTabID else { throw BrowserAgentError.tabNotFound }
        return resolvedID
    }

    private func summary(for tab: Tab) -> BrowserAgentTabSummary {
        BrowserAgentTabSummary(
            id: tab.id,
            title: (tab.webView.value(forKey: "title") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).browserNonEmptyValue
                ?? NSLocalizedString("新标签页", comment: "Browser Agent untitled tab"),
            url: (tab.webView.value(forKey: "URL") as? URL)?.absoluteString,
            isLoading: tab.webView.value(forKey: "loading") as? Bool ?? false,
            domRevision: tab.domRevision,
            userAgentProfile: tab.userAgentProfile,
            viewportWidth: tab.viewportWidth,
            viewportHeight: tab.viewportHeight,
            lastActivityAt: tab.lastActivityAt,
            wasRestoredByReload: false
        )
    }

    private func releaseUserTakeover(sessionID: UUID) async {
        guard let session = sessions[sessionID], session.isUserControlling else { return }
        session.controlState = BrowserAgentControlState(
            controller: .returningToAgent,
            status: .waiting,
            tabID: session.selectedTabID,
            detail: NSLocalizedString("正在刷新页面快照", comment: "Browser Agent refreshing after takeover")
        )
        objectWillChange.send()
        if session.selectedTabID != nil {
            _ = try? await snapshot(sessionID: sessionID, tabID: session.selectedTabID)
        }
        session.isUserControlling = false
        session.controlState = .idle
        objectWillChange.send()
    }

    private func waitForNavigation(_ webView: NSObject) async throws {
        let deadline = Date().addingTimeInterval(60)
        while webView.value(forKey: "loading") as? Bool == true {
            try Task.checkCancellation()
            if Date() >= deadline {
                throw BrowserAgentError.navigationFailed(
                    NSLocalizedString("等待网页加载超时。", comment: "Browser Agent navigation timeout")
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForTriggeredNavigation(_ webView: NSObject) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        if webView.value(forKey: "loading") as? Bool == true {
            try await waitForNavigation(webView)
        }
    }

    private func validateFinalNavigation(
        _ webView: NSObject,
        sourceHost: String?,
        allowedHosts: Set<String>?
    ) throws {
        guard let allowedHosts else { return }
        guard let url = webView.value(forKey: "URL") as? URL else {
            if sourceHost == nil { return }
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("Agent 浏览器跳转只允许 http 或 https 地址。", comment: "Browser Agent blocked navigation scheme")
            )
        }
        guard
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let targetHost = url.host?.lowercased() else {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("Agent 浏览器跳转只允许 http 或 https 地址。", comment: "Browser Agent blocked navigation scheme")
            )
        }
        let normalizedAllowedHosts = Set(allowedHosts.map { $0.lowercased() })
        guard sourceHost == targetHost || normalizedAllowedHosts.contains(targetHost) else {
            throw BrowserAgentError.crossDomainApprovalRequired(
                sourceHost: sourceHost,
                targetHost: targetHost
            )
        }
    }

    private func evaluate(_ script: String, in webView: NSObject) async throws -> Any? {
        let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard webView.responds(to: selector) else {
            throw BrowserAgentError.unsupported("evaluateJavaScript:completionHandler:")
        }
        let result: BrowserAgentUncheckedJavaScriptResult = try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (Any?, Error?) -> Void = { value, error in
                if let error {
                    continuation.resume(throwing: BrowserAgentError.javaScriptFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: BrowserAgentUncheckedJavaScriptResult(value: value))
                }
            }
            webView.perform(
                selector,
                with: script as NSString,
                with: unsafeBitCast(completion, to: AnyObject.self)
            )
        }
        return result.value
    }

    private static func runtimeProbe() -> (hasWebView: Bool, canLoadRequest: Bool, canEvaluateJavaScript: Bool) {
        loadWebKit()
        guard let webViewClass = NSClassFromString("WKWebView") as? NSObject.Type else {
            return (false, false, false)
        }
        let webView = webViewClass.init()
        return (
            true,
            webView.responds(to: NSSelectorFromString("loadRequest:")),
            webView.responds(to: NSSelectorFromString("evaluateJavaScript:completionHandler:"))
        )
    }

    private static func makeWebView() throws -> NSObject {
        loadWebKit()
        guard let webViewClass = NSClassFromString("WKWebView") as? NSObject.Type else {
            throw BrowserAgentError.unsupported("WKWebView")
        }
        let webView = webViewClass.init()
        if let scrollView = webView.value(forKey: "scrollView") as? NSObject {
            scrollView.setValue(true, forKey: "scrollEnabled")
            scrollView.setValue(true, forKey: "showsVerticalScrollIndicator")
        }
        return webView
    }

    private static func loadWebKit() {
        let frameworkPaths = [
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "/System/iOSSupport/System/Library/Frameworks/WebKit.framework/WebKit",
            "WebKit.framework/WebKit"
        ]
        for frameworkPath in frameworkPaths {
            frameworkPath.withCString { pathPointer in
                _ = dlopen(pathPointer, RTLD_LAZY)
            }
        }
    }

}

#endif
