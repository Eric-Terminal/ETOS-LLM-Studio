import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MacToolWidgetView: View {
    let widget: CompletedToolWidget
    let messageID: UUID
    @State private var content = InlineHTMLContent()
    @State private var isReady = false
    @State private var error: String?
    @State private var showsActions = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(widget.payload.title ?? NSLocalizedString("可视化 Widget", comment: ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showsActions = true } label: {
                    Label(NSLocalizedString("内联内容", comment: ""), systemImage: "ellipsis")
                }
            }
            MacWidgetWebView(widget: widget, messageID: messageID, content: content, isReady: $isReady, error: $error)
                .aspectRatio(CGFloat(widget.payload.inlineAspectRatio.value), contentMode: .fit)
                .frame(maxHeight: 600)
                .overlay {
                    if !isReady && error == nil {
                        ProgressView(widget.payload.loadingMessages.first ?? NSLocalizedString("正在渲染 Widget…", comment: ""))
                    }
                }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showsActions) {
            NavigationStack {
                InlineHTMLActionsView(content: content, onCopy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }, onExport: { try await MacInlineHTMLExport.save($0, $1) }) { EmptyView() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("完成", comment: "")) { showsActions = false }
                    }
                }
            }
            .modifier(MacGuideInspector())
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}

private struct MacWidgetWebView: NSViewRepresentable {
    let widget: CompletedToolWidget
    let messageID: UUID
    let content: InlineHTMLContent
    @Binding var isReady: Bool
    @Binding var error: String?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(isReady: $isReady, error: $error, content: content) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // 不安装 native message handler；Widget 脚本没有直接执行 App 工具的能力。
        MacInlineHTMLWebViewSupport.connect(content, to: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        content.messageID = messageID
        content.title = widget.payload.title ?? NSLocalizedString("可视化 Widget", comment: "")
        content.code = widget.payload.widgetCode
        content.html = widget.html
        guard context.coordinator.renderID != widget.id else { return }
        context.coordinator.renderID = widget.id
        webView.loadHTMLString(widget.html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        InlineHTMLContentRegistry.shared.remove(coordinator.content)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isReady: Bool
        @Binding var error: String?
        let content: InlineHTMLContent
        var renderID: UUID?

        init(isReady: Binding<Bool>, error: Binding<String?>, content: InlineHTMLContent) {
            _isReady = isReady
            _error = error
            self.content = content
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isReady = false
            error = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let isWebURL = url.scheme == "https" || url.scheme == "http"
            if action.navigationType == .linkActivated, isWebURL {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // 内联画布只保留自身文档；外部网页仅允许子框架加载，不能用自定义协议启动应用。
            let allowed = url.absoluteString == "about:blank" || (action.targetFrame?.isMainFrame == false && isWebURL)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

@MainActor
enum MacInlineHTMLExport {
    static func save(_ data: Data, _ fileExtension: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileExtension == "png" ? .png : .html]
        panel.nameFieldStringValue = "ETOS-Widget.\(fileExtension)"
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }
}
