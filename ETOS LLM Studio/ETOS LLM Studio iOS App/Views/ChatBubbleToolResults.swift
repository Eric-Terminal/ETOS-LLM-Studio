// ============================================================================
// ChatBubbleToolResults.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的工具结果详情、Widget 渲染与文本展开视图。
// ============================================================================

import Foundation
import SwiftUI
import Shared
import UIKit
import WebKit

struct ToolPermissionInlineView: View {
    let request: ToolPermissionRequest
    let onDecision: (ToolPermissionDecision) -> Void
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    private var autoApproveToggleLabel: String {
        permissionCenter.isAutoApproveDisabled(for: request.toolName)
            ? NSLocalizedString("恢复该工具自动批准", comment: "")
            : NSLocalizedString("关闭该工具自动批准", comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(NSLocalizedString("允许", comment: "")) {
                    onDecision(.allowOnce)
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("拒绝", comment: ""), role: .destructive) {
                    onDecision(.deny)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(NSLocalizedString("补充提示", comment: "")) {
                    onDecision(.supplement)
                }
                .buttonStyle(.bordered)

                Button(NSLocalizedString("保持允许", comment: "")) {
                    onDecision(.allowForTool)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(NSLocalizedString("完全权限", comment: "")) {
                    onDecision(.allowAll)
                }
                .buttonStyle(.bordered)

                if permissionCenter.autoApproveEnabled {
                    Button(autoApproveToggleLabel) {
                        let shouldDisable = !permissionCenter.isAutoApproveDisabled(for: request.toolName)
                        permissionCenter.setAutoApproveDisabled(shouldDisable, for: request.toolName)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let countdownText {
                Text(countdownText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}

struct ToolResultsDisclosureView: View, Equatable {
    let toolCalls: [InternalToolCall]
    let resultText: String
    @Binding var isExpanded: Bool
    let isOutgoing: Bool
    let isPending: Bool
    let enableExperimentalToolResultDisplay: Bool
    let customTextColor: Color?

    static func == (lhs: ToolResultsDisclosureView, rhs: ToolResultsDisclosureView) -> Bool {
        lhs.toolCalls.map(\.id) == rhs.toolCalls.map(\.id)
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.resultText == rhs.resultText
            && lhs.isPending == rhs.isPending
            && lhs.enableExperimentalToolResultDisplay == rhs.enableExperimentalToolResultDisplay
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
    }

    private func displayName(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        if let label = MCPManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = SkillManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = AppToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        return toolName
    }

    private var headerForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.9)
        }
        return isOutgoing ? Color.white.opacity(0.9) : Color.secondary
    }

    private var summaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.72)
        }
        return isOutgoing ? Color.white.opacity(0.72) : Color.secondary.opacity(0.9)
    }

    private var sectionForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary
    }

    private var sectionBackgroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(isOutgoing ? 0.15 : 0.1)
        }
        return isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    private func resolvedResult(for call: InternalToolCall) -> String {
        (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayModel(for call: InternalToolCall) -> MCPToolResultDisplayModel {
        MCPToolResultFormatter.displayModel(from: resolvedResult(for: call))
    }

    private var disclosureSummaryText: String? {
        guard enableExperimentalToolResultDisplay else { return nil }
        let summaries = toolCalls
            .map { call -> String in
                if let payload = widgetPayload(for: call) {
                    if let title = payload.title,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return String(format: NSLocalizedString("可视化 Widget · %@", comment: ""), title)
                    }
                    return NSLocalizedString("可视化 Widget", comment: "")
                }
                return displayModel(for: call).summaryText
            }
            .filter { !$0.isEmpty }

        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: " · ")
    }

    var body: some View {
        let toolNames = toolCalls.map { displayName(for: $0.toolName) }
        VStack(alignment: .leading, spacing: 0) {
            if isPending {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .etFont(.system(size: 12))
                    ShimmeringText(
                        text: String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")),
                        font: .subheadline.weight(.medium),
                        baseColor: headerForegroundColor,
                        highlightColor: customTextColor?.opacity(0.95) ?? (isOutgoing ? Color.white : Color.primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.4) : Color.secondary.opacity(0.6))
                }
                .foregroundStyle(headerForegroundColor)
                .contentShape(Rectangle())
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .etFont(.system(size: 12))
                            Text(String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")))
                                .etFont(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        if let disclosureSummaryText {
                            Text(disclosureSummaryText)
                                .etFont(.caption)
                                .foregroundStyle(summaryForegroundColor)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundStyle(headerForegroundColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded && !isPending {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls, id: \.id) { call in
                        toolResultContent(for: call)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    @ViewBuilder
    private func toolResultContent(for call: InternalToolCall) -> some View {
        if let payload = widgetPayload(for: call) {
            widgetToolResultContent(for: call, payload: payload)
        } else if enableExperimentalToolResultDisplay {
            experimentalToolResultContent(for: call)
        } else {
            legacyToolResultContent(for: call)
        }
    }

    private func widgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
        if let payload = ToolWidgetPayloadParser.parse(from: call.arguments) {
            return payload
        }

        let resolved = resolvedResult(for: call)
        if let payload = ToolWidgetPayloadParser.parse(from: resolved) {
            return payload
        }

        if let payload = ToolWidgetPayloadParser.parse(from: resultText) {
            return payload
        }

        return nil
    }

    @ViewBuilder
    private func widgetToolResultContent(for call: InternalToolCall, payload: ToolWidgetPayload) -> some View {
        if call.toolName == AppToolKind.showWidget.toolName {
            ToolWidgetRendererCard(payload: payload)
        } else {
            let display = displayModel(for: call)
            let label = displayName(for: call.toolName)
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .etFont(.caption.weight(.semibold))
                ToolWidgetRendererCard(payload: payload)
                if display.shouldShowRawSection {
                    Divider()
                        .background(sectionBackgroundColor.opacity(0.7))
                    toolResultSection(
                        title: "原始返回",
                        text: display.rawDisplayText,
                        font: .system(.caption, design: .monospaced),
                        enableSelection: true
                    )
                }
            }
            .foregroundStyle(sectionForegroundColor)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(sectionBackgroundColor)
            )
        }
    }

    private func experimentalToolResultContent(for call: InternalToolCall) -> some View {
        let display = displayModel(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if let primaryContentText = display.primaryContentText,
               !primaryContentText.isEmpty {
                toolResultSection(
                    title: display.shouldShowRawSection ? "主要内容" : "结果内容",
                    text: primaryContentText,
                    font: .caption,
                    enableSelection: true
                )
            }
            if display.shouldShowRawSection {
                if display.primaryContentText != nil {
                    Divider()
                        .background(sectionBackgroundColor.opacity(0.7))
                }
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption, design: .monospaced),
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    private func legacyToolResultContent(for call: InternalToolCall) -> some View {
        let result = resolvedResult(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if !result.isEmpty {
                CappedScrollableText(
                    text: result,
                    maxHeight: 200,
                    font: .caption,
                    foreground: sectionForegroundColor,
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    private func toolResultSection(
        title: String,
        text: String,
        font: Font,
        enableSelection: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(title, comment: "工具结果小节标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(sectionForegroundColor.opacity(0.85))
            CappedScrollableText(
                text: text,
                maxHeight: 200,
                font: font,
                foreground: sectionForegroundColor,
                enableSelection: enableSelection
            )
        }
    }

    private static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}

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
