// ============================================================================
// ETAdvancedMarkdownRendererMathJavaScript.swift
// ============================================================================
// ETOS LLM Studio
//
// 数学 Web 渲染 shell 的 JavaScript runtime。
// ============================================================================

import Foundation

extension ETMathWebShellConfiguration {
    nonisolated static func javascriptRuntime(
        enableMarkdown: Bool,
        syntaxHighlightingEnabled: Bool,
        codeCopyText: String,
        codeCopiedText: String,
        codeExpandText: String,
        codeCollapseText: String
    ) -> String {
        """
    const __enableMarkdown = \(enableMarkdown ? "true" : "false");
    const __syntaxHighlightingEnabled = \(syntaxHighlightingEnabled ? "true" : "false");
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

        if (__syntaxHighlightingEnabled && window.hljs) {
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
      const codeReady = !__enableMarkdown || !__syntaxHighlightingEnabled || !!window.hljs;
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
    """
    }
}
