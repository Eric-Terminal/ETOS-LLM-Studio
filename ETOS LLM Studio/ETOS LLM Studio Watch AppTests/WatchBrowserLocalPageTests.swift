import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("手表本地网页", .serialized, .timeLimit(.minutes(1)))
struct WatchBrowserLocalPageTests {
    @Test("运行时 WebKit 注册本地协议并加载 HTML 与相对脚本")
    func loadsLocalHTMLThroughRuntimeBridge() async throws {
        let name = "WatchLocalPageTest-" + UUID().uuidString
        let directory = StorageUtility.documentsDirectory.appendingPathComponent(name)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<!doctype html><meta charset='utf-8'><h1>手表本地页面</h1><script src='main.js'></script>".utf8)
                .write(to: directory.appendingPathComponent("index.html"))
            try Data("document.title = 'script-ready';".utf8).write(to: directory.appendingPathComponent("main.js"))
        }.value
        let manager = BrowserSessionManager(), session = UUID()
        var openedTab: UUID?
        do {
            let tab = try await manager.openTab(
                sessionID: session, url: URL(string: "etos://sandbox/\(name)/index.html")!,
                allowedAgentNavigationHosts: ["etos://sandbox"]
            )
            openedTab = tab.id
            let result = try await manager.evaluateJavaScript(
                sessionID: session, tabID: tab.id,
                script: "document.title + '|' + document.querySelector('h1').textContent",
                allowedAgentNavigationHosts: []
            )
            #expect(result == .string("script-ready|手表本地页面"))
            _ = try manager.closeTab(sessionID: session, tabID: tab.id)
        } catch {
            if let openedTab { _ = try? manager.closeTab(sessionID: session, tabID: openedTab) }
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
            throw error
        }
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }
}
