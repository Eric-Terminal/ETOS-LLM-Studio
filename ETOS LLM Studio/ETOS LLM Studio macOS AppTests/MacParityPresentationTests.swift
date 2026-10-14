import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacParityPresentationTests {
    @Test("相册只收录助手附件，每条消息去重并关联最近的用户提示词")
    func galleryMessages() {
        let user = ChatMessage(role: .user, content: "画一只猫", imageFileNames: ["reference.png"])
        let assistant = ChatMessage(role: .assistant, content: "", imageFileNames: ["cat.png", "cat.png"])
        let items = MacImageGalleryItem.prepare(messages: [user, assistant], sessionID: UUID(), directory: URL(fileURLWithPath: "/tmp"))
        #expect(items.count == 1)
        #expect(items.first?.fileName == "cat.png")
        #expect(items.first?.sourcePrompt == "画一只猫")
        #expect(items.first?.removingImage() == nil)
    }

    @Test("移除图片同步排除标记，保留消息中的思考与其他附件")
    func galleryRemovalRetainsOtherPayloads() {
        var message = ChatMessage(role: .assistant, content: "", imageFileNames: ["one.png", "two.png"])
        message.reasoningContent = "保留的思考"
        message.modelExcludedImageFileNames = ["one.png", "two.png"]
        let items = MacImageGalleryItem.prepare(messages: [message], sessionID: UUID(), directory: URL(fileURLWithPath: "/tmp"))
        let edited = items.first { $0.fileName == "one.png" }?.removingImage()
        #expect(edited?.imageFileNames == ["two.png"])
        #expect(edited?.modelExcludedImageFileNames == ["two.png"])
        #expect(edited?.reasoningContent == "保留的思考")
    }

    @Test("流式淡入保留组合字符边界和已有时间戳，非追加替换不重播旧字符")
    func revealAppendAndReplacement() {
        let first = MacStreamingReveal(source: "👩‍💻中", previous: nil, now: 10)
        let second = MacStreamingReveal(source: "👩‍💻中文", previous: first, now: 10.1)
        #expect(second.attributes[0] == first.attributes[0])
        #expect(second.attributes[first.utf16Length]?.startedAt == 10.1)
        let replaced = MacStreamingReveal(source: "新的内容", previous: second, now: 10.2)
        #expect(replaced.attributes.isEmpty)
        let long = MacStreamingReveal(source: String(repeating: "👨‍👩‍👧‍👦", count: 500), previous: nil, now: 20)
        #expect(long.attributes.count == 160)
        let finished = MacStreamingReveal(source: long.source, previous: long, now: 21)
        #expect(finished.attributes.isEmpty)
    }
}
