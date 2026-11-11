import Foundation
import Testing
@testable import ETOSCore

#if canImport(WebKit) && !os(watchOS)
import WebKit

@MainActor
@Suite("本地网页 WebKit 集成", .serialized, .timeLimit(.minutes(1)))
struct BrowserLocalPageRuntimeTests {
    @Test("浏览器加载本地 HTML、相对 CSS、脚本和图片，支持链接与更新后重载")
    func loadsLocalPageAndAssets() async throws {
        let name = "BrowserLocalPageTest-" + UUID().uuidString
        let directory = StorageUtility.documentsDirectory.appendingPathComponent(name)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = [
                "index.html": """
                <!doctype html><meta charset="utf-8"><title>本地网页</title>
                <link rel="stylesheet" href="main.css?v=1"><script src="main.js"></script>
                <h1>你好</h1><img id="icon" src="icon.svg"><a id="next" href="next.html?mode=dark#note">下一页</a>
                """,
                "main.css": "h1 { color: rgb(12, 34, 56); }",
                "main.js": "window.localScriptLoaded = true;",
                "icon.svg": "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10'/></svg>",
                "next.html": "<!doctype html><meta charset='utf-8'><h1 id='note'>第二页</h1>"
            ]
            for (filename, content) in files { try Data(content.utf8).write(to: directory.appendingPathComponent(filename)) }
        }.value
        let manager = BrowserSessionManager(), session = UUID()
        do {
            let url = URL(string: "etos://sandbox/\(name)/index.html?version=1#title")!
            let tab = try await manager.openTab(
                sessionID: session, url: url, dataProfile: .sessionIsolated,
                allowedAgentNavigationHosts: ["etos://sandbox"]
            )
            let webView = try manager.webView(sessionID: session, tabID: tab.id)
            let result = try await webView.evaluateJavaScript("""
                JSON.stringify([document.querySelector('h1').textContent,
                  getComputedStyle(document.querySelector('h1')).color,
                  window.localScriptLoaded, document.querySelector('#icon').naturalWidth > 0])
                """) as? String
            #expect(result == "[\"你好\",\"rgb(12, 34, 56)\",true,true]")
            #expect(tab.url == url.absoluteString)
            let destination = try #require(URL(string: "next.html?mode=dark#note", relativeTo: url)?.absoluteURL)
            _ = try await manager.evaluateJavaScript(
                sessionID: session, tabID: tab.id,
                script: "document.querySelector('#next').click(); true;", allowedAgentNavigationHosts: []
            )
            #expect(try manager.currentURL(sessionID: session, tabID: tab.id)?.fragment == "note")
            try await Task.detached(priority: .utility) {
                try Data("<!doctype html><meta charset='utf-8'><h1>已更新</h1>".utf8).write(to: directory.appendingPathComponent("next.html"))
            }.value
            _ = try await manager.navigate(sessionID: session, tabID: tab.id, url: destination)
            #expect(try await webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "已更新")
        } catch {
            manager.discardAllSessions()
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
            throw error
        }
        manager.discardAllSessions()
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }

    @Test("WebKit 取消请求后不再收到资源回调")
    func cancellationDoesNotDeliverCallbacks() async {
        let handler = BrowserLocalSchemeHandler(sessionID: UUID())
        let task = CancelledLocalSchemeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)
        // 让读取任务进入 actor 并返回；取消已在主执行器同步生效。
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(task.callbackCount == 0)
    }
}

@MainActor
private final class CancelledLocalSchemeTask: NSObject, WKURLSchemeTask {
    let request = URLRequest(url: URL(string: "etos://sandbox/missing.html")!)
    var callbackCount = 0
    func didReceive(_ response: URLResponse) { callbackCount += 1 }
    func didReceive(_ data: Data) { callbackCount += 1 }
    func didFinish() { callbackCount += 1 }
    func didFailWithError(_ error: Error) { callbackCount += 1 }
}
#endif
