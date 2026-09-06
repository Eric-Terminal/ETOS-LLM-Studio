// ============================================================================
// BrowserSessionManagerAdvanced.swift
// ============================================================================
// ETOS LLM Studio
//
// Browser Agent 的高级页面读取、稳定等待、收集、视口与截图动作。
// ============================================================================

import Foundation

#if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
import WebKit
import UIKit

@MainActor
public extension BrowserSessionManager {
    func getText(sessionID: UUID, tabID: UUID?, selector: String?) async throws -> JSONValue {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        return browserAgentJSONValue(from: try await evaluateAdvanced(
            try BrowserDOMAutomation.getText(selector: selector),
            in: webView
        ))
    }

    func getPageInfo(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentPageInfo {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        guard let object = try await evaluateAdvanced(BrowserDOMAutomation.pageInfo, in: webView) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("页面信息没有返回可解析的数据。", comment: "Browser Agent invalid page info")
            )
        }
        return BrowserDOMResultParser.pageInfo(object)
    }

    func findElements(
        sessionID: UUID,
        tabID: UUID?,
        selector: String?,
        maximumElements: Int
    ) async throws -> BrowserAgentElementCollection {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        guard let object = try await evaluateAdvanced(
            try BrowserDOMAutomation.findElements(
                selector: selector,
                maximumElements: maximumElements
            ),
            in: webView
        ) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("元素查找没有返回可解析的数据。", comment: "Browser Agent invalid element search")
            )
        }
        let revision = (object["domRevision"] as? NSNumber)?.intValue ?? 0
        return BrowserAgentElementCollection(
            elements: BrowserDOMResultParser.elements(object["elements"], fallbackRevision: revision),
            domRevision: revision,
            wasTruncated: object["wasTruncated"] as? Bool ?? false
        )
    }

    func hover(
        sessionID: UUID,
        tabID: UUID?,
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws {
        try await performGuardedInteraction(
            sessionID: sessionID,
            tabID: tabID,
            script: try BrowserDOMAutomation.hover(
                elementID: elementID,
                elementIndex: elementIndex,
                domRevision: domRevision
            ),
            allowedAgentNavigationHosts: allowedAgentNavigationHosts
        )
    }

    func getReadable(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentReadableContent {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        guard let object = try await evaluateAdvanced(BrowserReadableContent.script, in: webView) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("正文提取没有返回可解析的数据。", comment: "Browser Agent invalid readable content")
            )
        }
        return BrowserDOMResultParser.readable(object)
    }

    func getBackbone(
        sessionID: UUID,
        tabID: UUID?,
        selector: String?,
        maximumDepth: Int,
        maximumNodes: Int
    ) async throws -> JSONValue {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        return browserAgentJSONValue(from: try await evaluateAdvanced(
            try BrowserDOMAutomation.backbone(
                selector: selector,
                maximumDepth: maximumDepth,
                maximumNodes: maximumNodes
            ),
            in: webView
        ))
    }

    func waitForDOMStable(
        sessionID: UUID,
        tabID: UUID?,
        timeoutSeconds: Double,
        quietPeriodSeconds: Double
    ) async throws -> JSONValue {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        let token = UUID().uuidString
        let body = """
        const token = tokenValue;
        window.__etosDOMStableWaits = window.__etosDOMStableWaits || {};
        const timeoutMilliseconds = \(Int(timeoutSeconds * 1_000));
        const quietMilliseconds = \(Int(quietPeriodSeconds * 1_000));
        return await new Promise(resolve => {
          const startedAt = Date.now();
          let mutationCount = 0;
          let quietTimer = null;
          let timeoutTimer = null;
          const finish = (stable, cancelled) => {
            observer.disconnect();
            if (quietTimer) clearTimeout(quietTimer);
            if (timeoutTimer) clearTimeout(timeoutTimer);
            delete window.__etosDOMStableWaits[token];
            resolve({stable, cancelled, mutationCount, elapsedMilliseconds: Date.now() - startedAt});
          };
          const scheduleQuiet = () => {
            if (quietTimer) clearTimeout(quietTimer);
            quietTimer = setTimeout(() => finish(true, false), quietMilliseconds);
          };
          const observer = new MutationObserver(records => {
            mutationCount += records.length;
            scheduleQuiet();
          });
          window.__etosDOMStableWaits[token] = () => finish(false, true);
          observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
          timeoutTimer = setTimeout(() => finish(false, false), timeoutMilliseconds);
          scheduleQuiet();
        });
        """
        let value = try await withTaskCancellationHandler {
            try await webView.callAsyncJavaScript(
                body,
                arguments: ["tokenValue": token],
                in: nil,
                contentWorld: .page
            )
        } onCancel: {
            Task { @MainActor in
                let literal = (try? browserAgentJavaScriptLiteral(token)) ?? "''"
                _ = try? await webView.evaluateJavaScript("window.__etosDOMStableWaits?.[\(literal)]?.(); true")
            }
        }
        try Task.checkCancellation()
        return browserAgentJSONValue(from: value)
    }

    func scrollAndCollect(
        sessionID: UUID,
        tabID: UUID?,
        deltaY: Double,
        scrollCount: Int,
        itemSelector: String,
        dedupeKey: String?,
        allowedAgentNavigationHosts: Set<String>? = nil
    ) async throws -> JSONValue {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        var itemsByKey: [String: [String: Any]] = [:]
        var order: [String] = []
        var completedScrolls = 0
        for index in 0...scrollCount {
            try Task.checkCancellation()
            guard let values = try await evaluateAdvanced(
                try BrowserDOMAutomation.collectItems(
                    itemSelector: itemSelector,
                    dedupeKey: dedupeKey
                ),
                in: webView
            ) as? [[String: Any]] else {
                throw BrowserAgentError.javaScriptFailed(
                    NSLocalizedString("滚动收集没有返回可解析的数据。", comment: "Browser Agent invalid scroll collection")
                )
            }
            for value in values.prefix(500) {
                guard let key = value["key"] as? String, itemsByKey[key] == nil else { continue }
                itemsByKey[key] = value
                order.append(key)
                if order.count >= 1_000 { break }
            }
            if index == scrollCount || order.count >= 1_000 { break }
            try await performGuardedInteraction(
                sessionID: sessionID,
                tabID: tabID,
                script: "window.scrollBy(0, \(deltaY)); true",
                allowedAgentNavigationHosts: allowedAgentNavigationHosts
            )
            _ = try await waitForDOMStable(
                sessionID: sessionID,
                tabID: tabID,
                timeoutSeconds: 5,
                quietPeriodSeconds: 0.35
            )
            completedScrolls += 1
        }
        let items = order.compactMap { itemsByKey[$0] }
        return .dictionary([
            "items": .array(items.map { item in
                .dictionary(item.mapValues { browserAgentJSONValue(from: $0) })
            }),
            "count": .int(items.count),
            "scroll_count": .int(completedScrolls),
            "was_truncated": .bool(items.count >= 1_000)
        ])
    }

    func setUserAgent(
        sessionID: UUID,
        tabID: UUID?,
        profile: BrowserAgentUserAgentProfile
    ) async throws -> BrowserAgentTabSummary {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        switch profile {
        case .mobileSafari:
            webView.customUserAgent = nil
            webView.configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        case .desktopSafari:
            webView.customUserAgent = nil
            webView.configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        case .reset:
            webView.customUserAgent = nil
            webView.configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        }
        if webView.url != nil { webView.reload() }
        return try recordOverrides(
            sessionID: sessionID,
            tabID: tabID,
            userAgentProfile: profile
        )
    }

    func setViewport(
        sessionID: UUID,
        tabID: UUID?,
        width: Int?,
        height: Int?,
        reset: Bool
    ) async throws -> BrowserAgentTabSummary {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if !reset, let width, let height {
            let script = WKUserScript(
                source: """
                (() => {
                  document.querySelectorAll('meta[name="viewport"]').forEach(node => node.remove());
                  const meta = document.createElement('meta');
                  meta.name = 'viewport';
                  meta.content = 'width=\(width), initial-scale=1.0, user-scalable=yes';
                  (document.head || document.documentElement).appendChild(meta);
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
            webView.frame.size = CGSize(width: width, height: height)
        }
        if webView.url != nil { webView.reload() }
        return try recordOverrides(
            sessionID: sessionID,
            tabID: tabID,
            viewportWidth: width,
            viewportHeight: height,
            resetViewport: reset
        )
    }

    func screenshot(
        sessionID: UUID,
        tabID: UUID?,
        fullPage: Bool
    ) async throws -> BrowserAgentScreenshotResult {
        let webView = try await preparedWebView(sessionID: sessionID, tabID: tabID)
        return try await BrowserFullPageCapture.capture(
            webView: webView,
            sessionID: sessionID,
            fullPage: fullPage
        )
    }

    private func evaluateAdvanced(_ script: String, in webView: WKWebView) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            throw BrowserAgentError.javaScriptFailed(error.localizedDescription)
        }
    }
}

#elseif os(watchOS)

@MainActor
public extension BrowserSessionManager {
    func getText(sessionID: UUID, tabID: UUID?, selector: String?) async throws -> JSONValue {
        browserAgentJSONValue(from: try await evaluateAdvanced(
            try BrowserDOMAutomation.getText(selector: selector),
            in: try webView(sessionID: sessionID, tabID: tabID)
        ))
    }

    func getPageInfo(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentPageInfo {
        guard let object = try await evaluateAdvanced(
            BrowserDOMAutomation.pageInfo,
            in: try webView(sessionID: sessionID, tabID: tabID)
        ) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(NSLocalizedString("页面信息没有返回可解析的数据。", comment: "Browser Agent invalid page info"))
        }
        return BrowserDOMResultParser.pageInfo(object)
    }

    func findElements(sessionID: UUID, tabID: UUID?, selector: String?, maximumElements: Int) async throws -> BrowserAgentElementCollection {
        guard let object = try await evaluateAdvanced(
            try BrowserDOMAutomation.findElements(selector: selector, maximumElements: maximumElements),
            in: try webView(sessionID: sessionID, tabID: tabID)
        ) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(NSLocalizedString("元素查找没有返回可解析的数据。", comment: "Browser Agent invalid element search"))
        }
        let revision = (object["domRevision"] as? NSNumber)?.intValue ?? 0
        return BrowserAgentElementCollection(
            elements: BrowserDOMResultParser.elements(object["elements"], fallbackRevision: revision),
            domRevision: revision,
            wasTruncated: object["wasTruncated"] as? Bool ?? false
        )
    }

    func hover(sessionID: UUID, tabID: UUID?, elementID: String?, elementIndex: Int?, domRevision: Int?, allowedAgentNavigationHosts: Set<String>? = nil) async throws {
        try await performGuardedInteraction(
            sessionID: sessionID,
            tabID: tabID,
            script: try BrowserDOMAutomation.hover(elementID: elementID, elementIndex: elementIndex, domRevision: domRevision),
            allowedAgentNavigationHosts: allowedAgentNavigationHosts
        )
    }

    func getReadable(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentReadableContent {
        guard let object = try await evaluateAdvanced(
            BrowserReadableContent.script,
            in: try webView(sessionID: sessionID, tabID: tabID)
        ) as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(NSLocalizedString("正文提取没有返回可解析的数据。", comment: "Browser Agent invalid readable content"))
        }
        return BrowserDOMResultParser.readable(object)
    }

    func getBackbone(sessionID: UUID, tabID: UUID?, selector: String?, maximumDepth: Int, maximumNodes: Int) async throws -> JSONValue {
        browserAgentJSONValue(from: try await evaluateAdvanced(
            try BrowserDOMAutomation.backbone(selector: selector, maximumDepth: maximumDepth, maximumNodes: maximumNodes),
            in: try webView(sessionID: sessionID, tabID: tabID)
        ))
    }

    func waitForDOMStable(sessionID: UUID, tabID: UUID?, timeoutSeconds: Double, quietPeriodSeconds: Double) async throws -> JSONValue {
        throw BrowserAgentError.unsupported(
            NSLocalizedString("watchOS 本机 WebKit bridge 不提供可取消的异步 DOM 等待；可明确委托给 iPhone。", comment: "Watch DOM stable unsupported")
        )
    }

    func scrollAndCollect(sessionID: UUID, tabID: UUID?, deltaY: Double, scrollCount: Int, itemSelector: String, dedupeKey: String?, allowedAgentNavigationHosts: Set<String>? = nil) async throws -> JSONValue {
        throw BrowserAgentError.unsupported(
            NSLocalizedString("watchOS 本机 WebKit bridge 不提供稳定滚动收集；可明确委托给 iPhone。", comment: "Watch scroll collect unsupported")
        )
    }

    func setUserAgent(sessionID: UUID, tabID: UUID?, profile: BrowserAgentUserAgentProfile) async throws -> BrowserAgentTabSummary {
        let webView = try webView(sessionID: sessionID, tabID: tabID)
        guard webView.responds(to: NSSelectorFromString("setCustomUserAgent:")) else {
            throw BrowserAgentError.unsupported("setCustomUserAgent:")
        }
        let value: String? = profile == .desktopSafari
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
            : nil
        webView.setValue(value, forKey: "customUserAgent")
        return try recordOverrides(
            sessionID: sessionID,
            tabID: tabID,
            userAgentProfile: profile
        )
    }

    func setViewport(sessionID: UUID, tabID: UUID?, width: Int?, height: Int?, reset: Bool) async throws -> BrowserAgentTabSummary {
        throw BrowserAgentError.unsupported(
            NSLocalizedString("watchOS 本机 WebKit bridge 不提供可靠视口覆盖；可明确委托给 iPhone。", comment: "Watch viewport unsupported")
        )
    }

    private func evaluateAdvanced(_ script: String, in webView: NSObject) async throws -> Any? {
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
            webView.perform(selector, with: script as NSString, with: unsafeBitCast(completion, to: AnyObject.self))
        }
        return result.value
    }
}
#else
@MainActor
public extension BrowserSessionManager {
    func getText(sessionID: UUID, tabID: UUID?, selector: String?) async throws -> JSONValue { throw BrowserAgentError.unsupported("WKWebView") }
    func getPageInfo(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentPageInfo { throw BrowserAgentError.unsupported("WKWebView") }
    func findElements(sessionID: UUID, tabID: UUID?, selector: String?, maximumElements: Int) async throws -> BrowserAgentElementCollection { throw BrowserAgentError.unsupported("WKWebView") }
    func hover(sessionID: UUID, tabID: UUID?, elementID: String?, elementIndex: Int?, domRevision: Int?, allowedAgentNavigationHosts: Set<String>? = nil) async throws { throw BrowserAgentError.unsupported("WKWebView") }
    func getReadable(sessionID: UUID, tabID: UUID?) async throws -> BrowserAgentReadableContent { throw BrowserAgentError.unsupported("WKWebView") }
    func getBackbone(sessionID: UUID, tabID: UUID?, selector: String?, maximumDepth: Int, maximumNodes: Int) async throws -> JSONValue { throw BrowserAgentError.unsupported("WKWebView") }
    func waitForDOMStable(sessionID: UUID, tabID: UUID?, timeoutSeconds: Double, quietPeriodSeconds: Double) async throws -> JSONValue { throw BrowserAgentError.unsupported("WKWebView") }
    func scrollAndCollect(sessionID: UUID, tabID: UUID?, deltaY: Double, scrollCount: Int, itemSelector: String, dedupeKey: String?, allowedAgentNavigationHosts: Set<String>? = nil) async throws -> JSONValue { throw BrowserAgentError.unsupported("WKWebView") }
    func setUserAgent(sessionID: UUID, tabID: UUID?, profile: BrowserAgentUserAgentProfile) async throws -> BrowserAgentTabSummary { throw BrowserAgentError.unsupported("WKWebView") }
    func setViewport(sessionID: UUID, tabID: UUID?, width: Int?, height: Int?, reset: Bool) async throws -> BrowserAgentTabSummary { throw BrowserAgentError.unsupported("WKWebView") }
}
#endif
