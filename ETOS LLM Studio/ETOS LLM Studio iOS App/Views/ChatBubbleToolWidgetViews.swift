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
    @State private var renderedHeight: CGFloat = 180
    @State private var hasRendered = false

    private var loadingText: String {
        payload.loadingMessages.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (payload.loadingMessages.first ?? NSLocalizedString("正在渲染 Widget…", comment: ""))
            : NSLocalizedString("正在渲染 Widget…", comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ToolWidgetWebView(
                    widgetCode: payload.widgetCode,
                    colorScheme: colorScheme,
                    availableWidth: max(1, floor(proxy.size.width)),
                    renderedHeight: $renderedHeight,
                    hasRendered: $hasRendered
                )
            }
            .frame(height: max(120, renderedHeight))
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
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

struct ToolWidgetWebView: UIViewRepresentable {
    let widgetCode: String
    let colorScheme: ColorScheme
    let availableWidth: CGFloat
    @Binding var renderedHeight: CGFloat
    @Binding var hasRendered: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight, hasRendered: $hasRendered)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.heightMessageName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let stableWidth = max(1, floor(availableWidth))
        let html = wrappedHTML(widgetCode: widgetCode, stableWidth: stableWidth)
        let renderKey = "\(colorScheme == .dark ? "dark" : "light")|\(html)"
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessageName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etWidgetHeight"

        @Binding var renderedHeight: CGFloat
        @Binding var hasRendered: Bool
        var lastRenderKey: String?

        init(renderedHeight: Binding<CGFloat>, hasRendered: Binding<Bool>) {
            self._renderedHeight = renderedHeight
            self._hasRendered = hasRendered
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.heightMessageName else { return }
            guard let value = message.body as? Double else { return }
            let nextHeight = max(120, ceil(value))
            if abs(renderedHeight - nextHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.renderedHeight = nextHeight
                    self.hasRendered = true
                }
            } else {
                DispatchQueue.main.async {
                    self.hasRendered = true
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.__etReportSize && window.__etReportSize();", completionHandler: nil)
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

    private func wrappedHTML(widgetCode: String, stableWidth: CGFloat) -> String {
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
      height: auto;
      min-height: 0;
      background: transparent;
      overflow: visible;
    }
    body {
      position: relative;
    }
    #et-widget-host {
      width: min(100%, \(Int(stableWidth))px);
      max-width: 100%;
      min-height: 1px;
      box-sizing: border-box;
      overflow: visible;
    }
    #et-widget-root {
      width: 100%;
      min-width: 0;
      max-width: 100%;
      margin: 0;
      box-sizing: border-box;
      overflow: visible;
    }
  </style>
</head>
<body>
  <div id="et-widget-host">
    <div id="et-widget-root">
\(widgetCode)
    </div>
  </div>
  <script>
    (function () {
      var lastPostedHeight = 0;
      var sampleCount = 0;

      function isFiniteNumber(value) {
        return typeof value === 'number' && isFinite(value);
      }

      function walkElements(rootNode, visitor) {
        if (!rootNode || typeof rootNode.querySelectorAll !== 'function') return;
        var elements = rootNode.querySelectorAll('*');
        for (var index = 0; index < elements.length; index += 1) {
          var element = elements[index];
          visitor(element);
          if (element && element.shadowRoot) {
            walkElements(element.shadowRoot, visitor);
          }
        }
      }

      function syncSameOriginIframeHeight() {
        var iframes = document.querySelectorAll('iframe');
        for (var index = 0; index < iframes.length; index += 1) {
          var frame = iframes[index];
          if (!frame) continue;
          try {
            var frameDocument = frame.contentDocument;
            if (!frameDocument) continue;
            var frameBody = frameDocument.body;
            var frameRoot = frameDocument.documentElement;
            var frameHeight = Math.max(
              frameBody ? frameBody.scrollHeight : 0,
              frameBody ? frameBody.offsetHeight : 0,
              frameRoot ? frameRoot.scrollHeight : 0,
              frameRoot ? frameRoot.offsetHeight : 0
            );
            if (frameHeight > 0) {
              frame.style.height = frameHeight + 'px';
            }
          } catch (_) {
            // 跨域 iframe 无法读取高度，保持默认行为。
          }
        }
      }

      function visualBoundsHeight(container) {
        if (!container || typeof container.getBoundingClientRect !== 'function') return 0;
        var containerRect = container.getBoundingClientRect();
        var minTop = isFiniteNumber(containerRect.top) ? containerRect.top : 0;
        var maxBottom = isFiniteNumber(containerRect.bottom) ? containerRect.bottom : minTop;
        walkElements(container, function (element) {
          if (!element || typeof element.getBoundingClientRect !== 'function') return;
          var rect = element.getBoundingClientRect();
          if (!rect) return;
          if (!isFiniteNumber(rect.top) || !isFiniteNumber(rect.bottom)) return;
          if (rect.width <= 0 && rect.height <= 0) return;
          if (rect.top < minTop) minTop = rect.top;
          if (rect.bottom > maxBottom) maxBottom = rect.bottom;
        });
        return Math.max(0, Math.ceil(maxBottom - minTop));
      }

      function postHeight(height) {
        if (!isFiniteNumber(height)) return;
        if (Math.abs(height - lastPostedHeight) < 0.5) return;
        lastPostedHeight = height;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.etWidgetHeight) {
          window.webkit.messageHandlers.etWidgetHeight.postMessage(height);
        }
      }

      function reportHeight() {
        syncSameOriginIframeHeight();
        var host = document.getElementById('et-widget-host');
        var widgetRoot = document.getElementById('et-widget-root');
        var flowHeight = Math.max(
          host ? host.scrollHeight : 0,
          host ? host.offsetHeight : 0,
          widgetRoot ? widgetRoot.scrollHeight : 0,
          widgetRoot ? widgetRoot.offsetHeight : 0
        );
        var visualHeight = visualBoundsHeight(widgetRoot || host);
        var height = Math.max(1, flowHeight, visualHeight);
        var viewportHeight = window.innerHeight || 0;
        if (
          lastPostedHeight > 0 &&
          viewportHeight > 0 &&
          Math.abs(viewportHeight - lastPostedHeight) < 1 &&
          height > lastPostedHeight
        ) {
          var feedbackGrowth = height - viewportHeight;
          if (feedbackGrowth > 0 && feedbackGrowth <= 96) {
            height = lastPostedHeight;
          }
        }
        postHeight(height);
      }
      window.__etReportSize = reportHeight;
      if (window.ResizeObserver) {
        var observer = new ResizeObserver(reportHeight);
        var hostContainer = document.getElementById('et-widget-host');
        var widgetContainer = document.getElementById('et-widget-root');
        if (hostContainer) observer.observe(hostContainer);
        if (widgetContainer) observer.observe(widgetContainer);
      }
      if (window.MutationObserver) {
        var mutationObserver = new MutationObserver(reportHeight);
        var mutationTarget = document.getElementById('et-widget-host') || document.documentElement;
        if (mutationTarget) {
          mutationObserver.observe(mutationTarget, {
            attributes: true,
            characterData: true,
            childList: true,
            subtree: true
          });
        }
      }
      window.addEventListener('load', reportHeight);
      window.addEventListener('resize', reportHeight);
      setTimeout(reportHeight, 0);
      setTimeout(reportHeight, 120);
      setTimeout(reportHeight, 360);
      function sampleAnimatedLayout() {
        reportHeight();
        sampleCount += 1;
        if (sampleCount < 20) {
          setTimeout(sampleAnimatedLayout, 100);
        }
      }
      sampleAnimatedLayout();
    })();
  </script>
</body>
</html>
"""
    }
}
