// ============================================================================
// ETAdvancedMarkdownRenderer+MathWebViewLifecycle.swift
// ============================================================================
// iOS 数学 WebView 渲染组件的 WKWebView 生命周期、协调器与高度回传。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import Shared
import WebKit
import UIKit
#if canImport(SwiftMath)
import SwiftMath
#endif

extension ETMathWebViewRepresentable {
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
        let payload = Payload(
            content: content,
            availableWidth: stableWidth,
            bodyFontFamily: Self.resolvedCSSFontFamily(
                role: .body,
                sampleText: content,
                fallback: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            ),
            emphasisFontFamily: Self.resolvedCSSFontFamily(
                role: .emphasis,
                sampleText: content,
                fallback: "var(--font-body)"
            ),
            strongFontFamily: Self.resolvedCSSFontFamily(
                role: .strong,
                sampleText: content,
                fallback: "var(--font-body)"
            ),
            codeFontFamily: Self.resolvedCSSFontFamily(
                role: .code,
                sampleText: content,
                fallback: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace"
            )
        )
        let shellConfiguration = ShellConfiguration(
            enableMarkdown: enableMarkdown,
            isOutgoing: isOutgoing,
            customTextHex: customTextHex,
            prefersDarkPalette: prefersDarkPalette,
            fontScale: fontScale
        )
        context.coordinator.render(
            payload,
            shellConfiguration: shellConfiguration,
            on: webView
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessageName)
    }

    static func resolvedCSSFontFamily(
        role: FontSemanticRole,
        sampleText: String,
        fallback: String
    ) -> String {
        if FontLibrary.fallbackScope == .character {
            let familyChain = FontLibrary.fallbackPostScriptNames(for: role)
                .filter { !$0.isEmpty }
                .map(ShellConfiguration.cssFamilyLiteral)
            if !familyChain.isEmpty {
                return "\(familyChain.joined(separator: ", ")), \(fallback)"
            }
            return fallback
        }
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sampleText),
           !postScriptName.isEmpty {
            return "\(ShellConfiguration.cssFamilyLiteral(postScriptName)), \(fallback)"
        }
        return fallback
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etMathHeight"

        @Binding var renderedHeight: CGFloat
        var lastPayload: Payload?
        var lastShellConfiguration: ShellConfiguration?
        var pendingPayload: Payload?
        var isShellLoaded = false
        var isShellLoading = false

        init(renderedHeight: Binding<CGFloat>) { self._renderedHeight = renderedHeight }

        func render(
            _ payload: Payload,
            shellConfiguration: ShellConfiguration,
            on webView: WKWebView
        ) {
            let shellConfigurationChanged = lastShellConfiguration != shellConfiguration
            let shouldStartShellLoad: Bool
            if shellConfigurationChanged {
                shouldStartShellLoad = true
            } else if isShellLoaded {
                shouldStartShellLoad = false
            } else {
                shouldStartShellLoad = !isShellLoading
            }

            guard lastPayload != payload || shellConfigurationChanged || shouldStartShellLoad else { return }

            lastPayload = payload
            pendingPayload = payload

            if shouldStartShellLoad {
                lastShellConfiguration = shellConfiguration
                isShellLoaded = false
                isShellLoading = true
                webView.loadHTMLString(shellConfiguration.htmlDocument, baseURL: nil)
                return
            }

            applyPendingPayloadIfPossible(on: webView)
        }

        func applyPendingPayloadIfPossible(on webView: WKWebView) {
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
            isShellLoading = false
            isShellLoaded = true
            applyPendingPayloadIfPossible(on: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoading = false
            isShellLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoading = false
            isShellLoaded = false
        }
    }
}
