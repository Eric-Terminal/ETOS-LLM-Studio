import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacMessageDisplayTests {
    @Test("用户文字保留 Markdown 字面标记，助手只在开启渲染时准备块级内容")
    func markdownIsLimitedToAssistantContent() {
        let source = "# 标题\n\n- **项目**\n\n```swift\nlet value = 1\n```"
        let assistant = ChatMessage(role: .assistant, content: source)
        let enabled = MacMessagePresentation.prepare(assistant, markdown: true)
        #expect(enabled.content.markdown != nil)
        #expect(enabled.content.source == source)
        let disabled = MacMessagePresentation.prepare(assistant, markdown: false)
        #expect(disabled.content.markdown == nil)
        #expect(String(disabled.content.plain.characters) == source)
        let user = MacMessagePresentation.prepare(.init(role: .user, content: source), markdown: true)
        #expect(user.content.markdown == nil)
        #expect(String(user.content.plain.characters) == source)
    }

    @Test("折叠以完整字符为界并保留换行，消息原文不参与截断")
    func previewPreservesOriginalAndGraphemes() {
        let source = "👨‍👩‍👧‍👦\ne\u{301}后文"
        let message = ChatMessage(role: .user, content: source)
        let row = MacMessagePresentation.prepare(message, markdown: false, userPreviewLimit: 3)
        #expect(row.userPreview?.source == "👨‍👩‍👧‍👦\ne\u{301}…")
        #expect(row.message == message)
        #expect(row.content.source == source)
        let full = MacMessagePresentation.prepare(message, markdown: false, userPreviewLimit: source.count)
        #expect(full.userPreview == nil)
        #expect(MacMessagePresentation.prepare(.init(role: .assistant, content: source), markdown: false, userPreviewLimit: 1).userPreview == nil)
    }

    @Test("改变字符上限刷新旧消息预览，关闭 Markdown 不复用旧排版")
    func settingsInvalidateDisplayCache() async throws {
        let store = MacMessagePresentationStore()
        let messages = [ChatMessage(role: .user, content: "123456"), ChatMessage(role: .assistant, content: "**答复**")]
        let first = try await store.prepare(messages, markdown: true, language: "en", userPreviewLimit: 3)
        #expect(first[0].userPreview != nil)
        #expect(first[1].content.markdown != nil)
        let changed = try await store.prepare(messages, markdown: false, language: "en", userPreviewLimit: 6)
        #expect(changed[0].userPreview == nil)
        #expect(changed[1].content.markdown == nil)
        #expect(changed.map(\.message) == messages)
    }

    @Test("未变化正文复用解析对象，思考通道和删除历史不保留错误缓存")
    func parsedTextCacheKeepsChannelsSeparate() {
        var cache = MacMessageTextCache()
        let id = UUID()
        let first = cache.prepare("原文", messageID: id, markdown: true)
        #expect(cache.prepare("原文", messageID: id, markdown: true).id == first.id)
        #expect(cache.prepare("原文", messageID: id, reasoning: true, markdown: true).id != first.id)
        #expect(cache.prepare("新内容", messageID: id, markdown: true).id != first.id)
        let latest = cache.prepare("原文", messageID: id, markdown: true)
        cache.retain([])
        #expect(cache.prepare("原文", messageID: id, markdown: true).id != latest.id)
    }

    @Test("删除最后一条视觉正则时恢复原文，解析缓存不能残留替换结果")
    func removingVisualRulesRestoresSource() async throws {
        let store = MacMessagePresentationStore()
        let message = ChatMessage(role: .assistant, content: "旧文字")
        let rule = MessageRegexRule(pattern: "旧", replacement: "新", scopes: [.assistant], mode: .visualOnly)
        let modified = try await store.prepare([message], markdown: true, language: "en", rules: [rule])
        #expect(modified[0].content.source == "新文字")
        #expect(modified[0].message.content == "旧文字")
        let restored = try await store.prepare([message], markdown: true, language: "en")
        #expect(restored[0].content.source == "旧文字")
        #expect(restored[0].content.id != modified[0].content.id)
    }

    @Test("流式思考使用纯文本预览，出现正文收起，完成后才准备完整排版")
    func reasoningPresentationFollowsRequest() async throws {
        let store = MacMessagePresentationStore()
        var message = ChatMessage(role: .assistant, content: "")
        message.isReceivingStream = true
        message.reasoningContent = "**思考内容**"
        let live = try await store.prepare([message], markdown: true, language: "en", activeResponseID: message.id)
        #expect(live[0].activity.canPreviewReasoning)
        #expect(live[0].reasoning?.markdown == nil)
        message.content = "答复"
        let body = try await store.prepare([message], markdown: true, language: "en", activeResponseID: message.id)
        #expect(!body[0].activity.canPreviewReasoning)
        #expect(body[0].reasoning?.markdown == nil)
        let finished = try await store.prepare([message], markdown: true, language: "en")
        #expect(!finished[0].activity.canPreviewReasoning)
        #expect(finished[0].reasoning?.markdown != nil)
    }

    @Test("历史思考不会自动展开，附件正文也结束仅思考预览")
    func reasoningPreviewRequiresEmptyCurrentResponse() {
        var message = ChatMessage(role: .assistant, content: " \n")
        message.reasoningContent = "分析"
        #expect(MacMessageActivity(message: message, activeResponseID: message.id).canPreviewReasoning)
        #expect(!MacMessageActivity(message: message, activeResponseID: nil).canPreviewReasoning)
        message.imageFileNames = ["image.png"]
        #expect(!MacMessageActivity(message: message, activeResponseID: message.id).canPreviewReasoning)
        message.imageFileNames = nil
        message.responseMetrics = .init(requestStartedAt: .now, responseCompletedAt: .now)
        #expect(!MacMessageActivity(message: message, activeResponseID: message.id).canPreviewReasoning)
    }

    @Test("Mac 显示文档声明数据库复用、全文保留及向导确认边界")
    func guideDocumentsDisplayBoundaries() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("显示设置") && chinese.contains("完整原文"))
        #expect(english.contains("Display Settings") && english.contains("native confirmation"))
        #expect(chinese.contains("所有配色和时间段编辑都是草稿") && chinese.contains("不能保存、新增、排序、删除"))
        #expect(english.contains("they cannot save, add, reorder, delete") && english.contains("drain accepted writes"))
    }
}
