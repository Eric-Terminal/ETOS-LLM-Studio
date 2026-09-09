import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ETOSCore

struct InlineHTMLExportSupportTests {
    @Test("向导能够检索内联 Widget 复制与 PNG 导出说明")
    func guideSearchFindsInlineActions() async {
        let results = await GuideKnowledgeService().search("app_show_widget PNG 复制代码", limit: 1)
        #expect(results.first?.id == "inline-html-actions")
    }

    @Test("网页尺寸在截图前拒绝非有限值和超大位图")
    func snapshotLimits() throws {
        try InlineHTMLExportSupport.validateSnapshotSize(CGSize(width: 400, height: 2_000), scale: 2)
        #expect(throws: InlineHTMLExportError.self) {
            try InlineHTMLExportSupport.validateSnapshotSize(CGSize(width: CGFloat.infinity, height: 20), scale: 2)
        }
        #expect(throws: InlineHTMLExportError.self) {
            try InlineHTMLExportSupport.validateSnapshotSize(CGSize(width: 400, height: 100_000), scale: 3)
        }
        #expect(throws: InlineHTMLExportError.self) {
            try InlineHTMLExportSupport.validateSnapshotSize(.zero, scale: 2)
        }
    }

    @MainActor
    @Test("内联来源按消息和版本隔离，移除后不再保留网页操作")
    func sourceIsolation() {
        let registry = InlineHTMLContentRegistry.shared
        let content = InlineHTMLContent()
        let messageID = UUID()
        content.messageID = messageID
        content.versionIndex = 2
        content.readText = { "当前内容" }
        registry.register(content)
        registry.register(content)
        #expect(registry.contents(messageID: messageID, versionIndex: 2).count == 1)
        #expect(registry.contents(messageID: messageID, versionIndex: 1).isEmpty)
        #expect(registry.contents(messageID: UUID(), versionIndex: 2).isEmpty)
        registry.remove(content)
        #expect(registry.contents(messageID: messageID, versionIndex: 2).isEmpty)
        #expect(content.readText == nil)
    }

    @Test("导出的 PNG 可解码且保留图像尺寸")
    func pngEncoding() throws {
        let context = try #require(CGContext(data: nil, width: 12, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = try InlineHTMLExportSupport.pngData(image: image)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 12)
        #expect(decoded.height == 24)
    }
}
