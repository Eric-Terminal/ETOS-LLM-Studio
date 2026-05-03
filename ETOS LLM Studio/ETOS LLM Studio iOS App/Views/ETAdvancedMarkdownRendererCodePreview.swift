// ============================================================================
// ETAdvancedMarkdownRendererCodePreview.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Markdown 代码块的 HTML、SVG 等可运行内容预览。
// ============================================================================

import SwiftUI
import WebKit

enum ETCodePreviewSupport {
    private static let previewableLanguages: Set<String> = [
        "html", "htm", "xhtml", "xml", "svg"
    ]

    static func canPreview(_ language: String?) -> Bool {
        previewableLanguages.contains(normalizedLanguage(language))
    }

    static func htmlDocument(content: String, language: String?, prefersDarkPalette: Bool) -> String {
        let normalized = normalizedLanguage(language)
        let backgroundColor = prefersDarkPalette ? "#1C1C1E" : "#FFFFFF"
        let textColor = prefersDarkPalette ? "#FFFFFF" : "#1C1C1E"

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
      background: \(backgroundColor);
      color: \(textColor);
      color-scheme: \(prefersDarkPalette ? "dark" : "light");
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
            return wrappedHTMLIfNeeded(content, prefersDarkPalette: prefersDarkPalette)
        default:
            return content
        }
    }

    private static func previewResetStyle(prefersDarkPalette: Bool) -> String {
        let backgroundColor = prefersDarkPalette ? "#1C1C1E" : "#FFFFFF"
        let textColor = prefersDarkPalette ? "#FFFFFF" : "#1C1C1E"

        return """
<style id="et-preview-reset">
  html, body {
    margin: 0 !important;
    padding: 0 !important;
    min-height: 100%;
    width: 100%;
    color-scheme: \(prefersDarkPalette ? "dark" : "light");
  }
  body {
    background: \(backgroundColor);
    color: \(textColor);
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
    }

    private static func wrappedHTMLIfNeeded(_ content: String, prefersDarkPalette: Bool) -> String {
        let lowercased = content.lowercased()
        if lowercased.contains("<html") || lowercased.contains("<!doctype") {
            return injectingPreviewResetStyle(into: content, prefersDarkPalette: prefersDarkPalette)
        }
        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  \(previewResetStyle(prefersDarkPalette: prefersDarkPalette))
</head>
<body>
\(content)
</body>
</html>
"""
    }

    private static func injectingPreviewResetStyle(into html: String, prefersDarkPalette: Bool) -> String {
        if html.contains("id=\"et-preview-reset\"") {
            return html
        }

        if let headCloseRange = html.range(of: "</head>", options: [.caseInsensitive]) {
            var output = html
            output.insert(contentsOf: "\n\(previewResetStyle(prefersDarkPalette: prefersDarkPalette))\n", at: headCloseRange.lowerBound)
            return output
        }

        if let htmlOpenRange = html.range(of: "<html", options: [.caseInsensitive]),
           let htmlTagClose = html[htmlOpenRange.lowerBound...].firstIndex(of: ">") {
            var output = html
            let insertIndex = output.index(after: htmlTagClose)
            output.insert(contentsOf: "\n<head>\n\(previewResetStyle(prefersDarkPalette: prefersDarkPalette))\n</head>\n", at: insertIndex)
            return output
        }

        return """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  \(previewResetStyle(prefersDarkPalette: prefersDarkPalette))
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

struct ETCodePreviewButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let content: String
    let language: String?
    let tintColor: Color

    @State private var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            Image(systemName: "safari")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("预览代码", comment: ""))
        .fullScreenCover(isPresented: $showingPreview) {
            ETCodePreviewSheet(
                content: content,
                language: language,
                prefersDarkPalette: colorScheme == .dark
            )
        }
    }
}

private struct ETCodePreviewSheet: View {
    let content: String
    let language: String?
    let prefersDarkPalette: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ETCodePreviewWebView(
                htmlContent: ETCodePreviewSupport.htmlDocument(
                    content: content,
                    language: language,
                    prefersDarkPalette: prefersDarkPalette
                )
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
