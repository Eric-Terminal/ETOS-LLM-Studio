import CoreGraphics
import Foundation
import Testing
@testable import ETOSCore

struct DisplayImageLoaderRevisionTests {
    @Test("快照替换保留文件大小和修改时间时，显示缓存仍识别新的文件身份")
    func replacementWithPreservedMetadataInvalidatesImage() async throws {
        // 两个有效的单像素 PNG 分别为白色与黑色，编码长度相同。
        let white = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        let black = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        #expect(white.count == black.count && white != black)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("background.png")
        let modifiedAt = Date(timeIntervalSince1970: 123)
        try white.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        let loader = DisplayImageLoader()
        let target = DisplayImageTarget(size: CGSize(width: 1, height: 1), scale: 1)
        let original = try #require(await loader.image(at: url, target: target))
        try black.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        let restored = try #require(await loader.image(at: url, target: target))
        #expect(restored.sourceRevision != original.sourceRevision)
        #expect(restored.image !== original.image)
        let repeated = try #require(await loader.image(at: url, target: target))
        #expect(repeated.sourceRevision == restored.sourceRevision)
        #expect(repeated.image === restored.image)
    }
}
