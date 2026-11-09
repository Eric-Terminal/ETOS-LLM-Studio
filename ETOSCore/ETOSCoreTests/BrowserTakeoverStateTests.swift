import Foundation
import Testing
@testable import ETOSCore

#if canImport(WebKit) && (canImport(UIKit) || os(macOS)) && !os(watchOS)
import WebKit

@MainActor
@Suite("浏览器接管登录态", .serialized, .timeLimit(.minutes(1)))
struct BrowserTakeoverStateTests {
    enum TakeoverEntry: CaseIterable, Sendable {
        case selectedTab
        case switchedTab
        case newTab
    }

    @Test("交还及后台回收后，Agent 仍使用用户登录的原页面", arguments: TakeoverEntry.allCases)
    func takeoverPreservesLoginState(entry: TakeoverEntry) async throws {
        let manager = BrowserSessionManager()
        let sessionID = UUID()
        defer { manager.discardAllSessions() }
        let initial = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated)
        let targetID: UUID
        switch entry {
        case .selectedTab:
            targetID = initial.id
            manager.beginUserTakeover(sessionID: sessionID)
        case .switchedTab:
            let target = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated)
            try manager.selectTab(sessionID: sessionID, tabID: initial.id)
            manager.beginUserTakeover(sessionID: sessionID)
            try manager.selectTab(sessionID: sessionID, tabID: target.id)
            targetID = target.id
        case .newTab:
            manager.beginUserTakeover(sessionID: sessionID)
            targetID = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated).id
        }

        // 与接管界面一样借用管理器持有的页面，登录数据只存在于 WebKit 内。
        let userWebView = try #require(manager.selectedWebView(sessionID: sessionID))
        let loader = BrowserTakeoverPageLoader()
        try await loader.load(in: userWebView)
        try #require(userWebView.url != nil)
        try #require(!userWebView.isLoading)
        _ = try await userWebView.evaluateJavaScript("""
            document.cookie = 'browser_login=accepted; path=/; SameSite=Lax';
            localStorage.setItem('browser_login', 'local-token');
            sessionStorage.setItem('browser_login', 'session-token');
            window.browserLoginState = 'live-page';
            true;
            """)
        let beforeHandoff = try await manager.evaluateJavaScript(
            sessionID: sessionID, tabID: targetID, script: Self.loginStateScript
        )
        #expect(beforeHandoff == Self.expectedLoginState)
        #expect(!userWebView.configuration.websiteDataStore.isPersistent)

        try await handBack(manager, sessionID: sessionID)
        manager.beginAgentAction(sessionID: sessionID, tabID: targetID, action: .evaluateJavaScript)
        let afterHandoff = try await manager.evaluateJavaScript(
            sessionID: sessionID, tabID: targetID, script: Self.loginStateScript
        )
        #expect(afterHandoff == beforeHandoff)
        manager.finishAgentAction(sessionID: sessionID, action: .evaluateJavaScript, status: .completed, detail: nil)

        // 切换到其他标签后分别模拟内存警告与超时回收，避免仅验证“当前标签不回收”。
        _ = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated)
        manager.reclaimBackgroundTabs(olderThan: nil)
        manager.reclaimBackgroundTabs(olderThan: .distantFuture)
        let agentWebView = try manager.webView(sessionID: sessionID, tabID: targetID)
        try #require(agentWebView === userWebView)
        manager.beginAgentAction(sessionID: sessionID, tabID: targetID, action: .evaluateJavaScript)
        let afterReclamation = try await manager.evaluateJavaScript(
            sessionID: sessionID, tabID: targetID, script: Self.loginStateScript
        )
        #expect(afterReclamation == beforeHandoff)
        #expect(manager.tabs(sessionID: sessionID).first(where: { $0.id == targetID })?.wasRestoredByReload == false)

        // Cookie 容器和 DOM 同时校验，防止只保留其中一层却仍然无法继承登录。
        let cookies = await agentWebView.configuration.websiteDataStore.httpCookieStore.browserAgentAllCookies()
        #expect(cookies.contains { $0.name == "browser_login" && $0.value == "accepted" })
        _ = try manager.closeTab(sessionID: sessionID, tabID: targetID)
        #expect(!manager.tabs(sessionID: sessionID).contains { $0.id == targetID })
    }

    @Test("接管不把临时登录数据泄漏到其他聊天，标签间只共享网站数据")
    func takeoverKeepsSessionIsolation() async throws {
        let manager = BrowserSessionManager()
        let sessionID = UUID()
        defer { manager.discardAllSessions() }
        _ = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated)
        manager.beginUserTakeover(sessionID: sessionID)
        let userWebView = try #require(manager.selectedWebView(sessionID: sessionID))
        let loader = BrowserTakeoverPageLoader()
        try await loader.load(in: userWebView)
        _ = try await userWebView.evaluateJavaScript("""
            document.cookie = 'browser_login=accepted; path=/; SameSite=Lax';
            localStorage.setItem('browser_login', 'local-token');
            sessionStorage.setItem('browser_login', 'session-token');
            true;
            """)
        try await handBack(manager, sessionID: sessionID)

        let sibling = try await manager.openTab(sessionID: sessionID, dataProfile: .sessionIsolated)
        let siblingWebView = try manager.webView(sessionID: sessionID, tabID: sibling.id)
        try await loader.load(in: siblingWebView)
        let siblingState = try await manager.evaluateJavaScript(
            sessionID: sessionID, tabID: sibling.id, script: Self.loginStateScript
        )
        #expect(siblingState == .dictionary([
            "cookie": .bool(true), "local": .string("local-token"), "session": .null, "page": .null
        ]))

        let otherSessionID = UUID()
        let other = try await manager.openTab(sessionID: otherSessionID, dataProfile: .sessionIsolated)
        let otherWebView = try manager.webView(sessionID: otherSessionID, tabID: other.id)
        try await loader.load(in: otherWebView)
        let otherState = try await manager.evaluateJavaScript(
            sessionID: otherSessionID, tabID: other.id, script: Self.loginStateScript
        )
        #expect(otherState == .dictionary([
            "cookie": .bool(false), "local": .null, "session": .null, "page": .null
        ]))
        let otherCookies = await otherWebView.configuration.websiteDataStore.httpCookieStore.browserAgentAllCookies()
        #expect(!otherCookies.contains { $0.name == "browser_login" })
    }

    private static let loginStateScript = """
        ({
            cookie: document.cookie.split(';').some(value => value.trim() === 'browser_login=accepted'),
            local: localStorage.getItem('browser_login'),
            session: sessionStorage.getItem('browser_login'),
            page: window.browserLoginState || null
        })
        """

    private static let expectedLoginState: JSONValue = .dictionary([
        "cookie": .bool(true), "local": .string("local-token"),
        "session": .string("session-token"), "page": .string("live-page")
    ])

    private func handBack(_ manager: BrowserSessionManager, sessionID: UUID) async throws {
        manager.setUserControlling(false, sessionID: sessionID)
        for _ in 0..<200 {
            if !manager.isUserControlling(sessionID: sessionID) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(!manager.isUserControlling(sessionID: sessionID))
        #expect(manager.controlState(sessionID: sessionID).controller == .idle)
    }
}

@MainActor
private final class BrowserTakeoverPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(in webView: WKWebView) async throws {
        let delegate = webView.navigationDelegate
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = delegate }
        // 仅加载内存 HTML；固定同源地址使隔离测试能够比较真实 Cookie 与 Web Storage。
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(
                "<!doctype html><html><head><title>登录态回归</title></head><body>页面</body></html>",
                baseURL: URL(string: "http://127.0.0.1/browser-takeover/")!
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
