import ETOSCore
import Foundation

/// HTML 和 JSON 全部在后台生成。消息只能作为数据进入脚本，不得拼入可执行源码或样式。
struct MacAdvancedMarkdownDocument: Sendable {
    let id = UUID()
    let html: String

    struct Style: Equatable, Sendable, Encodable {
        let dark: Bool
        let pointSize: Double
        let lineSpacing: Double
        let bodyFont: String?
        let emphasisFont: String?
        let strongFont: String?
        let codeFont: String?
        let bodyColor: String
        let emphasisColor: String
        let strongColor: String
        let codeColor: String
    }

    private struct Payload: Encodable {
        let source: ETAdvancedMarkdownSource
        let style: Style
        let copy: String
        let copied: String
        let expand: String
        let collapse: String
    }

    init(source: ETAdvancedMarkdownSource, style: Style) throws {
        let payload = Payload(source: source, style: style, copy: NSLocalizedString("复制代码", comment: ""),
            copied: NSLocalizedString("已复制", comment: ""), expand: NSLocalizedString("展开", comment: ""),
            collapse: NSLocalizedString("收起", comment: ""))
        let data = try JSONEncoder().encode(payload)
        // JSON 字符串中的 </script> 也会被 HTML 解析器当作结束标签，须先处理尖括号。
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        let nonce = UUID().uuidString
        let mathResources = source.formulas.isEmpty ? "" : """
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css">
        <script defer nonce="\(nonce)" src="https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.js"></script>
        """
        let diagramResource = source.containsMermaid ? """
        <script defer nonce="\(nonce)" src="https://cdn.jsdelivr.net/npm/mermaid@12.1.0/dist/mermaid.min.js"></script>
        """ : ""
        html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline' https://cdn.jsdelivr.net; font-src https://cdn.jsdelivr.net; img-src https: data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer">
        <style>
        html,body { margin:0; background:transparent; overflow:hidden; font-family:var(--body-font); color:var(--body-color); }
        #content { overflow-wrap:anywhere; }
        p { margin:.35em 0; } pre { white-space:pre; overflow-x:auto; }
        code { font-family:var(--code-font); color:var(--code-color); }
        strong { font-family:var(--strong-font); color:var(--strong-color); }
        em { font-family:var(--emphasis-font); color:var(--emphasis-color); }
        blockquote { margin:.5em 0; padding-left:1em; border-left:2px solid GrayText; }
        img,svg { max-width:100%; } a { color:LinkText; }
        table { border-collapse:collapse; } td,th { padding:.4em; border:1px solid GrayText; }
        .scroll { overflow-x:auto; } .math-block { display:block; overflow-x:auto; }
        .code-actions { display:flex; gap:.5em; justify-content:flex-end; }
        button { font:inherit; color:inherit; } .code { margin:.5em 0; }
        </style>
        <script defer nonce="\(nonce)" src="https://cdn.jsdelivr.net/npm/marked@18.1.0/lib/marked.umd.js"></script>
        <script defer nonce="\(nonce)" src="https://cdn.jsdelivr.net/npm/dompurify@3.4.16/dist/purify.min.js"></script>
        \(mathResources)
        \(diagramResource)
        </head><body><div id="content"></div><script nonce="\(nonce)">
        const payload = \(json);
        \(Self.runtime)
        </script></body></html>
        """
    }

    private static let runtime = #"""
    const content = document.getElementById('content');
    const send = (value) => window.webkit.messageHandlers.etosMarkdown.postMessage(value);
    let lastHeight = 0;
    function reportHeight() {
      const height = Math.max(1, Math.ceil(content.getBoundingClientRect().height));
      if (height !== lastHeight) { lastHeight = height; send({height}); }
    }
    function escapeHTML(value) {
      const node = document.createElement('span'); node.textContent = value; return node.innerHTML;
    }
    function setStyle() {
      const style = payload.style, root = document.documentElement.style;
      root.colorScheme = style.dark ? 'dark' : 'light';
      content.style.fontSize = style.pointSize + 'px';
      content.style.lineHeight = (style.pointSize * 1.25 + style.lineSpacing) + 'px';
      for (const role of ['body', 'emphasis', 'strong', 'code']) {
        const fallback = role === 'code' ? 'ui-monospace, monospace' : '-apple-system, sans-serif';
        const family = style[role + 'Font'];
        root.setProperty('--' + role + '-font', family ? JSON.stringify(family) + ', ' + fallback : fallback);
        root.setProperty('--' + role + '-color', style[role + 'Color']);
      }
    }
    function renderFormulas() {
      const formulas = new Map(payload.source.formulas.map(f => [f.marker, f]));
      if (!formulas.size) return;
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
      const pattern = new RegExp(Array.from(formulas.keys()).join('|'), 'g');
      for (const node of nodes) {
        if (node.parentElement.closest('pre,code')) continue;
        const text = node.textContent, fragment = document.createDocumentFragment();
        let cursor = 0, changed = false;
        for (const match of text.matchAll(pattern)) {
          changed = true; fragment.append(document.createTextNode(text.slice(cursor, match.index)));
          const formula = formulas.get(match[0]), span = document.createElement('span');
          if (formula.display) span.className = 'math-block';
          try { window.katex.render(formula.latex, span, {displayMode:formula.display, throwOnError:false, trust:false, maxExpand:1000}); }
          catch (_) { span.textContent = formula.latex; }
          fragment.append(span); cursor = match.index + match[0].length;
        }
        if (changed) { fragment.append(document.createTextNode(text.slice(cursor))); node.replaceWith(fragment); }
      }
    }
    function decorateCode(pre, code) {
      const wrapper = document.createElement('div'); wrapper.className = 'code';
      pre.replaceWith(wrapper); wrapper.append(pre);
      const actions = document.createElement('div'); actions.className = 'code-actions';
      const copy = document.createElement('button'); copy.type = 'button'; copy.textContent = payload.copy;
      copy.addEventListener('click', (event) => {
        if (!event.isTrusted) return;
        const selection = getSelection(), range = document.createRange();
        range.selectNodeContents(code); selection.removeAllRanges(); selection.addRange(range);
        if (document.execCommand('copy')) copy.textContent = payload.copied;
        selection.removeAllRanges();
      });
      const toggle = document.createElement('button'); toggle.type = 'button'; toggle.textContent = payload.collapse;
      toggle.setAttribute('aria-expanded', 'true');
      toggle.addEventListener('click', () => {
        pre.hidden = !pre.hidden; toggle.textContent = pre.hidden ? payload.expand : payload.collapse;
        toggle.setAttribute('aria-expanded', String(!pre.hidden)); reportHeight();
      });
      actions.append(copy, toggle); wrapper.prepend(actions);
    }
    async function render() {
      try {
        if (!window.marked || !window.DOMPurify || (payload.source.formulas.length && !window.katex)
            || (payload.source.containsMermaid && !window.mermaid)) throw new Error('resources');
        setStyle();
        // 原始 HTML 仅显示字面内容；清理器再约束 Markdown 链接和属性。
        const parser = new window.marked.Marked({gfm:true, breaks:true,
          renderer:{html:({text}) => escapeHTML(text)}});
        content.innerHTML = window.DOMPurify.sanitize(parser.parse(payload.source.markdown), {
          USE_PROFILES:{html:true}, FORBID_TAGS:['form','input','button','textarea','style','iframe'],
          FORBID_ATTR:['style','id','name']
        });
        renderFormulas();
        if (payload.source.containsMermaid) window.mermaid.initialize({startOnLoad:false, securityLevel:'strict',
          theme:payload.style.dark ? 'dark' : 'default', suppressErrorRendering:true});
        let index = 0;
        for (const code of content.querySelectorAll('pre > code')) {
          const pre = code.parentElement;
          if (code.classList.contains('language-mermaid') || code.classList.contains('language-mmd')) {
            try {
              const result = await window.mermaid.render('etosDiagram' + index++, code.textContent);
              const wrapper = document.createElement('div'); wrapper.className = 'scroll';
              wrapper.innerHTML = result.svg; pre.replaceWith(wrapper);
            } catch (_) { decorateCode(pre, code); }
          } else { decorateCode(pre, code); }
        }
        for (const table of content.querySelectorAll('table')) {
          const wrapper = document.createElement('div'); wrapper.className = 'scroll';
          table.replaceWith(wrapper); wrapper.append(table);
        }
        content.addEventListener('load', reportHeight, true);
        new ResizeObserver(reportHeight).observe(content);
        document.fonts.ready.then(reportHeight);
        reportHeight(); send({ready:true});
      } catch (_) { send({failed:true}); }
    }
    window.addEventListener('load', render, {once:true});
    """#
}
