import Combine
import ETOSCore
import MarkdownUI
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import ETOS_LLM_Studio_App

@Suite("普通聊天代码预览", .serialized)
@MainActor
struct CodePreviewRuntimeTests {
    enum Scenario: CaseIterable {
        case basic, advanced, surroundingMath, precedingDollar, fullDocument, streaming
    }

    @Test("普通会话 HTML 代码框可打开并运行网页", arguments: Scenario.allCases)
    func previewsHTMLCodeBlock(scenario: Scenario) async throws {
        let advanced = scenario != .basic
        let config = AppConfigStore.shared
        // 配置加载与 Markdown 准备均需完成，避免把启动占位或错误渲染分支计为通过。
        await config.waitForPersistentStoreLoaded()
        let saved = (config.enableMarkdown, config.enableAdvancedRenderer, config.enableBackground)
        config.enableMarkdown = true
        config.enableAdvancedRenderer = advanced
        config.enableBackground = false
        defer {
            config.enableMarkdown = saved.0
            config.enableAdvancedRenderer = saved.1
            config.enableBackground = saved.2
        }
        let fragment = """
        <div id='code-preview-probe' style='margin-top:100px;color:#0759bf'>等待脚本</div>
        <button id='code-action' onclick="this.textContent = '交互成功'">点我</button>
        <script>
        const $ = id => document.getElementById(id);
        $('code-preview-probe').textContent = '脚本运行成功';
        const literal = String.raw`\\frac{1}{2}`;
        </script>
        """
        let source = scenario == .fullDocument
            ? "<!doctype html><html><head><meta charset='utf-8'></head><body>\(fragment)</body></html>"
            : fragment
        let content: String
        switch scenario {
        case .surroundingMath:
            content = "公式 $x^2$\n```html\n\(source)\n```\n后文 $y^2$"
        case .precedingDollar:
            content = "价格 $5\n```html\n\(source)\n```\n后文"
        default:
            content = "前文\n```html\n\(source)\n```\n后文"
        }
        var message = ChatMessage(role: .assistant, content: scenario == .streaming ? "正在生成网页" : content)
        let session = ChatSession(id: UUID(), name: "代码预览回归", isTemporary: true)
        // 角色卡绑定会自动提取 HTML，绕开这次需要验证的普通代码框。
        #expect(RoleplayStore.shared.binding(sessionID: session.id) == nil)
        let service = ChatService()
        let model = ChatViewModel(chatService: service)
        model.enableMarkdown = true
        model.enableAdvancedRenderer = advanced
        model.enableBackground = false
        service.chatSessionsSubject.send([session])
        service.currentSessionSubject.send(session)
        if scenario == .streaming { service.runningSessionIDsSubject.send([session.id]) }
        service.messagesForSessionSubject.send([message])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: NavigationStack {
            ChatView(scrollCoordinator: ChatScrollCoordinator()).environmentObject(model)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        if scenario == .streaming {
            for _ in 0..<200 {
                if model.isSendingMessage, model.messages.first?.id == message.id { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.isSendingMessage)
            message.content = content
            service.messagesForSessionSubject.send([message])
            for _ in 0..<200 {
                if model.messages.first?.message.content == content { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            service.runningSessionIDsSubject.send([])
        }
        for _ in 0..<400 {
            if model.preparedMarkdownByMessageID[message.id]?.sourceText == content { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.enableMarkdown)
        #expect(model.enableAdvancedRenderer == advanced)
        #expect(model.messages.first?.roleplayHTML == nil)
        let prepared = try #require(model.preparedMarkdownByMessageID[message.id])
        #expect(prepared.sourceText == content)
        #expect(prepared.containsMathContent == (scenario == .surroundingMath))
        #expect(prepared.mathRenderText.contains(source))
        if scenario == .surroundingMath {
            #expect(prepared.nativeMathMarkdownContent?.renderMarkdown().contains(source) == true)
        }
        var previewButton: NSObject?
        for _ in 0..<200 {
            host.view.layoutIfNeeded()
            previewButton = accessibilityObjects(host.view).first {
                $0.accessibilityLabel == NSLocalizedString("预览代码", comment: "")
            }
            if previewButton != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // 代码框出现后等一次布局绘制；公式图片独立加载，此帧不作为公式已完成的证据。
        try await Task.sleep(for: .seconds(1))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(png, named: "普通代码框-\(scenario).png")
        let button = try #require(previewButton, "HTML 代码框应有预览按钮")
        // 使用真实 SwiftUI 按钮的系统动作，不能直接创建预览 WebView 替代入口验证。
        #expect(button.accessibilityActivate(), "通过真实预览按钮打开页面")
        var loadedWebView: WKWebView?
        for _ in 0..<400 {
            for webView in webViews(window) {
                if (try? await webView.evaluateJavaScript("document.getElementById('code-preview-probe') !== null")) as? Bool == true {
                    loadedWebView = webView
                }
            }
            if let loadedWebView, !loadedWebView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let webView = try #require(loadedWebView, "预览页应加载 HTML")
        #expect(webView.bounds.width > 200)
        #expect(webView.bounds.height > 200)
        #expect(try await webView.evaluateJavaScript("document.getElementById('code-preview-probe').textContent") as? String == "脚本运行成功")
        #expect(try await webView.evaluateJavaScript("literal") as? String == #"\frac{1}{2}"#)
        #expect(try await webView.evaluateJavaScript("document.getElementById('code-action').click(); document.getElementById('code-action').textContent") as? String == "交互成功")
        for _ in 0..<200 {
            if host.presentedViewController?.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // DOM 更新完成与 WebKit 提交显示帧并非同一时刻。
        try await Task.sleep(for: .milliseconds(200))
        let previewPNG = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(previewPNG, named: "代码预览页-\(scenario).png")
        if scenario == .surroundingMath {
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
            // 返回后补采一帧，便于复核代码外的异步公式图片与网页预览能否共存。
            try await Task.sleep(for: .seconds(2))
            host.view.layoutIfNeeded()
            let returnedPNG = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(returnedPNG, named: "混排公式-返回聊天.png")
        }
    }

    private func accessibilityObjects(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 20 else { return [] }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else if object.accessibilityElementCount() > 0 && object.accessibilityElementCount() < 1000 {
            children = (0..<object.accessibilityElementCount()).compactMap {
                object.accessibilityElement(at: $0) as? NSObject
            }
        } else if let view = object as? UIView {
            children = view.subviews
        }
        return [object] + children.flatMap { accessibilityObjects($0, depth: depth + 1) }
    }

    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) }
    }
}
