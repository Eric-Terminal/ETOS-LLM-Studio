import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import ETOS_LLM_Studio_App

@Suite("真实聊天 HTML 内联显示", .serialized)
@MainActor
struct InlineHTMLChatRuntimeTests {
    enum DisplayMode: CaseIterable {
        case plain, fenced, fullDocument, advancedMarkdown, noBubble, scaledFont
    }

    @Test("角色卡 HTML 从会话消息进入真实聊天气泡后仍可显示和交互", arguments: DisplayMode.allCases)
    func rendersRoleplayHTMLInChat(mode: DisplayMode) async throws {
        let source = "<div id='etos-inline-probe' style='height:240px;background:#0b72ff;color:white'>内联网页<button id='action' onclick=\"this.textContent='交互成功'\">点我</button></div>"
        let content: String
        switch mode {
        case .fenced, .advancedMarkdown:
            content = "前文\n```html\n\(source)\n```"
        case .fullDocument:
            content = "<!doctype html><html><head><style>body { margin: 0; }</style></head><body>\(source)</body></html>"
        default:
            content = source
        }
        let message = ChatMessage(role: .assistant, content: content)
        let session = ChatSession(id: UUID(), name: "内联运行回归", isTemporary: true)
        RoleplayStore.shared.upsertBinding(SessionRoleplayBinding(sessionID: session.id, helperScriptsEnabled: false))
        defer { RoleplayStore.shared.removeBinding(sessionID: session.id) }
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let saved = (config.enableMarkdown, config.enableAdvancedRenderer, config.enableBackground, config.enableNoBubbleUI)
        let savedFont = (FontLibrary.isCustomFontEnabled, FontLibrary.fallbackScope, FontLibrary.customFontScale)
        config.enableMarkdown = true
        config.enableAdvancedRenderer = mode == .advancedMarkdown
        config.enableBackground = false
        config.enableNoBubbleUI = mode == .noBubble
        FontLibrary.updateRuntimeSettings(isCustomFontEnabled: false, fallbackScope: .segment, customFontScale: mode == .scaledFont ? 1.5 : 1)
        defer {
            config.enableMarkdown = saved.0
            config.enableAdvancedRenderer = saved.1
            config.enableBackground = saved.2
            config.enableNoBubbleUI = saved.3
            FontLibrary.updateRuntimeSettings(isCustomFontEnabled: savedFont.0, fallbackScope: savedFont.1, customFontScale: savedFont.2)
        }
        let service = ChatService()
        let model = ChatViewModel(chatService: service)
        service.chatSessionsSubject.send([session])
        service.currentSessionSubject.send(session)
        service.messagesForSessionSubject.send([message])
        for _ in 0..<200 {
            if model.messages.first?.message.id == message.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = try #require(model.messages.first)
        #expect(state.message.id == message.id)
        // 消息先进入列表，HTML 再由后台任务准备；等待真实任务，避免把调度延迟判成渲染失败。
        if state.roleplayHTML?.containsHTML != true {
            let preparation = try #require(model.visualMessagePrepareTasks[message.id], "消息应已启动 HTML 预处理")
            await preparation.value
        }
        #expect(state.roleplayHTML?.containsHTML == true)
        #expect(model.enableMarkdown)
        #expect(model.enableAdvancedRenderer == (mode == .advancedMarkdown))
        #expect(model.enableNoBubbleUI == (mode == .noBubble))
        #expect(FontLibrary.customFontScale == (mode == .scaledFont ? 1.5 : 1))
        let canvas = NavigationStack {
            ChatView(scrollCoordinator: ChatScrollCoordinator()).environmentObject(model)
        }
        let host = try HostedInlineHTML(canvas)
        defer { host.dispose() }
        let webView = try await host.waitForWebView(containing: "etos-inline-probe", minimumHeight: 240)
        #expect(webView.bounds.width > 200)
        #expect(webView.bounds.height >= 240)
        let frame = webView.convert(webView.bounds, to: host.window)
        #expect(frame.intersects(host.window.bounds))
        let result = try await webView.evaluateJavaScript("document.getElementById('action').click(); document.getElementById('action').textContent")
        #expect(result as? String == "交互成功")
        let inlineContent = try #require(InlineHTMLContentRegistry.shared.contents(messageID: message.id, versionIndex: 0).first)
        let capture = try #require(inlineContent.capturePNG)
        let png = try await capture()
        #expect(!png.isEmpty)
        Attachment.record(png, named: "内联网页-\(mode).png")
    }

    @Test("流式回复完成及切换消息版本后仍显示当前 HTML")
    func rendersUpdatedHTMLInChat() async throws {
        var message = ChatMessage(role: .assistant, content: "正在生成网页")
        let session = ChatSession(id: UUID(), name: "内联更新回归", isTemporary: true)
        RoleplayStore.shared.upsertBinding(SessionRoleplayBinding(sessionID: session.id, helperScriptsEnabled: false))
        defer { RoleplayStore.shared.removeBinding(sessionID: session.id) }
        let service = ChatService()
        let model = ChatViewModel(chatService: service)
        service.chatSessionsSubject.send([session])
        service.currentSessionSubject.send(session)
        service.runningSessionIDsSubject.send([session.id])
        service.messagesForSessionSubject.send([message])
        let host = try HostedInlineHTML(NavigationStack {
            ChatView(scrollCoordinator: ChatScrollCoordinator()).environmentObject(model)
        })
        defer { host.dispose() }
        for _ in 0..<200 {
            if model.messages.first?.message.id == message.id, model.isSendingMessage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.isSendingMessage)
        message.content = "<div id='streamed-html' style='height:260px'>生成完毕</div>"
        service.messagesForSessionSubject.send([message])
        _ = try await host.waitForWebView(containing: "streamed-html", minimumHeight: 260)
        service.runningSessionIDsSubject.send([])
        for _ in 0..<200 {
            if !model.isSendingMessage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isSendingMessage)
        _ = try await host.waitForWebView(containing: "streamed-html", minimumHeight: 260)

        message.addVersion("<div id='second-version' style='height:300px'>第二版网页</div>")
        service.messagesForSessionSubject.send([message])
        let second = try await host.waitForWebView(containing: "second-version", minimumHeight: 300)
        #expect(try await second.evaluateJavaScript("document.getElementById('streamed-html') === null") as? Bool == true)
        message.switchToVersion(0)
        service.messagesForSessionSubject.send([message])
        let first = try await host.waitForWebView(containing: "streamed-html", minimumHeight: 260)
        #expect(try await first.evaluateJavaScript("document.getElementById('second-version') === null") as? Bool == true)
    }

    @Test("已保存角色卡的正则网页在开关恢复与显示内容更新后继续渲染")
    func rendersPersistedRoleplayRegexAndUpdates() async throws {
        let store = RoleplayStore.shared
        let character = RoleplayCharacter(name: "网页回归", regexRules: [RoleplayRegexRule(
            findRegex: "<StatusPlaceHolderImpl/>",
            replaceString: "```html\n<div id='regex-html' style='height:240px'>正则状态栏</div>\n```",
            placements: [.aiOutput],
            markdownOnly: true
        )])
        let message = ChatMessage(role: .assistant, content: "叙事正文\n<StatusPlaceHolderImpl/>")
        let session = ChatSession(id: UUID(), name: "角色配置回归", isTemporary: true)
        var binding = SessionRoleplayBinding(sessionID: session.id, characterIDs: [character.id], helperScriptsEnabled: false)
        store.upsertCharacter(character)
        store.upsertBinding(binding)
        Persistence.saveMessages([message], for: session.id)
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        defer {
            store.removeBinding(sessionID: session.id)
            store.deleteCharacter(id: character.id)
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        // 清空内存缓存后从数据库重读，覆盖已有角色卡的配置恢复路径。
        store.invalidateCache()
        #expect(store.binding(sessionID: session.id)?.htmlRenderingEnabled == true)
        #expect(store.character(id: character.id)?.regexRules.count == 1)
        let service = ChatService()
        let model = ChatViewModel(chatService: service)
        service.chatSessionsSubject.send([session])
        service.currentSessionSubject.send(session)
        service.messagesForSessionSubject.send([message])
        let host = try HostedInlineHTML(NavigationStack {
            ChatView(scrollCoordinator: ChatScrollCoordinator()).environmentObject(model)
        })
        defer { host.dispose() }
        let initialWebView = try await host.waitForWebView(containing: "regex-html", minimumHeight: 240)

        binding.htmlRenderingEnabled = false
        store.upsertBinding(binding)
        for _ in 0..<200 {
            if model.messages.first?.roleplayHTML == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.messages.first?.roleplayHTML == nil)
        // 模型状态关闭还不够，已显示的网页也必须退出真实聊天视图树。
        for _ in 0..<200 {
            host.host.view.layoutIfNeeded()
            if !initialWebView.isDescendant(of: host.host.view) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!initialWebView.isDescendant(of: host.host.view))
        binding.htmlRenderingEnabled = true
        store.upsertBinding(binding)
        let original = try await host.waitForWebView(containing: "regex-html", minimumHeight: 240)
        // 使用网页公开桥接入口，让原生端定位持久化消息并发布显示更新通知。
        _ = try await original.evaluateJavaScript("""
        SillyTavern.updateMessageBlock(0, {message: "<div id='updated-html' style='height:280px'>脚本更新后的状态栏</div>"});
        """)
        let updated = try await host.waitForWebView(containing: "updated-html", minimumHeight: 280)
        #expect(try await updated.evaluateJavaScript("document.getElementById('regex-html') === null") as? Bool == true)
    }

    @Test("工具网页在真实 SwiftUI 卡片内有可见尺寸")
    func rendersToolWidgetInline() async throws {
        let payload = try #require(ToolWidgetPayloadParser.parse(from: #"{"widget_code":"<div id='etos-inline-probe'>工具网页</div>","title":"运行回归","inline_aspect_ratio":"16:9"}"#))
        let host = try HostedInlineHTML(ToolWidgetRendererCard(payload: payload).padding())
        defer { host.dispose() }
        let webView = try await host.waitForWebView(containing: "etos-inline-probe")
        #expect(webView.bounds.width > 200)
        #expect(webView.bounds.height > 100)
    }
}

@MainActor
private final class HostedInlineHTML<Content: View> {
    let window: UIWindow
    let host: UIHostingController<Content>

    init(_ content: Content) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
    }

    func waitForWebView(containing elementID: String, minimumHeight: CGFloat = 100) async throws -> WKWebView {
        var found: WKWebView?
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutIfNeeded()
            for webView in webViews(in: host.view) {
                if let exists = try? await webView.evaluateJavaScript("document.getElementById('\(elementID)') !== null"), exists as? Bool == true {
                    found = webView
                    if !webView.isLoading, webView.bounds.width > 200, webView.bounds.height >= minimumHeight { return webView }
                }
            }
        }
        let webView = try #require(found, "真实视图树中没有加载目标 HTML 的 WebView：\(elementID)")
        #expect(!webView.isLoading, "目标网页应完成加载：\(elementID)")
        #expect(webView.bounds.width > 200, "目标网页应有可见宽度：\(elementID)")
        #expect(webView.bounds.height >= minimumHeight, "目标网页应展开到内容高度：\(elementID)")
        return webView
    }

    func dispose() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }
}
