import Foundation
import Testing
import WebKit
import ETOSCore
@testable import ETOS_LLM_Studio_App

@MainActor
struct InlineHTMLWebViewSupportTests {
    @Test("复制网页纯文本读取交互后的 DOM，代码仍保留生成方原文")
    func copiesCurrentVisibleText() async throws {
        let code = "<p id='text'>初始文字</p><p hidden>隐藏文字</p><script>const secret = '脚本内容';</script>"
        let html = ToolWidgetHTMLDocumentFactory.document(widgetCode: code)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let loader = HTMLTestLoader()
        webView.navigationDelegate = loader
        try await loader.load(html, in: webView)
        let content = InlineHTMLContent()
        content.code = code
        InlineHTMLWebViewSupport.connect(content, to: webView)
        defer { InlineHTMLContentRegistry.shared.remove(content) }
        _ = try await webView.evaluateJavaScript("document.getElementById('text').innerText = '交互后的文字'")
        let read = try #require(content.readText)
        let text = try await read()
        #expect(text.contains("交互后的文字"))
        #expect(!text.contains("隐藏文字"))
        #expect(!text.contains("脚本内容"))
        #expect(content.code == code)
    }
}

@MainActor
private final class HTMLTestLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
