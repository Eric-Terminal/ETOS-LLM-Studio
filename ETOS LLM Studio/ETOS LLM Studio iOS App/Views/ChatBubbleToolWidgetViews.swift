// ============================================================================
// ChatBubbleToolWidgetViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天气泡工具结果中的 Widget 渲染卡片与 WKWebView 承载层。
// ============================================================================

import SwiftUI
import ETOSCore
import UIKit
import WebKit

struct ToolWidgetRendererCard: View {
    let payload: ToolWidgetPayload

    @Environment(\.colorScheme) private var colorScheme
    @State private var hasRendered = false
    @State private var inlineContent = InlineHTMLContent()
    @State private var showsInlineActions = false
    @State private var preparedHTML: String?

    private var loadingText: String {
        payload.loadingMessages.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (payload.loadingMessages.first ?? NSLocalizedString("正在渲染 Widget…", comment: ""))
            : NSLocalizedString("正在渲染 Widget…", comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title = payload.title, !title.isEmpty {
                    Text(title)
                        .etFont(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showsInlineActions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
                .disabled(preparedHTML == nil)
                .accessibilityLabel(NSLocalizedString("内联内容", comment: ""))
            }
            if let preparedHTML {
                ToolWidgetWebView(
                    html: preparedHTML,
                    sourceCode: payload.widgetCode,
                    title: payload.title,
                    colorScheme: colorScheme,
                    hasRendered: $hasRendered,
                    inlineContent: inlineContent
                )
                .aspectRatio(CGFloat(payload.inlineAspectRatio.value), contentMode: .fit)
                .overlay {
                    if !hasRendered {
                        ProgressView(loadingText)
                            .progressViewStyle(.circular)
                            .tint(.secondary)
                            .etFont(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ProgressView(loadingText)
            }
        }
        .task(id: payload.widgetCode) {
            let code = payload.widgetCode
            let html = await Task.detached(priority: .utility) {
                ToolWidgetHTMLDocumentFactory.document(widgetCode: code)
            }.value
            guard !Task.isCancelled else { return }
            preparedHTML = html
        }
        .sheet(isPresented: $showsInlineActions) {
            NavigationStack {
                InlineHTMLActionsView(content: inlineContent) { EmptyView() }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("完成", comment: "")) { showsInlineActions = false }
                        }
                    }
            }
        }
    }
}

struct ToolWidgetWebView: UIViewRepresentable {
    let html: String
    let sourceCode: String
    let title: String?
    let colorScheme: ColorScheme
    @Binding var hasRendered: Bool
    var inlineContent: InlineHTMLContent? = nil
    @Environment(\.inlineHTMLMessageIdentity) private var messageIdentity

    func makeCoordinator() -> Coordinator {
        Coordinator(hasRendered: $hasRendered)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        if let inlineContent {
            context.coordinator.inlineContent = inlineContent
            InlineHTMLWebViewSupport.connect(inlineContent, to: webView)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let inlineContent {
            inlineContent.messageID = messageIdentity?.messageID
            inlineContent.versionIndex = messageIdentity?.versionIndex ?? 0
            inlineContent.title = title ?? NSLocalizedString("可视化 Widget", comment: "")
            inlineContent.code = sourceCode
            inlineContent.html = html
        }
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let renderKey = html
        guard context.coordinator.lastRenderKey != renderKey else { return }
        context.coordinator.lastRenderKey = renderKey

        DispatchQueue.main.async {
            hasRendered = false
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        if let content = coordinator.inlineContent { InlineHTMLContentRegistry.shared.remove(content) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var hasRendered: Bool
        var lastRenderKey: String?
        var inlineContent: InlineHTMLContent?

        init(hasRendered: Binding<Bool>) {
            self._hasRendered = hasRendered
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.hasRendered = true
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.hasRendered = true
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.hasRendered = true
            }
        }
    }

}

enum ToolWidgetHTMLDocumentFactory {
    nonisolated static func document(widgetCode: String) -> String {
        """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <style id="et-widget-host-style">
    :root {
      color-scheme: light dark;
      --color-background-primary: #FFFFFF;
      --color-background-secondary: #F2F2F7;
      --color-background-tertiary: #FFFFFF;
      --color-text-primary: #1C1C1E;
      --color-text-secondary: #3C3C43;
      --color-text-tertiary: #8E8E93;
      --color-text-info: #0A84FF;
      --color-border-tertiary: rgba(60, 60, 67, 0.16);
      --color-border-secondary: rgba(60, 60, 67, 0.3);
      --border-radius-md: 8px;
      --border-radius-lg: 12px;
      --border-radius-xl: 16px;
      --font-sans: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      --font-serif: Georgia, 'Times New Roman', serif;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --color-background-primary: #1C1C1E;
        --color-background-secondary: #2C2C2E;
        --color-background-tertiary: #1C1C1E;
        --color-text-primary: #FFFFFF;
        --color-text-secondary: #EBEBF5;
        --color-text-tertiary: #8E8E93;
        --color-text-info: #5AC8FA;
        --color-border-tertiary: rgba(235, 235, 245, 0.16);
        --color-border-secondary: rgba(235, 235, 245, 0.3);
      }
    }
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      min-height: 0;
      background: transparent;
      overflow: hidden;
    }
    body {
      position: relative;
    }
    #et-widget-host {
      width: 100%;
      height: 100%;
      max-width: 100%;
      box-sizing: border-box;
      overflow: hidden;
    }
    #et-widget-root {
      width: 100%;
      height: 100%;
      min-width: 0;
      max-width: 100%;
      margin: 0;
      box-sizing: border-box;
      overflow: hidden;
    }
  </style>
</head>
<body>
  <div id="et-widget-host">
    <div id="et-widget-root">
\(widgetCode)
    </div>
  </div>
</body>
</html>
"""
    }
}
