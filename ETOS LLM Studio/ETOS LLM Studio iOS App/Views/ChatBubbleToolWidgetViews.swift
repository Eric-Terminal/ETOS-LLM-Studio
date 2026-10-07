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
