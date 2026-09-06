// ============================================================================
// MarkdownImageReferenceSupportTests.swift
// ============================================================================
// ETOSCoreTests
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct MarkdownImageReferenceSupportTests {
    @Test("只提取可下载的 Markdown 图片，不把普通链接当成图片")
    func extractsDownloadableImagesOnly() throws {
        let source = """
        [站点](https://example.com)

        ![远程图片](https://example.com/a.png "标题")

        ![相对图片](assets/local.png)
        """

        let references = MarkdownImageReferenceSupport.downloadableReferences(in: source)

        #expect(references.map(\.source) == ["https://example.com/a.png"])
        let reference = try #require(references.first)
        let range = try #require(Range(reference.sourceUTF16Range, in: source))
        #expect(String(source[range]) == "![远程图片](https://example.com/a.png \"标题\")")
    }

    @Test("支持引用式图片与 Unicode 前缀的源码范围")
    func preservesReferenceImageRangeAfterUnicode() throws {
        let source = "前缀🙂 ![示例][image]\n\n[image]: https://example.com/image.webp"

        let reference = try #require(
            MarkdownImageReferenceSupport.downloadableReferences(in: source).first
        )
        let range = try #require(Range(reference.sourceUTF16Range, in: source))

        #expect(reference.source == "https://example.com/image.webp")
        #expect(String(source[range]) == "![示例][image]")
    }

    @Test("模型附件列表排除仅供本地显示的图片")
    func excludesDisplayOnlyImagesFromModelAttachments() {
        let message = ChatMessage(
            role: .assistant,
            content: "正文",
            imageFileNames: ["generated.png", "inline.png"],
            modelExcludedImageFileNames: ["inline.png"]
        )

        #expect(message.modelVisibleImageFileNames == ["generated.png"])
    }

    @Test("模型排除图片列表可随消息编码往返")
    func excludedImagesCodableRoundTrip() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "正文",
            imageFileNames: ["inline.png"],
            modelExcludedImageFileNames: ["inline.png"]
        )

        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded.modelExcludedImageFileNames == ["inline.png"])
        #expect(decoded.modelVisibleImageFileNames.isEmpty)
    }

    @Test("仅展示图片列表可随消息持久化")
    func excludedImagesPersistenceRoundTrip() throws {
        try withStore { store in
            let session = ChatSession(id: UUID(), name: "图片附件", isTemporary: false)
            let message = ChatMessage(
                role: .assistant,
                content: "正文",
                imageFileNames: ["inline.png"],
                modelExcludedImageFileNames: ["inline.png"]
            )

            store.saveChatSessions([session])
            store.saveMessages([message], for: session.id)

            let restored = try #require(store.loadMessages(for: session.id).first)
            #expect(restored.modelExcludedImageFileNames == ["inline.png"])
            #expect(restored.modelVisibleImageFileNames.isEmpty)
        }
    }

    private func withStore(_ body: (PersistenceGRDBStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-markdown-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        try body(store)
    }
}
