import Foundation
import SwiftUI
import MarkdownUI
import Shared
import WebKit
import UIKit

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool

    private var shouldUseMathWebRenderer: Bool {
        enableAdvancedRenderer
            && enableMathRendering
            && ETMathContentParser.containsMath(in: content)
    }

    var body: some View {
        if shouldUseMathWebRenderer {
            ETMathWebMarkdownView(
                content: content,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing
            )
        } else {
            baseTextView(content)
        }
    }

    @ViewBuilder
    private func baseTextView(_ text: String) -> some View {
        if enableMarkdown {
            Markdown(text)
                .markdownSoftBreakMode(.lineBreak)
                .markdownTextStyle {
                    ForegroundColor(isOutgoing ? .white : .primary)
                }
        } else {
            Text(text)
                .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        }
    }
}

private struct ETMathWebMarkdownView: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool

    @State private var renderedHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            ETMathWebViewRepresentable(
                content: content,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing,
                availableWidth: max(1, geometry.size.width),
                renderedHeight: $renderedHeight
            )
        }
        .frame(height: max(28, renderedHeight))
    }
}

private struct ETMathWebViewRepresentable: UIViewRepresentable {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let availableWidth: CGFloat
    @Binding var renderedHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        controller.add(context.coordinator, name: Coordinator.heightMessageName)
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let payload = Payload(
            content: content,
            enableMarkdown: enableMarkdown,
            isOutgoing: isOutgoing,
            availableWidth: availableWidth
        )

        guard context.coordinator.lastPayload != payload else { return }
        context.coordinator.lastPayload = payload
        webView.loadHTMLString(payload.htmlDocument, baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etMathHeight"

        @Binding var renderedHeight: CGFloat
        var lastPayload: Payload?

        init(renderedHeight: Binding<CGFloat>) {
            self._renderedHeight = renderedHeight
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.heightMessageName else { return }
            guard let value = message.body as? Double else { return }

            let newHeight = max(28, ceil(value))
            if abs(renderedHeight - newHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.renderedHeight = newHeight
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = "window.__etNotifyHeight && window.__etNotifyHeight();"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    struct Payload: Equatable {
        let content: String
        let enableMarkdown: Bool
        let isOutgoing: Bool
        let availableWidth: CGFloat

        var htmlDocument: String {
            let sourceJSON = jsonEscaped(content)
            let textColor = isOutgoing ? "#FFFFFF" : UIColor.label.hexString
            let secondaryTextColor = isOutgoing ? "rgba(255,255,255,0.85)" : UIColor.secondaryLabel.hexString
            let linkColor = isOutgoing ? "rgba(255,255,255,0.95)" : "#0A84FF"
            let maxContentWidth = max(1, floor(availableWidth))

            return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
  <style>
    :root {
      color-scheme: light dark;
      --text: \(textColor);
      --secondary: \(secondaryTextColor);
      --link: \(linkColor);
      --max-width: \(maxContentWidth)px;
    }

    html, body {
      margin: 0;
      padding: 0;
      background: transparent;
      color: var(--text);
      width: 100%;
      overflow: hidden;
      font: -apple-system-body;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
    }

    #content {
      width: 100%;
      max-width: var(--max-width);
      box-sizing: border-box;
      line-height: 1.45;
      word-break: break-word;
      overflow-wrap: anywhere;
      color: var(--text);
    }

    p { margin: 0.25em 0; }
    ul, ol { margin: 0.3em 0; padding-left: 1.25em; }
    li { margin: 0.2em 0; }
    a { color: var(--link); text-decoration: underline; }
    strong { font-weight: 600; }
    em { font-style: italic; }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      background: rgba(127,127,127,0.16);
      border-radius: 6px;
      padding: 0.08em 0.3em;
      font-size: 0.92em;
    }
    pre {
      margin: 0.35em 0;
      padding: 0.55em 0.65em;
      border-radius: 10px;
      background: rgba(127,127,127,0.14);
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    pre code {
      background: transparent;
      padding: 0;
      border-radius: 0;
      white-space: pre;
      overflow-wrap: normal;
      word-break: normal;
    }

    .katex {
      color: var(--text);
      font-size: 1em;
    }
    .katex-display {
      margin: 0.28em 0;
      overflow-x: auto;
      overflow-y: hidden;
      -webkit-overflow-scrolling: touch;
      padding-bottom: 1px;
      max-width: 100%;
    }
    .katex-display > .katex {
      text-align: left;
    }
    .katex-error {
      color: var(--secondary);
      white-space: pre-wrap;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      font-size: 0.9em;
    }
  </style>
</head>
<body>
  <div id="content"></div>

  <script>
    const __raw = \(sourceJSON);
    const __enableMarkdown = \(enableMarkdown ? "true" : "false");

    function __escapeHTML(input) {
      return input
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll("\"", "&quot;")
        .replaceAll("'", "&#39;");
    }

    function __setFallbackContent() {
      const container = document.getElementById("content");
      const escaped = __escapeHTML(__raw).replaceAll("\\n", "<br/>");
      container.innerHTML = escaped;
    }

    function __notifyHeightNow() {
      const body = document.body;
      const doc = document.documentElement;
      const height = Math.max(
        body.scrollHeight,
        body.offsetHeight,
        doc.clientHeight,
        doc.scrollHeight,
        doc.offsetHeight
      );
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.etMathHeight) {
        window.webkit.messageHandlers.etMathHeight.postMessage(height);
      }
    }

    window.__etNotifyHeight = __notifyHeightNow;

    function __render() {
      const container = document.getElementById("content");

      if (__enableMarkdown && window.marked) {
        container.innerHTML = window.marked.parse(__raw, { breaks: true, gfm: true });
      } else if (!__enableMarkdown) {
        __setFallbackContent();
      } else {
        __setFallbackContent();
      }

      if (window.renderMathInElement) {
        window.renderMathInElement(container, {
          delimiters: [
            { left: "$$", right: "$$", display: true },
            { left: "\\\\[", right: "\\\\]", display: true },
            { left: "\\\\(", right: "\\\\)", display: false },
            { left: "$", right: "$", display: false }
          ],
          throwOnError: false,
          strict: "ignore"
        });
      }

      __notifyHeightNow();
    }

    function __bootstrap(retryCount = 0) {
      const markdownReady = !__enableMarkdown || !!window.marked;
      const mathReady = !!window.renderMathInElement;
      if (markdownReady && mathReady) {
        __render();
        return;
      }

      if (retryCount >= 80) {
        __setFallbackContent();
        __notifyHeightNow();
        return;
      }

      setTimeout(() => __bootstrap(retryCount + 1), 50);
    }

    if (window.ResizeObserver) {
      const observer = new ResizeObserver(() => __notifyHeightNow());
      observer.observe(document.documentElement);
    }

    window.addEventListener("load", () => __bootstrap(0));
    window.addEventListener("resize", () => __notifyHeightNow());
  </script>

  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
</body>
</html>
"""
        }

        private func jsonEscaped(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }
    }
}

private extension UIColor {
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#000000"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}
