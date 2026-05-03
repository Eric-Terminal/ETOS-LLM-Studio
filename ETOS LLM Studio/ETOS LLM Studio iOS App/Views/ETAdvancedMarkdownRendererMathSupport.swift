// ============================================================================
// ETAdvancedMarkdownRendererMathSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责数学 Web 渲染 shell 的 HTML、CSS、JavaScript 与 payload 序列化。
// ============================================================================

import Foundation
import SwiftUI
import Shared

struct ETMathWebShellConfiguration: Equatable {
        let enableMarkdown: Bool
        let isOutgoing: Bool
        let customTextHex: String?
        let prefersDarkPalette: Bool
        let fontScale: Double

        var htmlDocument: String {
            let defaultTextColor = isOutgoing ? "#FFFFFF" : (prefersDarkPalette ? "#FFFFFF" : "#1C1C1E")
            let textColor = Self.cssRGBA(from: customTextHex, alphaMultiplier: 1) ?? defaultTextColor
            let defaultSecondaryTextColor = isOutgoing
                ? "rgba(255,255,255,0.85)"
                : (prefersDarkPalette ? "rgba(255,255,255,0.82)" : "#3C3C43")
            let secondaryTextColor = Self.cssRGBA(from: customTextHex, alphaMultiplier: 0.85) ?? defaultSecondaryTextColor
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
            let quoteBorderColor = isOutgoing ? "rgba(255,255,255,0.56)" : "rgba(120,120,128,0.48)"
            let bodyFontFamily = Self.cssFontFamily(
                role: .body,
                fallback: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            )
            let emphasisFontFamily = Self.cssFontFamily(
                role: .emphasis,
                fallback: "var(--font-body)"
            )
            let strongFontFamily = Self.cssFontFamily(
                role: .strong,
                fallback: "var(--font-body)"
            )
            let codeFontFamily = Self.cssFontFamily(
                role: .code,
                fallback: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace"
            )
            let codeCopyText = Self.javaScriptStringLiteral(NSLocalizedString("复制", comment: ""))
            let codeCopiedText = Self.javaScriptStringLiteral(NSLocalizedString("已复制", comment: ""))
            let codeExpandText = Self.javaScriptStringLiteral(NSLocalizedString("展开", comment: ""))
            let codeCollapseText = Self.javaScriptStringLiteral(NSLocalizedString("收起", comment: ""))

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
      --font-body: \(bodyFontFamily);
      --font-emphasis: \(emphasisFontFamily);
      --font-strong: \(strongFontFamily);
      --font-code: \(codeFontFamily);
      --font-scale: \(String(format: "%.3f", fontScale));
    }

    html, body {
      margin: 0;
      padding: 0;
      background: transparent;
      color: var(--text);
      width: 100%;
      overflow: hidden;
      font: -apple-system-body;
      font-family: var(--font-body);
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
    }

    #content {
      width: 100%;
      max-width: var(--max-width);
      box-sizing: border-box;
      font-size: calc(1em * var(--font-scale));
      line-height: 1.45;
      word-break: break-word;
      overflow-wrap: anywhere;
      color: var(--text);
    }

    p { margin: 0.25em 0; }
    ul, ol { margin: 0.3em 0; padding-left: 1.25em; }
    li { margin: 0.2em 0; }
    blockquote {
      margin: 0.3em 0;
      padding: 0.05em 0 0.05em 0.82em;
      border-left: 3px solid \(quoteBorderColor);
    }
    blockquote > :first-child { margin-top: 0; }
    blockquote > :last-child { margin-bottom: 0; }
    a { color: var(--link); text-decoration: underline; }
    strong { font-weight: 600; font-family: var(--font-strong); }
    em { font-style: italic; font-family: var(--font-emphasis); }
    code {
      font-family: var(--font-code);
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
    .et-code-actions {
      margin-left: auto;
      display: inline-flex;
      align-items: center;
      gap: 0.35em;
    }
    .et-code-copy {
      border: none;
      padding: 0.18em 0.5em;
      border-radius: 6px;
      background: var(--code-copy-bg);
      color: var(--text);
      font-size: 0.72em;
      line-height: 1.1;
      cursor: pointer;
    }
    .et-code-toggle {
      border: none;
      padding: 0.18em 0.5em;
      border-radius: 6px;
      background: var(--code-copy-bg);
      color: var(--text);
      font-size: 0.72em;
      line-height: 1.1;
      cursor: pointer;
      min-width: 2.8em;
    }
    .et-code-copy[data-copied="true"] {
      background: var(--code-copy-active-bg);
    }
    .et-code-copy:active,
    .et-code-toggle:active {
      transform: translateY(0.5px);
    }
    .et-code-content {
      display: grid;
      grid-template-rows: 1fr;
      overflow: hidden;
      opacity: 1;
      transition: grid-template-rows 220ms ease, opacity 180ms ease;
    }
    .et-code-content > .et-code-body {
      min-height: 0;
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
    .et-code-block.is-collapsed .et-code-header {
      border-bottom-color: transparent;
    }
    .et-code-block.is-collapsed .et-code-content {
      grid-template-rows: 0fr;
      opacity: 0;
    }
    .et-code-block.is-collapsed .et-code-copy {
      display: none;
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
      availableWidth: 1,
      bodyFontFamily: "",
      emphasisFontFamily: "",
      strongFontFamily: "",
      codeFontFamily: ""
    };
    const __codeCollapseState = Object.create(null);

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
      if (!window.mermaid) {
        return;
      }

      const fontFamily = __state.bodyFontFamily || "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif";
      if (window.__etMermaidConfigured && window.__etMermaidConfiguredFontFamily === fontFamily) {
        return;
      }

      const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
      try {
        window.mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme: prefersDark ? "dark" : "default",
          fontFamily
        });
        window.__etMermaidConfigured = true;
        window.__etMermaidConfiguredFontFamily = fontFamily;
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
      button.textContent = \(codeCopyText);
      button.addEventListener("click", async () => {
        const codeText = codeNode ? (codeNode.textContent || "") : "";
        if (!codeText) {
          return;
        }
        try {
          await __copyText(codeText);
          button.dataset.copied = "true";
          button.textContent = \(codeCopiedText);
          if (button.__etCopyTimer) {
            clearTimeout(button.__etCopyTimer);
          }
          button.__etCopyTimer = setTimeout(() => {
            button.textContent = \(codeCopyText);
            button.dataset.copied = "false";
            button.__etCopyTimer = null;
          }, 1400);
        } catch (_) {}
      });
      return button;
    }

    function __hashText(source) {
      let hash = 0;
      for (let index = 0; index < source.length; index += 1) {
        hash = ((hash << 5) - hash + source.charCodeAt(index)) | 0;
      }
      return String(hash >>> 0);
    }

    function __codeBlockStateKey(codeNode, index) {
      const language = __languageLabelFromCodeElement(codeNode).toLowerCase();
      const rawText = (codeNode && codeNode.textContent) ? codeNode.textContent : "";
      const sampled = rawText.length > 2048 ? rawText.slice(0, 2048) : rawText;
      return `${index}:${language}:${sampled.length}:${__hashText(sampled)}`;
    }

    function __setCodeBlockCollapsed(wrapper, collapsed, shouldNotify = true) {
      if (!wrapper) {
        return;
      }

      wrapper.dataset.collapsed = collapsed ? "true" : "false";
      wrapper.classList.toggle("is-collapsed", collapsed);

      const toggleButton = wrapper.querySelector(".et-code-toggle");
      if (toggleButton) {
        toggleButton.textContent = collapsed ? \(codeExpandText) : \(codeCollapseText);
        toggleButton.setAttribute("aria-expanded", collapsed ? "false" : "true");
      }

      if (!shouldNotify) {
        return;
      }

      requestAnimationFrame(() => __notifyHeightNow());
      setTimeout(() => __notifyHeightNow(), 260);
    }

    function __createCodeToggleButton(wrapper, stateKey) {
      const button = document.createElement("button");
      button.className = "et-code-toggle";
      button.type = "button";
      button.addEventListener("click", () => {
        const nextCollapsed = wrapper.dataset.collapsed !== "true";
        __codeCollapseState[stateKey] = nextCollapsed;
        __setCodeBlockCollapsed(wrapper, nextCollapsed);
      });
      return button;
    }

    function __decorateCodeBlocks(container) {
      const codeNodes = container.querySelectorAll("pre > code");
      codeNodes.forEach((codeNode, index) => {
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

        const stateKey = __codeBlockStateKey(codeNode, index);
        const actions = document.createElement("div");
        actions.className = "et-code-actions";

        const copyButton = __createCodeCopyButton(codeNode);
        actions.appendChild(copyButton);

        const toggleButton = __createCodeToggleButton(wrapper, stateKey);
        actions.appendChild(toggleButton);
        header.appendChild(actions);

        const content = document.createElement("div");
        content.className = "et-code-content";

        const body = document.createElement("div");
        body.className = "et-code-body";

        preNode.parentNode.insertBefore(wrapper, preNode);
        wrapper.appendChild(header);
        wrapper.appendChild(content);
        content.appendChild(body);
        body.appendChild(preNode);

        const initialCollapsed = __codeCollapseState[stateKey] === true;
        __setCodeBlockCollapsed(wrapper, initialCollapsed, false);

        content.addEventListener("transitionend", (event) => {
          if (event && (event.propertyName === "grid-template-rows" || event.propertyName === "opacity")) {
            __notifyHeightNow();
          }
        });
      });
    }

    function __setContentWidth(width) {
      const stableWidth = Math.max(1, Math.floor(width || 1));
      document.documentElement.style.setProperty("--max-width", `${stableWidth}px`);
    }

    function __normalizeFontFamily(value) {
      if (typeof value !== "string") {
        return "";
      }
      const trimmed = value.trim();
      return trimmed.length > 0 ? trimmed : "";
    }

    function __setFontFamilies() {
      const rootStyle = document.documentElement.style;
      if (__state.bodyFontFamily) {
        rootStyle.setProperty("--font-body", __state.bodyFontFamily);
      }
      if (__state.emphasisFontFamily) {
        rootStyle.setProperty("--font-emphasis", __state.emphasisFontFamily);
      }
      if (__state.strongFontFamily) {
        rootStyle.setProperty("--font-strong", __state.strongFontFamily);
      }
      if (__state.codeFontFamily) {
        rootStyle.setProperty("--font-code", __state.codeFontFamily);
      }
    }

    function __notifyHeightNow() {
      const content = document.getElementById("content");
      const rectHeight = content ? content.getBoundingClientRect().height : 0;
      const scrollHeight = content ? content.scrollHeight : 0;
      const height = Math.max(rectHeight, scrollHeight, 1);
      const nextHeight = Math.max(1, Math.ceil(height));
      const lastHeight = Number(window.__etLastNotifiedHeight || 0);
      if (Math.abs(lastHeight - nextHeight) < 0.5) {
        return;
      }
      window.__etLastNotifiedHeight = nextHeight;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.etMathHeight) {
        window.webkit.messageHandlers.etMathHeight.postMessage(nextHeight);
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
      const markdownReady = !__enableMarkdown || !!window.marked;
      const mathReady = !!window.renderMathInElement && !!window.katex;
      const codeReady = !__enableMarkdown || !!window.hljs;
      const mermaidReady = !__enableMarkdown || !__rawHasMermaidFence(__state.raw) || !!window.mermaid;
      const allReady = markdownReady && mathReady && codeReady && mermaidReady;

      if (retryCount == 0 || allReady || retryCount >= 80) {
        __render();
      }

      if (allReady || retryCount >= 80) {
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

      const bodyFontFamily = __normalizeFontFamily(payload.bodyFontFamily);
      if (bodyFontFamily) {
        __state.bodyFontFamily = bodyFontFamily;
      }

      const emphasisFontFamily = __normalizeFontFamily(payload.emphasisFontFamily);
      if (emphasisFontFamily) {
        __state.emphasisFontFamily = emphasisFontFamily;
      }

      const strongFontFamily = __normalizeFontFamily(payload.strongFontFamily);
      if (strongFontFamily) {
        __state.strongFontFamily = strongFontFamily;
      }

      const codeFontFamily = __normalizeFontFamily(payload.codeFontFamily);
      if (codeFontFamily) {
        __state.codeFontFamily = codeFontFamily;
      }

      __setContentWidth(__state.availableWidth);
      __setFontFamilies();
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
      __setFontFamilies();
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

        nonisolated fileprivate static func cssFontFamily(role: FontSemanticRole, fallback: String) -> String {
            if FontLibrary.fallbackScope == .character {
                let customFamilies = FontLibrary.fallbackPostScriptNames(for: role)
                    .filter { !$0.isEmpty }
                    .map(cssFamilyLiteral)
                if !customFamilies.isEmpty {
                    return (customFamilies + [fallback]).joined(separator: ", ")
                }
                return fallback
            }
            if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: ""),
               !postScriptName.isEmpty {
                return "\(cssFamilyLiteral(postScriptName)), \(fallback)"
            }
            return fallback
        }

        nonisolated static func cssFamilyLiteral(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        }

        nonisolated fileprivate static func javaScriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }

        nonisolated private static func cssRGBA(from hexRGBA: String?, alphaMultiplier: Double) -> String? {
            guard let hexRGBA else { return nil }
            let parsedColor = ChatAppearanceColorCodec.color(from: hexRGBA, fallback: .clear)
            guard let components = ChatAppearanceColorCodec.rgbaComponents(from: parsedColor) else { return nil }
            let alpha = min(max(components.alpha * alphaMultiplier, 0), 1)
            let red = Int((components.red * 255).rounded())
            let green = Int((components.green * 255).rounded())
            let blue = Int((components.blue * 255).rounded())
            return "rgba(\(red),\(green),\(blue),\(String(format: "%.3f", alpha)))"
        }
    }
