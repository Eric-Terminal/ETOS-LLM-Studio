// ============================================================================
// WatchWebHTMLView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 上的 HTML 全屏承载层。系统没有公开 WebKit Swift 模块，
// 因此这里只在运行时桥接 WKWebView，并把私有 API 使用范围收束在本文件。
// ============================================================================

import SwiftUI
import Foundation
import Darwin
import ETOSCore

#if canImport(UIKit)
import UIKit
#endif

struct WatchWebHTMLPageItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let html: String
}

struct WatchWebHTMLPage: View {
    let item: WatchWebHTMLPageItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WatchRuntimeHTMLWebView(html: item.html)
            .ignoresSafeArea()
            .navigationTitle(item.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(NSLocalizedString("关闭", comment: "Close web preview"))
                }
            }
    }
}

struct WatchRuntimeHTMLWebView: _UIViewRepresentable {
    typealias UIViewType = NSObject

    let html: String
    let sessionID: UUID?
    let messageID: UUID?
    let versionIndex: Int
    let scriptID: UUID?

    init(
        html: String,
        sessionID: UUID? = nil,
        messageID: UUID? = nil,
        versionIndex: Int = 0,
        scriptID: UUID? = nil
    ) {
        self.html = html
        self.sessionID = sessionID
        self.messageID = messageID
        self.versionIndex = versionIndex
        self.scriptID = scriptID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID, messageID: messageID, versionIndex: versionIndex, scriptID: scriptID)
    }

    func makeUIView(context: Context) -> NSObject {
        let view = WatchWebKitRuntime.makeWebView(messageHandler: context.coordinator.messageHandler)
        context.coordinator.webView = view
        context.coordinator.loadedHTML = html
        WatchWebKitRuntime.load(html, into: view)
        return view
    }

    func updateUIView(_ uiView: NSObject, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        WatchWebKitRuntime.load(html, into: uiView)
    }

    static func dismantleUIView(_ uiView: NSObject, coordinator: Coordinator) {
        WatchWebKitRuntime.removeMessageHandler(from: uiView)
        coordinator.webView = nil
    }

    final class Coordinator {
        var loadedHTML: String?
        let messageHandler: WatchRoleplayScriptMessageHandler
        weak var webView: NSObject?
        private var buttonObserver: NSObjectProtocol? = nil

        init(sessionID: UUID?, messageID: UUID?, versionIndex: Int, scriptID: UUID?) {
            self.messageHandler = WatchRoleplayScriptMessageHandler(
                sessionID: sessionID,
                messageID: messageID,
                versionIndex: versionIndex
            )
            buttonObserver = NotificationCenter.default.addObserver(
                forName: RoleplayScriptButtonNotification.requested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let sessionID,
                      let scriptID,
                      notification.userInfo?[RoleplayScriptButtonNotification.sessionIDKey] as? UUID == sessionID,
                      notification.userInfo?[RoleplayScriptButtonNotification.scriptIDKey] as? UUID == scriptID,
                      let name = notification.userInfo?[RoleplayScriptButtonNotification.buttonNameKey] as? String,
                      let data = try? JSONEncoder().encode(name),
                      let literal = String(data: data, encoding: .utf8),
                      let webView = self.webView else { return }
                WatchWebKitRuntime.evaluate("window.__etosEmitScriptButton?.(\(literal));", in: webView)
            }
        }

        deinit {
            if let buttonObserver { NotificationCenter.default.removeObserver(buttonObserver) }
        }
    }
}

final class WatchRoleplayScriptMessageHandler: NSObject {
    let sessionID: UUID?
    let messageID: UUID?
    let versionIndex: Int

    init(sessionID: UUID?, messageID: UUID?, versionIndex: Int) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.versionIndex = versionIndex
    }

    @objc(userContentController:didReceiveScriptMessage:)
    func userContentController(_ userContentController: NSObject, didReceiveScriptMessage message: NSObject) {
        guard let sessionID, let messageID,
              let payload = message.value(forKey: "body") as? [String: Any],
              payload["action"] as? String != "height" else { return }
        RoleplayBridgeDispatcher.handle(
            payload,
            sessionID: sessionID,
            messageID: messageID,
            versionIndex: versionIndex
        )
    }
}

enum WatchWebHTMLDocumentFactory {
    static func mathDocument(
        content: String,
        prefersDarkPalette: Bool,
        fontScale: Double
    ) -> String {
        let background = prefersDarkPalette ? "#000000" : "#FFFFFF"
        let text = prefersDarkPalette ? "#F5F5F7" : "#1C1C1E"
        let secondary = prefersDarkPalette ? "rgba(235,235,245,0.72)" : "rgba(60,60,67,0.72)"
        let codeBackground = prefersDarkPalette ? "rgba(118,118,128,0.24)" : "rgba(118,118,128,0.14)"
        let quotedContent = jsonLiteral(content)
        let normalizedFontScale = String(format: "%.3f", FontLibrary.normalizedFontScale(fontScale))

        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0, user-scalable=yes" />
  <link
    rel="stylesheet"
    href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css"
    onerror="this.onerror=null;this.href='https://unpkg.com/katex@0.16.11/dist/katex.min.css';"
  >
  <style>
    :root {
      color-scheme: \(prefersDarkPalette ? "dark" : "light");
      --text: \(text);
      --secondary: \(secondary);
      --code-bg: \(codeBackground);
      --font-scale: \(normalizedFontScale);
    }
    html, body {
      margin: 0;
      min-height: 100%;
      background: \(background);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    body {
      box-sizing: border-box;
      padding: 12px 10px 18px;
      font-size: calc(16px * var(--font-scale));
      line-height: 1.48;
      overflow-wrap: anywhere;
    }
    #content {
      max-width: 100%;
    }
    p { margin: 0.35em 0; }
    ul, ol { margin: 0.35em 0; padding-left: 1.35em; }
    blockquote {
      margin: 0.45em 0;
      padding-left: 0.8em;
      border-left: 3px solid var(--secondary);
      color: var(--secondary);
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      background: var(--code-bg);
      border-radius: 5px;
      padding: 0.1em 0.3em;
      font-size: 0.9em;
    }
    pre {
      margin: 0.5em 0;
      padding: 0.65em;
      overflow-x: auto;
      background: var(--code-bg);
      border-radius: 9px;
    }
    pre code {
      background: transparent;
      padding: 0;
      white-space: pre;
    }
    table {
      border-collapse: collapse;
      max-width: 100%;
      display: block;
      overflow-x: auto;
    }
    th, td {
      border: 1px solid var(--secondary);
      padding: 0.28em 0.45em;
    }
    .katex-display {
      overflow-x: auto;
      overflow-y: hidden;
      padding: 0.15em 0 0.25em;
      text-align: left;
    }
    .katex-display > .katex {
      text-align: left;
    }
    .math-fallback {
      white-space: pre-wrap;
      color: var(--secondary);
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    }
  </style>
</head>
<body>
  <main id="content"></main>
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js" onerror="this.onerror=null;this.src='https://unpkg.com/marked/marked.min.js';"></script>
  <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/katex.min.js';"></script>
  <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/contrib/auto-render.min.js';"></script>
  <script>
    (function () {
      const raw = \(quotedContent);
      const content = document.getElementById("content");

      function escapeHTML(value) {
        return value
          .replaceAll("&", "&amp;")
          .replaceAll("<", "&lt;")
          .replaceAll(">", "&gt;")
          .replaceAll('"', "&quot;")
          .replaceAll("'", "&#39;");
      }

      function renderFallback() {
        content.innerHTML = '<div class="math-fallback">' + escapeHTML(raw).replaceAll("\\n", "<br/>") + '</div>';
      }

      function render() {
        if (window.marked) {
          try {
            content.innerHTML = window.marked.parse(raw, { gfm: true, breaks: false });
          } catch (_) {
            renderFallback();
          }
        } else {
          renderFallback();
        }

        if (window.renderMathInElement && window.katex) {
          try {
            window.renderMathInElement(content, {
              delimiters: [
                { left: "$$", right: "$$", display: true },
                { left: "\\\\[", right: "\\\\]", display: true },
                { left: "\\\\(", right: "\\\\)", display: false },
                { left: "$", right: "$", display: false }
              ],
              throwOnError: false,
              strict: "ignore"
            });
          } catch (_) {}
        }
      }

      render();
      setTimeout(render, 250);
      setTimeout(render, 900);
      setTimeout(render, 1800);
    })();
  </script>
</body>
</html>
"""
    }

    static func widgetDocument(
        payload: ToolWidgetPayload,
        prefersDarkPalette: Bool
    ) -> String {
        let background = prefersDarkPalette ? "#000000" : "#FFFFFF"
        let textPrimary = prefersDarkPalette ? "#FFFFFF" : "#1C1C1E"
        let textSecondary = prefersDarkPalette ? "#EBEBF5" : "#3C3C43"
        let backgroundSecondary = prefersDarkPalette ? "#1C1C1E" : "#F2F2F7"
        let border = prefersDarkPalette ? "rgba(235,235,245,0.18)" : "rgba(60,60,67,0.18)"

        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0, user-scalable=yes" />
  <style>
    :root {
      color-scheme: \(prefersDarkPalette ? "dark" : "light");
      --color-background-primary: \(background);
      --color-background-secondary: \(backgroundSecondary);
      --color-background-tertiary: \(background);
      --color-text-primary: \(textPrimary);
      --color-text-secondary: \(textSecondary);
      --color-text-tertiary: #8E8E93;
      --color-text-info: #0A84FF;
      --color-border-tertiary: \(border);
      --color-border-secondary: \(border);
      --border-radius-md: 8px;
      --border-radius-lg: 12px;
      --border-radius-xl: 16px;
      --font-sans: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      --font-serif: Georgia, 'Times New Roman', serif;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    }
    html, body {
      margin: 0;
      min-height: 100%;
      background: var(--color-background-primary);
      color: var(--color-text-primary);
      font-family: var(--font-sans);
      -webkit-font-smoothing: antialiased;
    }
    body {
      box-sizing: border-box;
      padding: 10px;
      overflow-wrap: anywhere;
    }
    #et-widget-root {
      width: 100%;
      min-width: 0;
      max-width: 100%;
      box-sizing: border-box;
    }
    img, svg, canvas, video {
      max-width: 100%;
      height: auto;
    }
  </style>
</head>
<body>
  <main id="et-widget-root">
\(payload.widgetCode)
  </main>
</body>
</html>
"""
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

private enum WatchWebKitRuntime {
    static func makeWebView(messageHandler: NSObject? = nil) -> NSObject {
        loadWebKitIfNeeded()
        guard let webViewClass = NSClassFromString("WKWebView") as? NSObject.Type else {
            return fallbackView()
        }
        let webView = webViewClass.init()
        if let messageHandler {
            addMessageHandler(messageHandler, to: webView)
        }
        configure(webView)
        return webView
    }

    static func load(_ html: String, into view: NSObject) {
        let selector = NSSelectorFromString("loadHTMLString:baseURL:")
        guard view.responds(to: selector) else { return }
        view.perform(selector, with: html as NSString, with: nil)
    }

    private static func loadWebKitIfNeeded() {
        let frameworkPaths: [String] = [
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "/System/iOSSupport/System/Library/Frameworks/WebKit.framework/WebKit",
            "WebKit.framework/WebKit"
        ]
        frameworkPaths.forEach { path in
            _ = dlopen(path, RTLD_LAZY)
        }
    }

    private static func configure(_ webView: NSObject) {
        let backForwardSelector = NSSelectorFromString("setAllowsBackForwardNavigationGestures:")
        if webView.responds(to: backForwardSelector) {
            webView.setValue(true, forKey: "allowsBackForwardNavigationGestures")
        }
    }

    static func removeMessageHandler(from webView: NSObject) {
        guard let controller = userContentController(from: webView) else { return }
        let selector = NSSelectorFromString("removeScriptMessageHandlerForName:")
        if controller.responds(to: selector) {
            controller.perform(selector, with: "etosRoleplay" as NSString)
        }
    }

    static func evaluate(_ javaScript: String, in webView: NSObject) {
        let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        if webView.responds(to: selector) {
            webView.perform(selector, with: javaScript as NSString, with: nil)
        }
    }

    private static func addMessageHandler(_ handler: NSObject, to webView: NSObject) {
        guard let controller = userContentController(from: webView) else { return }
        let selector = NSSelectorFromString("addScriptMessageHandler:name:")
        if controller.responds(to: selector) {
            controller.perform(selector, with: handler, with: "etosRoleplay" as NSString)
        }
    }

    private static func userContentController(from webView: NSObject) -> NSObject? {
        guard let configuration = webView.value(forKey: "configuration") as? NSObject else { return nil }
        return configuration.value(forKey: "userContentController") as? NSObject
    }

    private static func fallbackView() -> NSObject {
        guard let labelClass = NSClassFromString("UILabel") as? NSObject.Type else {
            return NSObject()
        }
        let label = labelClass.init()
        label.setValue(
            NSLocalizedString("错误：当前 watchOS 运行时没有可用的 WKWebView。", comment: "watchOS WebKit unavailable fallback"),
            forKey: "text"
        )
        label.setValue(1, forKey: "textAlignment")
        label.setValue(0, forKey: "numberOfLines")
        return label
    }
}
