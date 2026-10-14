import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacAdvancedMarkdownTests {
    @Test("流式提交块保持解析身份，末尾增长不重建已完成段落")
    func streamingRetainsCommittedBlocks() async throws {
        let store = MacStreamingMarkdownStore(), id = UUID()
        let first = try await store.prepare("第一段\n\n末尾", messageID: id, advanced: true)
        let second = try await store.prepare("第一段\n\n末尾继续", messageID: id, advanced: true)
        let old = try #require(first.stream?.blocks.first)
        let new = try #require(second.stream?.blocks.first)
        #expect(old.id == new.id)
        #expect(old.text.id == new.text.id)
        #expect(second.stream?.active?.displayText == "末尾继续")
        #expect(second.markdown == nil)
        #expect(second.source == "第一段\n\n末尾继续")
    }

    @Test("重试替换内容重置块代次，清理后同一消息不能复用旧块")
    func streamingResetAndRetention() async throws {
        let store = MacStreamingMarkdownStore(), id = UUID()
        let first = try await store.prepare("旧段落\n\n末尾", messageID: id, advanced: true)
        let next = try await store.prepare("新段落\n\n新末尾", messageID: id, advanced: true)
        #expect(first.stream?.blocks.first?.id != next.stream?.blocks.first?.id)
        #expect(next.stream?.blocks.first?.text.source.contains("新段落") == true)
        let oldID = next.stream?.blocks.first?.text.id
        await store.retain([])
        let fresh = try await store.prepare("新段落\n\n新末尾", messageID: id, advanced: true)
        #expect(fresh.stream?.blocks.first?.text.id != oldID)
    }

    @Test("流式未闭合代码保留源码，完成交接直接得到完整 Markdown")
    func finalHandoffKeepsSource() async throws {
        let store = MacMessagePresentationStore()
        var message = ChatMessage(role: .assistant, content: "首段\n\n```swift\nlet value = 1")
        message.isReceivingStream = true
        let live = try await store.prepare([message], markdown: true, language: "en", activeResponseID: message.id, advanced: true)
        let active = try #require(live.first?.content.stream?.active)
        #expect(active.presentation == .code(language: "swift"))
        #expect(active.displayText.contains("let value = 1"))
        message.isReceivingStream = false
        let final = try await store.prepare([message], markdown: true, language: "en", advanced: true)
        #expect(final[0].content.stream == nil)
        #expect(final[0].content.markdown != nil)
        #expect(final[0].content.source == message.content)
        #expect(final[0].message.content == message.content)
    }

    @Test("高级开关刷新历史缓存，普通消息及用户原文不启动网页")
    func rendererSettingsInvalidateCache() async throws {
        let store = MacMessagePresentationStore()
        let messages = [ChatMessage(role: .assistant, content: "$x^2$"), ChatMessage(role: .user, content: "$x^2$")]
        let plain = try await store.prepare(messages, markdown: true, language: "en", advanced: false)
        let rich = try await store.prepare(messages, markdown: true, language: "en", advanced: true)
        #expect(plain[0].content.advanced == nil)
        #expect(rich[0].content.advanced?.formulas.first?.latex == "x^2")
        #expect(rich[0].content.id != plain[0].content.id)
        #expect(rich[1].content.advanced == nil)
        let disabled = try await store.prepare(messages, markdown: false, language: "en", advanced: true)
        #expect(disabled[0].content.advanced == nil)
        #expect(MacPreparedMessageText("普通 **文本**", markdown: true, advanced: true).advanced == nil)
    }

    @Test("活动思考始终保持纯文本，完成后才准备公式")
    func reasoningWaitsForCompletion() async throws {
        let store = MacMessagePresentationStore()
        var message = ChatMessage(role: .assistant, content: "")
        message.isReceivingStream = true; message.reasoningContent = "$x$"
        let live = try await store.prepare([message], markdown: true, language: "en", activeResponseID: message.id, advanced: true)
        #expect(live[0].reasoning?.advanced == nil)
        let final = try await store.prepare([message], markdown: true, language: "en", advanced: true)
        #expect(final[0].reasoning?.advanced?.formulas.first?.latex == "x")
    }

    @Test("网页载荷转义脚本结束标签，公式和图表按需加载且不带聊天工具桥")
    func webDocumentIsDataOnly() throws {
        let source = ETAdvancedMarkdownSource("$x$ </script><script>alert('原文')</script>")
        let style = MacAdvancedMarkdownDocument.Style(dark: true, pointSize: 15, lineSpacing: 4,
            bodyFont: "字体 </script>", emphasisFont: nil, strongFont: nil, codeFont: nil,
            bodyColor: "#FFFFFFFF", emphasisColor: "#FFFFFFFF", strongColor: "#FFFFFFFF", codeColor: "#FFFFFFFF")
        let document = try MacAdvancedMarkdownDocument(source: source, style: style)
        #expect(!document.html.contains("</script><script>alert"))
        #expect(document.html.contains("\\u003c"))
        #expect(document.html.contains("katex@0.19.0"))
        #expect(!document.html.contains("mermaid@12.1.0"))
        #expect(document.html.contains("connect-src 'none'"))
        #expect(document.html.contains("trust:false"))
        #expect(!document.html.contains("etosRoleplay"))
        let diagram = try MacAdvancedMarkdownDocument(source: .init("```mermaid\ngraph TD; A-->B\n```"), style: style)
        #expect(diagram.html.contains("mermaid@12.1.0"))
        #expect(!diagram.html.contains("katex@0.19.0"))
    }

    @Test("中英文向导说明高级渲染联网与失败回退，流式模式不是请求流式开关")
    func guideExplainsRenderingBoundaries() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("jsDelivr") && chinese.contains("原文回退"))
        #expect(english.contains("jsDelivr") && english.contains("request streaming"))
        #expect(ChatStreamingDisplayMode.gentle.uiPublishInterval > ChatStreamingDisplayMode.immediate.uiPublishInterval)
    }
}
