import AppKit
import ETOSCore
import SwiftUI
import WebKit

struct MacAdvancedMarkdownView<Fallback: View>: View {
    let sourceID: UUID
    let source: ETAdvancedMarkdownSource
    let typography: MacTextTypography
    let palette: MacChatTextPalette
    @ViewBuilder var fallback: () -> Fallback
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var prepared: Prepared?
    @State private var status = MacMarkdownWebStatus.loading
    @State private var height: CGFloat = 1
    @State private var retry = UUID()
    @State private var visible = false
    private var available: Bool { visible && workspace.canManageLocalModels && appLock.state != .locked }

    private struct Request: Equatable, Sendable {
        let sourceID: UUID
        let retry: UUID
        let language: String
        let active: Bool
        let style: MacAdvancedMarkdownDocument.Style
    }
    private struct Prepared {
        let request: Request
        let document: MacAdvancedMarkdownDocument
    }
    private var request: Request {
        let defaultColor = colorScheme == .dark ? "FFFFFFFF" : "1C1C1EFF"
        let body = palette.bodyHex ?? defaultColor
        return .init(sourceID: sourceID, retry: retry, language: configuration.appLanguage, active: available, style: .init(
            dark: colorScheme == .dark, pointSize: typography.pointSize, lineSpacing: typography.lineSpacing,
            bodyFont: typography.bodyName, emphasisFont: typography.emphasisName, strongFont: typography.strongName,
            codeFont: typography.codeName, bodyColor: "#" + body,
            emphasisColor: "#" + (palette.emphasisHex ?? body), strongColor: "#" + (palette.strongHex ?? body),
            codeColor: "#" + (palette.codeHex ?? body)))
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !available || status != .ready || prepared?.request != request { fallback() }
            if available, let prepared, prepared.request == request, status != .failed {
                MacMarkdownWebView(document: prepared.document, height: $height, status: $status)
                    .id(prepared.document.id)
                    .frame(height: status == .ready ? height : 1)
                    .opacity(status == .ready ? 1 : 0)
                    .accessibilityHidden(status != .ready)
            }
            if available, status == .failed {
                Text(NSLocalizedString("高级渲染暂不可用，已显示原文。", comment: ""))
                    .font(.caption).foregroundStyle(.secondary)
                Button(NSLocalizedString("重试", comment: "")) { retry = UUID() }.buttonStyle(.borderless)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; prepared = nil }
        .task(id: request) {
            let request = request, source = source
            status = .loading
            guard request.active else { prepared = nil; return }
            let document = await Task.detached(priority: .userInitiated) {
                try? MacAdvancedMarkdownDocument(source: source, style: request.style)
            }.value
            guard !Task.isCancelled else { return }
            if let document { prepared = .init(request: request, document: document) }
            else { prepared = nil; status = .failed }
        }
    }
}

private enum MacMarkdownWebStatus: Equatable { case loading, ready, failed }

private struct MacMarkdownWebView: NSViewRepresentable {
    let document: MacAdvancedMarkdownDocument
    @Binding var height: CGFloat
    @Binding var status: MacMarkdownWebStatus

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, status: $status) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "etosMarkdown")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.render(document, on: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "etosMarkdown")
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding private var height: CGFloat
        @Binding private var status: MacMarkdownWebStatus
        private var documentID: UUID?
        private var timeout: Task<Void, Never>?
        private var invalidated = false

        init(height: Binding<CGFloat>, status: Binding<MacMarkdownWebStatus>) {
            _height = height; _status = status
        }

        func render(_ document: MacAdvancedMarkdownDocument, on view: WKWebView) {
            guard !invalidated, documentID != document.id else { return }
            documentID = document.id
            timeout?.cancel()
            let id = document.id
            // 仅设置一次加载截止时间；迟到回调不能覆盖新内容或已销毁的页面。
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, !invalidated, documentID == id, status == .loading else { return }
                status = .failed
            }
            view.loadHTMLString(document.html, baseURL: nil)
        }

        func invalidate() { invalidated = true; documentID = nil; timeout?.cancel(); timeout = nil }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !invalidated, status != .failed, message.frameInfo.isMainFrame,
                  let value = message.body as? [String: Any] else { return }
            let id = documentID
            DispatchQueue.main.async { [weak self] in
                guard let self, !invalidated, documentID == id, status != .failed else { return }
                if value["failed"] as? Bool == true { status = .failed; timeout?.cancel() }
                else {
                    if let value = (value["height"] as? NSNumber)?.doubleValue, value.isFinite, value > 0 { height = CGFloat(value) }
                    if value["ready"] as? Bool == true { status = .ready; timeout?.cancel() }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !invalidated, let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            // 只加载本地生成的文档，不接受模型链接发起的自动导航、文件或脚本 URL。
            decisionHandler(action.navigationType == .other && url.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        private func fail() {
            guard !invalidated else { return }
            timeout?.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self, !invalidated else { return }
                status = .failed
            }
        }
    }
}
