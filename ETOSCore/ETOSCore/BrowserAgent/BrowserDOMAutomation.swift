// ============================================================================
// BrowserDOMAutomation.swift
// ============================================================================
// ETOS LLM Studio
//
// Browser Agent 的页面脚本集中在这里，避免把 DOM 扫描与协议细节塞回会话管理器。
// ============================================================================

import Foundation

enum BrowserDOMAutomation {
    static let interactiveSelector = "a,button,input,textarea,select,summary,[role=\"button\"],[role=\"link\"],[contenteditable=\"true\"]"

    static func snapshot(maximumText: Int = 50_000, maximumElements: Int = 300) -> String {
        """
        (() => {
          \(runtime())
          const sourceText = (document.body?.innerText || '').replace(/\\u0000/g, '');
          const all = Array.from(document.querySelectorAll(ETOS_SELECTOR));
          const revision = ETOS_STATE.revision;
          return {
            title: document.title || '',
            url: location.href || null,
            text: sourceText.slice(0, \(maximumText)),
            elements: all.slice(0, \(maximumElements)).map((node, index) => ETOS_PAYLOAD(node, index, revision)),
            domRevision: revision,
            wasTruncated: sourceText.length > \(maximumText) || all.length > \(maximumElements)
          };
        })()
        """
    }

    static func getText(selector: String?) throws -> String {
        let selectorLiteral = try selector.map(browserAgentJavaScriptLiteral) ?? "null"
        return """
        (() => {
          const selector = \(selectorLiteral);
          const node = selector ? document.querySelector(selector) : document.body;
          if (!node) return {error: 'element_not_found'};
          const source = (node.innerText || '').replace(/\\u0000/g, '');
          return {
            selector: selector,
            text: source.slice(0, 50000),
            length: source.length,
            wasTruncated: source.length > 50000
          };
        })()
        """
    }

    static let pageInfo = """
    (() => {
      \(runtime())
      const root = document.documentElement;
      const canonical = document.querySelector('link[rel="canonical"]')?.href || null;
      return {
        title: document.title || '',
        url: location.href || null,
        canonicalURL: canonical,
        language: document.documentElement.lang || null,
        contentType: document.contentType || null,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        scrollWidth: Math.max(root?.scrollWidth || 0, document.body?.scrollWidth || 0),
        scrollHeight: Math.max(root?.scrollHeight || 0, document.body?.scrollHeight || 0),
        linkCount: document.links.length,
        formCount: document.forms.length,
        domRevision: ETOS_STATE.revision
      };
    })()
    """

    static func findElements(selector: String?, maximumElements: Int = 300) throws -> String {
        let selectorLiteral = try selector.map(browserAgentJavaScriptLiteral) ?? "null"
        return """
        (() => {
          \(runtime())
          const selector = \(selectorLiteral) || ETOS_SELECTOR;
          const all = Array.from(document.querySelectorAll(selector));
          const revision = ETOS_STATE.revision;
          return {
            elements: all.slice(0, \(maximumElements)).map((node, index) => ETOS_PAYLOAD(node, index, revision)),
            domRevision: revision,
            count: Math.min(all.length, \(maximumElements)),
            wasTruncated: all.length > \(maximumElements)
          };
        })()
        """
    }

    static func click(elementID: String?, elementIndex: Int?, domRevision: Int?) throws -> String {
        let resolution = try resolveElement(
            elementID: elementID,
            elementIndex: elementIndex,
            domRevision: domRevision
        )
        return """
        (() => {
          \(runtime())
          \(resolution)
          node.scrollIntoView({block: 'center', inline: 'center'});
          node.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
          node.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));
          node.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
          node.click();
          return {clicked: true, elementID: ETOS_ID(node), domRevision: ETOS_STATE.revision};
        })()
        """
    }

    static func type(
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        text: String,
        submit: Bool
    ) throws -> String {
        let resolution = try resolveElement(
            elementID: elementID,
            elementIndex: elementIndex,
            domRevision: domRevision
        )
        let textLiteral = try browserAgentJavaScriptLiteral(text)
        return """
        (() => {
          \(runtime())
          \(resolution)
          node.focus();
          if ('value' in node) {
            const prototype = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
            if (descriptor?.set) descriptor.set.call(node, \(textLiteral)); else node.value = \(textLiteral);
          } else {
            node.textContent = \(textLiteral);
          }
          node.dispatchEvent(new InputEvent('input', {data: \(textLiteral), inputType: 'insertText', bubbles: true}));
          node.dispatchEvent(new Event('change', {bubbles: true}));
          if (\(submit ? "true" : "false")) {
            if (node.form?.requestSubmit) node.form.requestSubmit();
            else node.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true}));
          }
          return {typed: true, submitted: \(submit ? "true" : "false"), elementID: ETOS_ID(node)};
        })()
        """
    }

    static func hover(elementID: String?, elementIndex: Int?, domRevision: Int?) throws -> String {
        let resolution = try resolveElement(
            elementID: elementID,
            elementIndex: elementIndex,
            domRevision: domRevision
        )
        return """
        (() => {
          \(runtime())
          \(resolution)
          node.scrollIntoView({block: 'center', inline: 'center'});
          const rect = node.getBoundingClientRect();
          const options = {bubbles: true, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2};
          node.dispatchEvent(new PointerEvent('pointerover', options));
          node.dispatchEvent(new MouseEvent('mouseover', options));
          node.dispatchEvent(new MouseEvent('mouseenter', {...options, bubbles: false}));
          node.dispatchEvent(new MouseEvent('mousemove', options));
          return {hovered: true, elementID: ETOS_ID(node)};
        })()
        """
    }

    static func interactionDestination(
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?,
        submittingForm: Bool
    ) throws -> String {
        let resolution = try resolveElement(
            elementID: elementID,
            elementIndex: elementIndex,
            domRevision: domRevision
        )
        return """
        (() => {
          \(runtime())
          \(resolution)
          const candidate = \(submittingForm ? "node.form?.action" : "node.closest('a')?.href || node.form?.action");
          if (!candidate) return null;
          try { return new URL(candidate, location.href).href; } catch (_) { return null; }
        })()
        """
    }

    static func backbone(selector: String?, maximumDepth: Int, maximumNodes: Int) throws -> String {
        let selectorLiteral = try selector.map(browserAgentJavaScriptLiteral) ?? "null"
        return """
        (() => {
          const root = \(selectorLiteral) ? document.querySelector(\(selectorLiteral)) : document.body;
          if (!root) return {error: 'element_not_found'};
          let seen = 0;
          let truncated = false;
          function visit(node, depth) {
            if (seen >= \(maximumNodes)) { truncated = true; return null; }
            if (!(node instanceof Element) || depth > \(maximumDepth)) return null;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden') return null;
            seen += 1;
            const children = [];
            for (const child of node.children) {
              const value = visit(child, depth + 1);
              if (value) children.push(value);
              if (seen >= \(maximumNodes)) break;
            }
            const directText = Array.from(node.childNodes)
              .filter(value => value.nodeType === Node.TEXT_NODE)
              .map(value => value.textContent || '')
              .join(' ').replace(/\\s+/g, ' ').trim().slice(0, 500);
            return {
              tag: node.tagName.toLowerCase(),
              role: node.getAttribute('role'),
              label: (node.getAttribute('aria-label') || '').slice(0, 300),
              text: directText,
              children
            };
          }
          return {tree: visit(root, 0), nodeCount: seen, wasTruncated: truncated};
        })()
        """
    }

    static func collectItems(itemSelector: String, dedupeKey: String?) throws -> String {
        let itemLiteral = try browserAgentJavaScriptLiteral(itemSelector)
        let keyLiteral = try dedupeKey.map(browserAgentJavaScriptLiteral) ?? "null"
        return """
        (() => {
          const selector = \(itemLiteral);
          const dedupeKey = \(keyLiteral);
          const nodes = Array.from(document.querySelectorAll(selector)).slice(0, 500);
          return nodes.map((node, index) => {
            let key = null;
            if (dedupeKey) {
              const nested = node.querySelector(dedupeKey);
              key = node.getAttribute(dedupeKey) || nested?.getAttribute('href') || nested?.textContent || null;
            }
            const text = (node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 4000);
            return {key: String(key || text || index).slice(0, 1000), text};
          });
        })()
        """
    }

    private static func resolveElement(
        elementID: String?,
        elementIndex: Int?,
        domRevision: Int?
    ) throws -> String {
        let idLiteral = try elementID.map(browserAgentJavaScriptLiteral) ?? "null"
        let indexLiteral = elementIndex.map(String.init) ?? "null"
        let revisionLiteral = domRevision.map(String.init) ?? "null"
        return """
        const expectedRevision = \(revisionLiteral);
        if (expectedRevision !== null && expectedRevision !== ETOS_STATE.revision) {
          return {error: 'stale_element', expectedRevision, actualRevision: ETOS_STATE.revision};
        }
        const elementID = \(idLiteral);
        const elementIndex = \(indexLiteral);
        const nodes = Array.from(document.querySelectorAll(ETOS_SELECTOR));
        const node = elementID ? ETOS_STATE.elements.get(elementID) : nodes[elementIndex];
        if (!node || !node.isConnected) return {error: 'element_not_found', actualRevision: ETOS_STATE.revision};
        """
    }

    private static func runtime() -> String {
        """
        const ETOS_SELECTOR = '\(interactiveSelector)';
        const ETOS_STATE = (() => {
          if (window.__etosBrowserAgentState) return window.__etosBrowserAgentState;
          const state = {revision: 0, nextID: 1, elements: new Map()};
          const observer = new MutationObserver(() => {
            state.revision += 1;
            for (const [key, value] of state.elements) if (!value.isConnected) state.elements.delete(key);
          });
          observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
          window.__etosBrowserAgentState = state;
          return state;
        })();
        const ETOS_ID = node => {
          for (const [key, value] of ETOS_STATE.elements) if (value === node) return key;
          const key = 'element-' + ETOS_STATE.nextID++;
          ETOS_STATE.elements.set(key, node);
          return key;
        };
        const ETOS_VISIBLE = node => {
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
        };
          const ETOS_PAYLOAD = (node, index, revision) => {
            const rect = node.getBoundingClientRect();
            const tag = node.tagName.toLowerCase();
            const text = (node.innerText || node.textContent || '').trim().slice(0, 1000);
            const actions = [];
          if (tag === 'input' || tag === 'textarea' || tag === 'select' || node.isContentEditable) actions.push('type');
          if (tag === 'a' || tag === 'button' || node.onclick || node.getAttribute('role') === 'button') actions.push('click');
          actions.push('hover');
          return {
            index,
            elementID: ETOS_ID(node),
            domRevision: revision,
            role: node.getAttribute('role') || tag,
            label: (node.getAttribute('aria-label') || text || node.getAttribute('placeholder') || node.getAttribute('title') || node.name || '').trim().slice(0, 500),
            text,
            value: ('value' in node ? String(node.value || '').slice(0, 2000) : null),
            isVisible: ETOS_VISIBLE(node),
            bounds: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
            actions
          };
        };
        """
    }
}
