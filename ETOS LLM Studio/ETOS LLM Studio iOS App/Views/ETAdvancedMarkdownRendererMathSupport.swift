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
    \(Self.javascriptRuntime(
            enableMarkdown: enableMarkdown,
            codeCopyText: codeCopyText,
            codeCopiedText: codeCopiedText,
            codeExpandText: codeExpandText,
            codeCollapseText: codeCollapseText
        ))
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
