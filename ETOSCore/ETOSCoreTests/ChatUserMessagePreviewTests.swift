import Foundation
import Testing
@testable import ETOSCore

@Suite("长用户消息预览")
struct ChatUserMessagePreviewTests {
    @Test("空文本、短文本和恰好到达阈值的文本保持原样")
    func keepsContentWithinLimit() {
        for content in ["", "**短消息**\n第二行", String(repeating: "字", count: ChatUserMessagePreview.defaultCharacterLimit)] {
            let preview = ChatUserMessagePreview(content: content)
            #expect(preview.content == content)
            #expect(!preview.isTruncated)
        }
    }

    @Test("超长文本只保留阈值内的前缀和省略号")
    func truncatesLongContent() {
        let prefix = String(repeating: "字", count: ChatUserMessagePreview.defaultCharacterLimit)
        let preview = ChatUserMessagePreview(content: prefix + "完整尾部")
        #expect(preview.content == prefix + "…")
        #expect(preview.isTruncated)
    }

    @Test("截断保留完整 emoji 和组合音标")
    func preservesGraphemeClusters() {
        for character in ["👨‍👩‍👧‍👦", "e\u{301}", "🇨🇳"] {
            let prefix = String(repeating: character, count: ChatUserMessagePreview.defaultCharacterLimit)
            let preview = ChatUserMessagePreview(content: prefix + "尾")
            #expect(preview.content == prefix + "…")
            #expect(preview.isTruncated)
        }
    }

    @Test("大量 LF、CRLF 与 Unicode 换行不会在字符阈值之前截断")
    func doesNotLimitLines() {
        for separator in ["\n", "\r\n", "\r", "\u{2028}"] {
            let content = Array(repeating: "行", count: 50).joined(separator: separator)
            let preview = ChatUserMessagePreview(content: content)
            #expect(!preview.isTruncated)
            #expect(preview.content == content)
            #expect(ChatUserMessagePreview(content: content, characterLimit: 3).content == "行" + separator + "行…")
        }
    }

    @Test("自定义阈值按完整字符计数并支持缩短和放宽")
    func honorsCustomCharacterLimit() {
        let content = "A👨‍👩‍👧‍👦e\u{301}Z"
        for limit in 1...3 {
            let preview = ChatUserMessagePreview(content: content, characterLimit: limit)
            #expect(preview.content == String(content.prefix(limit)) + "…")
            #expect(preview.isTruncated)
        }
        #expect(!ChatUserMessagePreview(content: content, characterLimit: 4).isTruncated)
        #expect(ChatUserMessagePreview(content: content, characterLimit: 8).content == content)
    }

    @MainActor
    @Test("列表占位与截断都不改写原文、版本和附件，导出默认保留全文")
    func keepsBusinessMessageIntact() async {
        var message = ChatMessage(role: .user, content: "旧版本", imageFileNames: ["photo.png"], fileFileNames: ["notes.txt"])
        message.addVersion(String(repeating: "完整输入", count: 2_000))
        let state = ChatMessageRenderState(message: message, defersUserContentPreparation: true)
        #expect(state.visualMessage.content == "…")
        #expect(state.message == message)

        let preview = await Task.detached { [message] in
            ChatUserMessagePreview(content: message.content)
        }.value
        var visualMessage = message
        visualMessage.content = preview.content
        state.updateVisualMessage(visualMessage, isUserContentTruncated: preview.isTruncated)

        #expect(state.isUserContentTruncated)
        #expect(state.message == message)
        #expect(state.message.getAllVersions() == message.getAllVersions())
        #expect(state.visualMessage.imageFileNames == message.imageFileNames)
        #expect(state.visualMessage.fileFileNames == message.fileFileNames)
        #expect(ChatMessageRenderState(message: message).visualMessage.content == message.content)

        var editedMessage = message
        editedMessage.content = "缩短后的输入"
        state.update(with: editedMessage)
        state.updateVisualMessage(editedMessage)
        #expect(!state.isUserContentTruncated)
        #expect(state.visualMessage.content == editedMessage.content)
    }

    @MainActor
    @Test("助手长回复和原有错误响应不进入用户消息占位")
    func keepsOtherRolesUnchanged() {
        for role in [MessageRole.assistant, .system, .tool, .error] {
            let message = ChatMessage(role: role, content: String(repeating: "回复", count: 2_000))
            let state = ChatMessageRenderState(message: message, defersUserContentPreparation: true)
            #expect(state.visualMessage == message)
            #expect(!state.isUserContentTruncated)
        }
    }
}
