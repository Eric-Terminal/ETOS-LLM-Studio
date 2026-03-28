// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETAdvancedMarkdownRenderer 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

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
        let normalizedContent = Self.normalizedMarkdownForStreaming(content)
        if shouldUseMathWebRenderer {
            ETMathWebMarkdownView(
                content: normalizedContent,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing
            )
        } else {
            baseTextView(normalizedContent)
        }
    }

    private static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var openedFence: (marker: Character, count: Int)?

        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            if let currentFence = openedFence {
                let isClosingFence = currentFence.marker == fence.marker
                    && fence.count >= currentFence.count
                    && fence.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isClosingFence {
                    openedFence = nil
                }
            } else {
                openedFence = (marker: fence.marker, count: fence.count)
            }
        }

        guard let openedFence else { return text }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if text.hasSuffix("\n") {
            return text + closingFence
        }
        return text + "\n" + closingFence
    }

    private static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        return (marker: marker, count: count, tail: tail)
    }

    @ViewBuilder
    private func baseTextView(_ text: String) -> some View {
        if enableMarkdown {
            let textColor: Color = isOutgoing ? .white : .primary
            Markdown(text)
                .etChatMarkdownBaseStyle(textColor: textColor, isOutgoing: isOutgoing)
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
        let payload = Payload(content: content, availableWidth: stableWidth)
        let shellConfiguration = ShellConfiguration(
            enableMarkdown: enableMarkdown,
            isOutgoing: isOutgoing
        )
        context.coordinator.render(
            payload,
            shellConfiguration: shellConfiguration,
            on: webView
        )
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etMathHeight"

        @Binding var renderedHeight: CGFloat
        var lastPayload: Payload?
        var lastShellConfiguration: ShellConfiguration?
        var pendingPayload: Payload?
        var isShellLoaded = false

        init(renderedHeight: Binding<CGFloat>) { self._renderedHeight = renderedHeight }

        func render(
            _ payload: Payload,
            shellConfiguration: ShellConfiguration,
            on webView: WKWebView
        ) {
            let shouldReloadShell = lastShellConfiguration != shellConfiguration || !isShellLoaded
            guard lastPayload != payload || shouldReloadShell else { return }

            lastPayload = payload
            pendingPayload = payload

            if shouldReloadShell {
                lastShellConfiguration = shellConfiguration
                isShellLoaded = false
                webView.loadHTMLString(shellConfiguration.htmlDocument, baseURL: nil)
                return
            }

            applyPendingPayloadIfPossible(on: webView)
        }

        private func applyPendingPayloadIfPossible(on webView: WKWebView) {
            guard isShellLoaded, let payload = pendingPayload else { return }
            pendingPayload = nil
            webView.evaluateJavaScript(payload.javaScriptInvocation) { _, error in
                if error != nil {
                    self.pendingPayload = payload
                }
            }
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
            isShellLoaded = true
            applyPendingPayloadIfPossible(on: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoaded = false
        }
    }

    struct ShellConfiguration: Equatable {
        let enableMarkdown: Bool
        let isOutgoing: Bool

        var htmlDocument: String {
            let textColor = isOutgoing ? "#FFFFFF" : "#1C1C1E"
            let secondaryTextColor = isOutgoing ? "rgba(255,255,255,0.85)" : "#3C3C43"
            let linkColor = isOutgoing ? "rgba(255,255,255,0.95)" : "#0A84FF"

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
      --max-width: 1px;
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
    .et-code-block {
      margin: 0.4em 0;
      border-radius: 11px;
      overflow: hidden;
      border: 1px solid rgba(127,127,127,0.28);
      background: rgba(127,127,127,0.12);
      max-width: 100%;
    }
    .et-code-header {
      min-height: 1.7em;
      display: flex;
      align-items: center;
      padding: 0.22em 0.65em;
      background: rgba(127,127,127,0.16);
      border-bottom: 1px solid rgba(127,127,127,0.24);
    }
    .et-code-header:empty {
      display: none;
    }
    .et-code-language {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      font-size: 0.76em;
      letter-spacing: 0.02em;
      opacity: 0.9;
    }
    pre {
      margin: 0;
      padding: 0.62em 0.72em;
      border-radius: 0;
      background: transparent;
      overflow-x: visible;
      -webkit-overflow-scrolling: auto;
    }
    .et-code-body {
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
      max-width: 100%;
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
  <div id="content"></div>

  <script>
    const __enableMarkdown = \(enableMarkdown ? "true" : "false");
    const __state = {
      raw: "",
      availableWidth: 1
    };

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
      const escaped = __escapeHTML(__state.raw).replaceAll("\\n", "<br/>");
      container.innerHTML = escaped;
    }

    function __languageLabelFromCodeElement(codeElement) {
      if (!codeElement) {
        return "";
      }
      for (const className of codeElement.classList) {
        if (!className.startsWith("language-")) {
          continue;
        }
        const language = className.slice("language-".length).trim();
        if (language) {
          return language;
        }
      }
      return (codeElement.getAttribute("data-language") || "").trim();
    }

    function __decorateCodeBlocks(container) {
      const codeNodes = container.querySelectorAll("pre > code");
      codeNodes.forEach((codeNode) => {
        const preNode = codeNode.parentElement;
        if (!preNode || !preNode.parentNode) {
          return;
        }
        const preParent = preNode.parentElement;
        if (preParent && preParent.classList.contains("et-code-body")) {
          return;
        }

        const wrapper = document.createElement("div");
        wrapper.className = "et-code-block";

        const header = document.createElement("div");
        header.className = "et-code-header";

        const language = __languageLabelFromCodeElement(codeNode);
        if (language) {
          const languageTag = document.createElement("span");
          languageTag.className = "et-code-language";
          languageTag.textContent = language;
          header.appendChild(languageTag);
        }

        const body = document.createElement("div");
        body.className = "et-code-body";

        preNode.parentNode.insertBefore(wrapper, preNode);
        wrapper.appendChild(header);
        wrapper.appendChild(body);
        body.appendChild(preNode);
      });
    }

    function __setContentWidth(width) {
      const stableWidth = Math.max(1, Math.floor(width || 1));
      document.documentElement.style.setProperty("--max-width", `${stableWidth}px`);
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
      const raw = __state.raw;
      const rawHasMath = raw.includes("$$") || raw.includes("\\\\(") || raw.includes("\\\\[");

      if (__enableMarkdown && window.marked) {
        const tokenized = __tokenizeDisplayMath(raw);
        container.innerHTML = window.marked.parse(tokenized.markdown, {
          breaks: !rawHasMath,
          gfm: true
        });
        __renderMathBlocks(container, tokenized.blocks);
      } else if (!__enableMarkdown) {
        __setFallbackContent();
      } else {
        __setFallbackContent();
      }

      __decorateCodeBlocks(container);
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

    function __scheduleBootstrap(retryCount = 0) {
      __render();

      const markdownReady = !__enableMarkdown || !!window.marked;
      const mathReady = !!window.renderMathInElement && !!window.katex;
      if ((markdownReady && mathReady) || retryCount >= 80) {
        return;
      }

      if (window.__etBootstrapTimer) {
        clearTimeout(window.__etBootstrapTimer);
      }
      window.__etBootstrapTimer = setTimeout(() => {
        window.__etBootstrapTimer = null;
        __scheduleBootstrap(retryCount + 1);
      }, 50);
    }

    window.__etApplyPayload = function(payload) {
      if (!payload || typeof payload !== "object") {
        return;
      }

      if (payload.content == null) {
        __state.raw = "";
      } else if (typeof payload.content === "string") {
        __state.raw = payload.content;
      } else {
        __state.raw = String(payload.content);
      }

      const numericWidth = Number(payload.availableWidth);
      if (Number.isFinite(numericWidth) && numericWidth > 0) {
        __state.availableWidth = numericWidth;
      }

      __setContentWidth(__state.availableWidth);
      __scheduleBootstrap(0);
    }

    if (window.ResizeObserver) {
      const observer = new ResizeObserver(() => __notifyHeightNow());
      const content = document.getElementById("content");
      if (content) {
        observer.observe(content);
      }
    }

    window.addEventListener("load", () => {
      __setContentWidth(__state.availableWidth);
      __scheduleBootstrap(0);
    });
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
    }

    struct Payload: Equatable {
        let content: String
        let availableWidth: CGFloat

        var javaScriptInvocation: String {
            let widthString = String(format: "%.0f", availableWidth)
            let contentJSON = Self.jsonStringLiteral(content)
            return """
window.__etApplyPayload && window.__etApplyPayload({
  content: \(contentJSON),
  availableWidth: \(widthString)
});
window.__etNotifyHeight && window.__etNotifyHeight();
"""
        }

        private static func jsonStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }
    }
}

private extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(textColor: Color, isOutgoing: Bool) -> some View {
        let codeBlockBackground = isOutgoing
            ? Color.white.opacity(0.12)
            : Color.primary.opacity(0.06)
        let codeHeaderBackground = isOutgoing
            ? Color.white.opacity(0.14)
            : Color.primary.opacity(0.05)
        let codeBorderColor = isOutgoing
            ? Color.white.opacity(0.2)
            : Color.primary.opacity(0.12)
        let codeHeaderTextColor = isOutgoing
            ? Color.white.opacity(0.9)
            : Color.secondary

        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownTextStyle {
                ForegroundColor(textColor)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    if let language = configuration.language, !language.isEmpty {
                        Text(language)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(codeHeaderTextColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(codeHeaderBackground)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .relativeLineSpacing(.em(0.15))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.9))
                                ForegroundColor(textColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(codeBorderColor, lineWidth: 1)
                )
                .markdownMargin(top: .em(0.2), bottom: .em(0.75))
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
