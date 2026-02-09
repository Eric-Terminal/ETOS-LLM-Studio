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
            let textColor: Color = isOutgoing ? .white : .primary
            Markdown(text)
                .etChatMarkdownBaseStyle(textColor: textColor)
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
        let stableWidth = max(1, floor(availableWidth))
        let payload = Payload(
            content: content,
            enableMarkdown: enableMarkdown,
            isOutgoing: isOutgoing,
            availableWidth: stableWidth
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
            let textColor = isOutgoing ? "#FFFFFF" : "#1C1C1E"
            let secondaryTextColor = isOutgoing ? "rgba(255,255,255,0.85)" : "#3C3C43"
            let linkColor = isOutgoing ? "rgba(255,255,255,0.95)" : "#0A84FF"
            let maxContentWidth = max(1, floor(availableWidth))
            let initialFallbackHTML = htmlEscaped(content).replacingOccurrences(of: "\n", with: "<br/>")

            return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <link
    rel="stylesheet"
    href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css"
    onerror="this.onerror=null;this.href='https://unpkg.com/katex@0.16.11/dist/katex.min.css';"
  >
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

    .et-table-scroll {
      margin: 0.3em 0;
      overflow-x: auto;
      overflow-y: hidden;
      -webkit-overflow-scrolling: touch;
      max-width: 100%;
    }
    .et-table-scroll table {
      width: max-content;
      min-width: 100%;
      border-collapse: collapse;
      table-layout: auto;
    }
    .et-table-scroll th,
    .et-table-scroll td {
      white-space: nowrap;
      padding: 0.25em 0.55em;
      border: 1px solid rgba(127,127,127,0.3);
      vertical-align: top;
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
    .et-math-block {
      margin: 0.3em 0;
      overflow-x: auto;
      overflow-y: hidden;
      -webkit-overflow-scrolling: touch;
      max-width: 100%;
    }
  </style>
</head>
<body>
  <div id="content">\(initialFallbackHTML)</div>

  <script>
    const __raw = \(sourceJSON);
    const __enableMarkdown = \(enableMarkdown ? "true" : "false");
    const __rawHasMath = __raw.includes("$$") || __raw.includes("\\\\(") || __raw.includes("\\\\[");

    function __escapeHTML(input) {
      return input
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function __setFallbackContent() {
      const container = document.getElementById("content");
      const escaped = __escapeHTML(__raw).replaceAll("\\n", "<br/>");
      container.innerHTML = escaped;
    }

    function __notifyHeightNow() {
      const content = document.getElementById("content");
      const rectHeight = content ? content.getBoundingClientRect().height : 0;
      const scrollHeight = content ? content.scrollHeight : 0;
      const height = Math.max(rectHeight, scrollHeight, 1);
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.etMathHeight) {
        window.webkit.messageHandlers.etMathHeight.postMessage(height);
      }
    }

    window.__etNotifyHeight = __notifyHeightNow;

    function __wrapTables(container) {
      const tables = container.querySelectorAll("table");
      tables.forEach((table) => {
        const parent = table.parentElement;
        if (parent && parent.classList.contains("et-table-scroll")) {
          return;
        }
        const wrapper = document.createElement("div");
        wrapper.className = "et-table-scroll";
        table.parentNode.insertBefore(wrapper, table);
        wrapper.appendChild(table);
      });
    }

    function __tokenizeDisplayMath(source) {
      const blocks = [];

      let rewritten = source.replace(/\\$\\$([\\s\\S]+?)\\$\\$/g, (_, latex) => {
        const index = blocks.length;
        blocks.push(latex.trim());
        return `\n\n<div class="et-math-block" data-et-math-index="${index}"></div>\n\n`;
      });

      let cursor = 0;
      let bracketRewritten = "";
      while (cursor < rewritten.length) {
        const start = rewritten.indexOf("\\\\[", cursor);
        if (start < 0) {
          bracketRewritten += rewritten.slice(cursor);
          break;
        }
        const end = rewritten.indexOf("\\\\]", start + 2);
        if (end < 0) {
          bracketRewritten += rewritten.slice(cursor);
          break;
        }
        const latex = rewritten.slice(start + 2, end).trim();
        const index = blocks.length;
        blocks.push(latex);
        bracketRewritten += rewritten.slice(cursor, start);
        bracketRewritten += `\n\n<div class="et-math-block" data-et-math-index="${index}"></div>\n\n`;
        cursor = end + 2;
      }
      rewritten = bracketRewritten;

      return { markdown: rewritten, blocks };
    }

    function __renderMathBlocks(container, blocks) {
      if (!window.katex || !Array.isArray(blocks) || blocks.length === 0) {
        return;
      }
      const nodes = container.querySelectorAll(".et-math-block[data-et-math-index]");
      nodes.forEach((node) => {
        const index = Number(node.getAttribute("data-et-math-index"));
        if (!Number.isFinite(index) || index < 0 || index >= blocks.length) {
          return;
        }
        const latex = (blocks[index] || "").trim();
        if (!latex) {
          return;
        }
        try {
          window.katex.render(latex, node, {
            displayMode: true,
            throwOnError: false,
            strict: "ignore"
          });
        } catch (_) {
          node.textContent = `$$\n${latex}\n$$`;
        }
      });
    }

    function __render() {
      const container = document.getElementById("content");

      if (__enableMarkdown && window.marked) {
        const tokenized = __tokenizeDisplayMath(__raw);
        container.innerHTML = window.marked.parse(tokenized.markdown, {
          breaks: !__rawHasMath,
          gfm: true
        });
        __renderMathBlocks(container, tokenized.blocks);
      } else if (!__enableMarkdown) {
        __setFallbackContent();
      } else {
        __setFallbackContent();
      }

      __wrapTables(container);

      if (window.renderMathInElement) {
        try {
          window.renderMathInElement(container, {
            delimiters: [
              { left: "\\\\(", right: "\\\\)", display: false },
              { left: "$", right: "$", display: false }
            ],
            throwOnError: false,
            strict: "ignore"
          });
        } catch (_) {}
      }

      __notifyHeightNow();
    }

    function __bootstrap(retryCount = 0) {
      __render();

      const markdownReady = !__enableMarkdown || !!window.marked;
      const mathReady = !!window.renderMathInElement && !!window.katex;
      if ((markdownReady && mathReady) || retryCount >= 80) {
        return;
      }

      setTimeout(() => __bootstrap(retryCount + 1), 50);
    }

    if (window.ResizeObserver) {
      const observer = new ResizeObserver(() => __notifyHeightNow());
      const content = document.getElementById("content");
      if (content) {
        observer.observe(content);
      }
    }

    window.addEventListener("load", () => __bootstrap(0));
    window.addEventListener("resize", () => __notifyHeightNow());
  </script>

  <script
    src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/marked/marked.min.js';"
  ></script>
  <script
    src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/katex.min.js';"
  ></script>
  <script
    src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/contrib/auto-render.min.js';"
  ></script>
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

        private func htmlEscaped(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
    }
}

private extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(textColor: Color) -> some View {
        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownTextStyle {
                ForegroundColor(textColor)
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
    }
}
