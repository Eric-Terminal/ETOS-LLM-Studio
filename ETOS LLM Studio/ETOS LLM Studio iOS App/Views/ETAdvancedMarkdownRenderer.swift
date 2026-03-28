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
    @Environment(\.colorScheme) private var colorScheme

    private var shouldUseWebRenderer: Bool {
        enableAdvancedRenderer && (containsMathContent || containsMermaidContent)
    }

    private var containsMathContent: Bool {
        enableMathRendering && ETMathContentParser.containsMath(in: content)
    }

    private var containsMermaidContent: Bool {
        enableMarkdown && Self.containsMermaidFence(in: content)
    }

    var body: some View {
        let normalizedContent = Self.normalizedMarkdownForStreaming(content)
        if shouldUseWebRenderer {
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

    private static func containsMermaidFence(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            let infoToken = fence.tail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased()
            if infoToken == "mermaid" || infoToken == "mmd" {
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private func baseTextView(_ text: String) -> some View {
        if enableMarkdown {
            let textColor: Color = isOutgoing ? .white : .primary
            Markdown(text)
                .etChatMarkdownBaseStyle(
                    textColor: textColor,
                    isOutgoing: isOutgoing,
                    prefersDarkPalette: colorScheme == .dark
                )
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
            let codeKeywordColor = isOutgoing ? "rgba(255,255,255,0.96)" : "#8E44AD"
            let codeStringColor = isOutgoing ? "#D4F5FF" : "#1A9445"
            let codeNumberColor = isOutgoing ? "#FFE5C6" : "#D46B17"
            let codeCommentColor = isOutgoing ? "rgba(255,255,255,0.7)" : "#8E8E93"
            let codeTypeColor = isOutgoing ? "#E9F6FF" : "#0A84A8"
            let codePunctuationColor = isOutgoing ? "rgba(255,255,255,0.88)" : "#4B5563"
            let codeCopyButtonBackground = isOutgoing ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.05)"
            let codeCopyButtonActiveBackground = isOutgoing ? "rgba(255,255,255,0.2)" : "rgba(0,0,0,0.1)"
            let codeBlockBackgroundColor = isOutgoing ? "rgba(255,255,255,0.16)" : "rgba(127,127,127,0.16)"
            let codeHeaderBackgroundColor = isOutgoing ? "rgba(255,255,255,0.2)" : "rgba(127,127,127,0.2)"
            let codeBorderColor = isOutgoing ? "rgba(255,255,255,0.28)" : "rgba(127,127,127,0.3)"

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
      --code-keyword: \(codeKeywordColor);
      --code-string: \(codeStringColor);
      --code-number: \(codeNumberColor);
      --code-comment: \(codeCommentColor);
      --code-type: \(codeTypeColor);
      --code-punctuation: \(codePunctuationColor);
      --code-copy-bg: \(codeCopyButtonBackground);
      --code-copy-active-bg: \(codeCopyButtonActiveBackground);
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
      border: 1px solid \(codeBorderColor);
      background: \(codeBlockBackgroundColor);
      -webkit-backdrop-filter: blur(6px);
      backdrop-filter: blur(6px);
      max-width: 100%;
    }
    .et-code-header {
      min-height: 1.7em;
      display: flex;
      align-items: center;
      padding: 0.22em 0.65em;
      background: \(codeHeaderBackgroundColor);
      border-bottom: 1px solid \(codeBorderColor);
      -webkit-backdrop-filter: blur(4px);
      backdrop-filter: blur(4px);
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
    .et-code-copy {
      border: none;
      margin-left: auto;
      padding: 0.18em 0.5em;
      border-radius: 6px;
      background: var(--code-copy-bg);
      color: var(--text);
      font-size: 0.72em;
      line-height: 1.1;
      cursor: pointer;
    }
    .et-code-copy[data-copied="true"] {
      background: var(--code-copy-active-bg);
    }
    .et-code-copy:active {
      transform: translateY(0.5px);
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
    .hljs-keyword,
    .hljs-selector-tag,
    .hljs-literal,
    .hljs-built_in {
      color: var(--code-keyword);
    }
    .hljs-string,
    .hljs-attr,
    .hljs-template-variable {
      color: var(--code-string);
    }
    .hljs-number,
    .hljs-symbol {
      color: var(--code-number);
    }
    .hljs-comment,
    .hljs-quote {
      color: var(--code-comment);
    }
    .hljs-title,
    .hljs-type {
      color: var(--code-type);
    }
    .hljs-punctuation,
    .hljs-operator {
      color: var(--code-punctuation);
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

    .et-mermaid-scroll {
      margin: 0.3em 0;
      overflow-x: auto;
      overflow-y: hidden;
      -webkit-overflow-scrolling: touch;
      max-width: 100%;
    }
    .et-mermaid-block {
      width: max-content;
      min-width: 100%;
      max-width: none;
    }
    .et-mermaid-block .mermaid {
      width: max-content;
      min-width: 100%;
    }
    .et-mermaid-block svg {
      display: block;
      max-width: none;
      height: auto;
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

    function __rawHasMermaidFence(raw) {
      if (!raw) {
        return false;
      }
      return /(^|\\n)\\s*(```|~~~)\\s*(mermaid|mmd)(\\s+[^\\n]*)?(\\n|$)/i.test(raw);
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

    function __isMermaidLanguage(language) {
      const normalized = (language || "").trim().toLowerCase();
      return normalized === "mermaid" || normalized === "mmd";
    }

    function __prepareMermaidBlocks(container) {
      const codeNodes = container.querySelectorAll("pre > code");
      let index = 0;
      codeNodes.forEach((codeNode) => {
        if (!__isMermaidLanguage(__languageLabelFromCodeElement(codeNode))) {
          return;
        }
        const preNode = codeNode.parentElement;
        if (!preNode || !preNode.parentNode) {
          return;
        }

        const source = (codeNode.textContent || "").trim();
        if (!source) {
          return;
        }

        const scroll = document.createElement("div");
        scroll.className = "et-mermaid-scroll";
        const block = document.createElement("div");
        block.className = "et-mermaid-block";
        const mermaidNode = document.createElement("div");
        mermaidNode.className = "mermaid";
        mermaidNode.setAttribute("data-et-mermaid-id", `et-mermaid-${Date.now()}-${index}`);
        mermaidNode.textContent = source;
        index += 1;

        block.appendChild(mermaidNode);
        scroll.appendChild(block);

        preNode.parentNode.insertBefore(scroll, preNode);
        preNode.remove();
      });
    }

    function __ensureMermaidConfigured() {
      if (!window.mermaid || window.__etMermaidConfigured) {
        return;
      }

      const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
      try {
        window.mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme: prefersDark ? "dark" : "default",
          fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        });
        window.__etMermaidConfigured = true;
      } catch (_) {}
    }

    function __setMermaidFallback(node, source) {
      const fallback = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = source;
      fallback.appendChild(code);
      node.innerHTML = "";
      node.appendChild(fallback);
    }

    async function __renderMermaidBlocks(container) {
      if (!window.mermaid) {
        return;
      }
      __ensureMermaidConfigured();
      const nodes = container.querySelectorAll(".mermaid[data-et-mermaid-id]");
      for (const node of nodes) {
        const source = (node.textContent || "").trim();
        if (!source) {
          continue;
        }
        const renderId = node.getAttribute("data-et-mermaid-id")
          || `et-mermaid-${Math.random().toString(36).slice(2)}`;
        try {
          const result = await window.mermaid.render(renderId, source);
          node.innerHTML = result.svg;
        } catch (_) {
          __setMermaidFallback(node, source);
        }
      }
    }

    async function __copyText(content) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(content);
        return;
      }
      const textArea = document.createElement("textarea");
      textArea.value = content;
      textArea.style.position = "fixed";
      textArea.style.top = "-2000px";
      textArea.style.left = "-2000px";
      document.body.appendChild(textArea);
      textArea.focus();
      textArea.select();
      document.execCommand("copy");
      document.body.removeChild(textArea);
    }

    function __createCodeCopyButton(codeNode) {
      const button = document.createElement("button");
      button.className = "et-code-copy";
      button.type = "button";
      button.textContent = "复制";
      button.addEventListener("click", async () => {
        const codeText = codeNode ? (codeNode.textContent || "") : "";
        if (!codeText) {
          return;
        }
        try {
          await __copyText(codeText);
          button.dataset.copied = "true";
          button.textContent = "已复制";
          if (button.__etCopyTimer) {
            clearTimeout(button.__etCopyTimer);
          }
          button.__etCopyTimer = setTimeout(() => {
            button.textContent = "复制";
            button.dataset.copied = "false";
            button.__etCopyTimer = null;
          }, 1400);
        } catch (_) {}
      });
      return button;
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

        if (window.hljs) {
          try {
            window.hljs.highlightElement(codeNode);
          } catch (_) {}
        }

        const copyButton = __createCodeCopyButton(codeNode);
        header.appendChild(copyButton);

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
        __prepareMermaidBlocks(container);
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

      __renderMermaidBlocks(container)
        .catch(() => {})
        .then(() => __notifyHeightNow());
    }

    function __scheduleBootstrap(retryCount = 0) {
      __render();

      const markdownReady = !__enableMarkdown || !!window.marked;
      const mathReady = !!window.renderMathInElement && !!window.katex;
      const codeReady = !__enableMarkdown || !!window.hljs;
      const mermaidReady = !__enableMarkdown || !__rawHasMermaidFence(__state.raw) || !!window.mermaid;
      if ((markdownReady && mathReady && codeReady && mermaidReady) || retryCount >= 80) {
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
    src="https://cdn.jsdelivr.net/npm/highlight.js@11.11.1/lib/highlight.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/highlight.js@11.11.1/lib/highlight.min.js';"
  ></script>
  <script
    src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/katex.min.js';"
  ></script>
  <script
    src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/katex@0.16.11/dist/contrib/auto-render.min.js';"
  ></script>
  <script
    src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"
    onerror="this.onerror=null;this.src='https://unpkg.com/mermaid@11/dist/mermaid.min.js';"
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
    func etChatMarkdownBaseStyle(textColor: Color, isOutgoing: Bool, prefersDarkPalette: Bool) -> some View {
        let codeBlockBackground = isOutgoing
            ? Color.white.opacity(0.16)
            : Color.primary.opacity(0.09)
        let codeHeaderBackground = isOutgoing
            ? Color.white.opacity(0.2)
            : Color.primary.opacity(0.11)
        let codeBorderColor = isOutgoing
            ? Color.white.opacity(0.24)
            : Color.primary.opacity(0.16)
        let codeHeaderTextColor = isOutgoing
            ? Color.white.opacity(0.9)
            : Color.secondary

        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownCodeSyntaxHighlighter(
                ETCodeSyntaxHighlighter(
                    baseColor: textColor,
                    isOutgoing: isOutgoing,
                    prefersDarkPalette: prefersDarkPalette
                )
            )
            .markdownTextStyle {
                ForegroundColor(textColor)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(configuration.language?.isEmpty == false ? (configuration.language ?? "代码") : "代码")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(codeHeaderTextColor)

                        Spacer(minLength: 8)

                        if ETCodePreviewSupport.canPreview(configuration.language) {
                            ETCodePreviewButton(
                                content: configuration.content,
                                language: configuration.language,
                                tintColor: codeHeaderTextColor
                            )
                        }

                        if ETCodeClipboard.supportsCopy {
                            ETCodeCopyButton(
                                content: configuration.content,
                                normalColor: codeHeaderTextColor,
                                successColor: isOutgoing ? Color.white : Color.green
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            Rectangle().fill(codeHeaderBackground)
                        }
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
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(codeBlockBackground)
                    }
                }
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

private enum ETCodeClipboard {
    static var supportsCopy: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func copy(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #endif
    }
}

private struct ETCodeCopyButton: View {
    let content: String
    let normalColor: Color
    let successColor: Color

    @State private var didCopy = false

    var body: some View {
        Button {
            ETCodeClipboard.copy(content)
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif

            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(didCopy ? successColor : normalColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制代码")
    }
}

private enum ETCodePreviewSupport {
    private static let previewableLanguages: Set<String> = [
        "html", "htm", "xhtml", "xml", "svg"
    ]
    private static let previewResetStyle = """
<style id="et-preview-reset">
  html, body {
    margin: 0 !important;
    padding: 0 !important;
    min-height: 100%;
    width: 100%;
  }
  body {
    overflow: auto !important;
    -webkit-overflow-scrolling: touch;
  }
  body > :first-child {
    margin-top: 0 !important;
  }
  body > :last-child {
    margin-bottom: 0 !important;
  }
</style>
"""

    static func canPreview(_ language: String?) -> Bool {
        previewableLanguages.contains(normalizedLanguage(language))
    }

    static func htmlDocument(content: String, language: String?) -> String {
        let normalized = normalizedLanguage(language)
        switch normalized {
        case "svg":
            return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: #FFFFFF;
      color: #1C1C1E;
      width: 100%;
      min-height: 100%;
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
    }
    .et-svg-wrap {
      min-height: 100vh;
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding: 0;
      box-sizing: border-box;
    }
    .et-svg-wrap svg {
      max-width: 100%;
      height: auto;
    }
  </style>
</head>
<body>
  <div class="et-svg-wrap">
    \(content)
  </div>
</body>
</html>
"""
        case "html", "htm", "xhtml":
            return wrappedHTMLIfNeeded(content)
        default:
            return content
        }
    }

    private static func wrappedHTMLIfNeeded(_ content: String) -> String {
        let lowercased = content.lowercased()
        if lowercased.contains("<html") || lowercased.contains("<!doctype") {
            return injectingPreviewResetStyle(into: content)
        }
        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  \(previewResetStyle)
</head>
<body>
\(content)
</body>
</html>
"""
    }

    private static func injectingPreviewResetStyle(into html: String) -> String {
        if html.contains("id=\"et-preview-reset\"") {
            return html
        }

        if let headCloseRange = html.range(of: "</head>", options: [.caseInsensitive]) {
            var output = html
            output.insert(contentsOf: "\n\(previewResetStyle)\n", at: headCloseRange.lowerBound)
            return output
        }

        if let htmlOpenRange = html.range(of: "<html", options: [.caseInsensitive]),
           let htmlTagClose = html[htmlOpenRange.lowerBound...].firstIndex(of: ">") {
            var output = html
            let insertIndex = output.index(after: htmlTagClose)
            output.insert(contentsOf: "\n<head>\n\(previewResetStyle)\n</head>\n", at: insertIndex)
            return output
        }

        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  \(previewResetStyle)
</head>
<body>
\(html)
</body>
</html>
"""
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct ETCodePreviewButton: View {
    let content: String
    let language: String?
    let tintColor: Color

    @State private var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            Image(systemName: "safari")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("预览代码")
        .fullScreenCover(isPresented: $showingPreview) {
            ETCodePreviewSheet(
                content: content,
                language: language
            )
        }
    }
}

private struct ETCodePreviewSheet: View {
    let content: String
    let language: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ETCodePreviewWebView(
                htmlContent: ETCodePreviewSupport.htmlDocument(content: content, language: language)
            )
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private struct ETCodePreviewWebView: UIViewRepresentable {
    let htmlContent: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isUserInteractionEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoadedHTML != htmlContent else { return }
        context.coordinator.lastLoadedHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }

    final class Coordinator {
        var lastLoadedHTML: String?
    }
}

private enum ETCodeLanguage: Hashable {
    case swift
    case javascript
    case typescript
    case python
    case ruby
    case bash
    case cstyle
    case sql
    case data
    case markup
    case plain

    init(rawLanguage: String?) {
        let raw = (rawLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "swift":
            self = .swift
        case "js", "jsx", "javascript", "mjs", "cjs":
            self = .javascript
        case "ts", "tsx", "typescript":
            self = .typescript
        case "py", "python":
            self = .python
        case "rb", "ruby":
            self = .ruby
        case "sh", "bash", "zsh", "shell":
            self = .bash
        case "c", "h", "cpp", "cc", "cxx", "hpp", "objective-c", "objc", "objc++", "java", "kotlin", "kt", "go", "rust", "rs":
            self = .cstyle
        case "sql":
            self = .sql
        case "json", "yaml", "yml", "toml":
            self = .data
        case "html", "xml", "svg", "xhtml":
            self = .markup
        default:
            self = .plain
        }
    }

    var keywordMatchOptions: NSRegularExpression.Options {
        self == .sql ? [.caseInsensitive] : []
    }

    var keywords: Set<String> {
        Self.keywordTable[self] ?? []
    }

    var supportsSlashComment: Bool {
        Self.slashCommentLanguages.contains(self)
    }

    var supportsHashComment: Bool {
        Self.hashCommentLanguages.contains(self)
    }

    var supportsBacktickString: Bool {
        Self.backtickStringLanguages.contains(self)
    }

    var supportsTypeNameHighlight: Bool {
        Self.typeNameLanguages.contains(self)
    }

    var supportsFunctionHighlight: Bool {
        self != .data
    }

    var supportsPropertyHighlight: Bool {
        Self.propertyLanguages.contains(self)
    }

    private static let slashCommentLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .cstyle]
    private static let hashCommentLanguages: Set<ETCodeLanguage> = [.python, .ruby, .bash, .data]
    private static let backtickStringLanguages: Set<ETCodeLanguage> = [.javascript, .typescript]
    private static let typeNameLanguages: Set<ETCodeLanguage> = [.swift, .typescript, .cstyle]
    private static let propertyLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .python, .ruby, .cstyle]

    private static let keywordTable: [ETCodeLanguage: Set<String>] = [
        .swift: [
            "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
            "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
            "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static",
            "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"
        ],
        .javascript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true",
            "try", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        .typescript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "interface", "let", "new", "null", "return", "super", "switch", "this", "throw",
            "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "implements"
        ],
        .python: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "elif", "else",
            "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None",
            "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
        ],
        .ruby: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
            "until", "when", "while", "yield"
        ],
        .bash: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
            "then", "time", "until", "while"
        ],
        .cstyle: [
            "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "false", "final", "float", "for", "if", "import",
            "inline", "int", "interface", "let", "long", "namespace", "new", "null", "private", "protected",
            "public", "return", "short", "signed", "static", "struct", "switch", "template", "this", "throw",
            "true", "try", "typedef", "typename", "union", "unsigned", "using", "var", "virtual", "void",
            "volatile", "while"
        ],
        .sql: [
            "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner",
            "outer", "on", "as", "group", "by", "order", "limit", "having", "and", "or", "not", "null",
            "is", "in", "exists", "distinct", "create", "table", "alter", "drop", "values", "set"
        ],
        .data: ["true", "false", "null", "yes", "no", "on", "off"]
    ]
}

private enum ETCodeTheme {
    case outgoing
    case atomOneDark
    case atomOneLight

    static func resolve(isOutgoing: Bool, prefersDarkPalette: Bool) -> ETCodeTheme {
        if isOutgoing { return .outgoing }
        return prefersDarkPalette ? .atomOneDark : .atomOneLight
    }
}

private struct ETCodeHighlightPalette {
    let plain: Color
    let comment: Color
    let string: Color
    let number: Color
    let keyword: Color
    let typeName: Color
    let function: Color
    let property: Color
    let tag: Color
    let attribute: Color
    let punctuation: Color
    let operatorSymbol: Color

    init(baseColor: Color, theme: ETCodeTheme) {
        plain = baseColor
        switch theme {
        case .outgoing:
            comment = Color.white.opacity(0.7)
            string = Color(red: 0.84, green: 0.97, blue: 1.0)
            number = Color(red: 1.0, green: 0.9, blue: 0.78)
            keyword = Color.white.opacity(0.96)
            typeName = Color(red: 0.93, green: 0.97, blue: 1.0)
            function = Color(red: 0.78, green: 0.9, blue: 1.0)
            property = Color(red: 1.0, green: 0.82, blue: 0.86)
            tag = Color(red: 1.0, green: 0.83, blue: 0.88)
            attribute = Color(red: 1.0, green: 0.92, blue: 0.8)
            punctuation = Color.white.opacity(0.88)
            operatorSymbol = Color.white.opacity(0.9)
        case .atomOneDark:
            comment = Self.color(hex: 0x5C6370)
            string = Self.color(hex: 0x98C379)
            number = Self.color(hex: 0xD19A66)
            keyword = Self.color(hex: 0xC678DD)
            typeName = Self.color(hex: 0xE5C07B)
            function = Self.color(hex: 0x61AFEF)
            property = Self.color(hex: 0xE06C75)
            tag = Self.color(hex: 0xE06C75)
            attribute = Self.color(hex: 0xD19A66)
            punctuation = Self.color(hex: 0xABB2BF)
            operatorSymbol = Self.color(hex: 0x56B6C2)
        case .atomOneLight:
            comment = Self.color(hex: 0xA0A1A7)
            string = Self.color(hex: 0x50A14F)
            number = Self.color(hex: 0x986801)
            keyword = Self.color(hex: 0xA626A4)
            typeName = Self.color(hex: 0xC18401)
            function = Self.color(hex: 0x4078F2)
            property = Self.color(hex: 0xE45649)
            tag = Self.color(hex: 0xE45649)
            attribute = Self.color(hex: 0x986801)
            punctuation = Self.color(hex: 0x383A42)
            operatorSymbol = Self.color(hex: 0x0184BC)
        }
    }

    private static func color(hex: UInt32) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

private struct ETCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private enum TokenKind {
        case plain
        case comment
        case string
        case number
        case keyword
        case typeName
        case function
        case property
        case tag
        case attribute
        case punctuation
        case operatorSymbol
    }

    let baseColor: Color
    let isOutgoing: Bool
    let prefersDarkPalette: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard !code.isEmpty else { return Text("") }

        let nsCode = code as NSString
        let length = nsCode.length
        guard length > 0, length <= 12_000 else {
            return Text(code).foregroundColor(baseColor)
        }

        let language = ETCodeLanguage(rawLanguage: language)
        let theme = ETCodeTheme.resolve(isOutgoing: isOutgoing, prefersDarkPalette: prefersDarkPalette)
        let palette = ETCodeHighlightPalette(baseColor: baseColor, theme: theme)

        var priorities = Array(repeating: Int.min, count: length)
        var kinds = Array(repeating: TokenKind.plain, count: length)

        func apply(
            pattern: String,
            options: NSRegularExpression.Options = [],
            kind: TokenKind,
            priority: Int
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return
            }
            let full = NSRange(location: 0, length: length)
            expression.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound, range.length > 0 else { return }
                let lowerBound = max(0, range.location)
                let upperBound = min(length, range.location + range.length)
                guard lowerBound < upperBound else { return }
                for index in lowerBound..<upperBound where priority >= priorities[index] {
                    priorities[index] = priority
                    kinds[index] = kind
                }
            }
        }

        if language.supportsSlashComment {
            apply(pattern: #"//.*$"#, options: [.anchorsMatchLines], kind: .comment, priority: 120)
            apply(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment, priority: 120)
        }
        if language.supportsHashComment {
            apply(pattern: #"(?m)#.*$"#, kind: .comment, priority: 120)
        }
        if language == .sql {
            apply(pattern: #"(?m)--.*$"#, kind: .comment, priority: 120)
        }
        if language == .markup {
            apply(pattern: #"<!--[\s\S]*?-->"#, kind: .comment, priority: 120)
            apply(pattern: #"</?[A-Za-z][A-Za-z0-9:-]*"#, kind: .tag, priority: 98)
            apply(pattern: #"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#, kind: .attribute, priority: 96)
        }

        apply(pattern: #""([^"\\]|\\.)*""#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        apply(pattern: #"'([^'\\]|\\.)*'"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        if language.supportsBacktickString {
            apply(pattern: #"`([^`\\]|\\.|[\r\n])*`"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        }

        apply(pattern: #"\b0x[0-9A-Fa-f]+\b"#, kind: .number, priority: 90)
        apply(pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number, priority: 90)

        if !language.keywords.isEmpty {
            let joined = language.keywords
                .sorted()
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            apply(pattern: "\\b(?:\(joined))\\b", options: language.keywordMatchOptions, kind: .keyword, priority: 100)
        }

        if language.supportsTypeNameHighlight {
            apply(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .typeName, priority: 82)
        }
        if language.supportsFunctionHighlight {
            apply(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, kind: .function, priority: 80)
        }
        if language.supportsPropertyHighlight {
            apply(pattern: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*\b"#, kind: .property, priority: 79)
        }

        apply(
            pattern: #"(?:==|!=|<=|>=|=>|->|<-|\+\+|--|\+=|-=|\*=|/=|%=|&&|\|\||<<|>>|[+\-*/%=!<>|&~^?:])"#,
            kind: .operatorSymbol,
            priority: 60
        )
        apply(pattern: #"[{}\[\]();,.:]"#, kind: .punctuation, priority: 56)

        var result = Text("")
        var segmentStart = 0
        var currentKind = kinds[0]

        for index in 1...length {
            let reachedEnd = index == length
            let kindChanged = !reachedEnd && kinds[index] != currentKind
            if reachedEnd || kindChanged {
                let range = NSRange(location: segmentStart, length: index - segmentStart)
                let segment = nsCode.substring(with: range)
                result = result + Text(segment).foregroundColor(color(for: currentKind, palette: palette))
                if !reachedEnd {
                    segmentStart = index
                    currentKind = kinds[index]
                }
            }
        }

        return result
    }

    private func color(for token: TokenKind, palette: ETCodeHighlightPalette) -> Color {
        switch token {
        case .plain:
            return palette.plain
        case .comment:
            return palette.comment
        case .string:
            return palette.string
        case .number:
            return palette.number
        case .keyword:
            return palette.keyword
        case .typeName:
            return palette.typeName
        case .function:
            return palette.function
        case .property:
            return palette.property
        case .tag:
            return palette.tag
        case .attribute:
            return palette.attribute
        case .punctuation:
            return palette.punctuation
        case .operatorSymbol:
            return palette.operatorSymbol
        }
    }
}
