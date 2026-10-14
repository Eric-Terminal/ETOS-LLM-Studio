// ============================================================================
// MacDisplayImageLoaderTests.swift
// ============================================================================
// macOS 图片使用 AppKit 载体，但附件解码仍必须保持原始 EXIF 方向和显示比例。
// ============================================================================

#if os(macOS)
import AppKit
import ImageIO
import Testing
@testable import ETOSCore

@Suite("Mac 附件图像解码")
struct MacDisplayImageLoaderTests {
    @Test("原尺寸图片先在后台应用 EXIF 方向")
    func originalImageRespectsOrientation() async throws {
        let url = try makeRotatedImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(await DisplayImageLoader.shared.original(at: url))
        #expect(image.size == CGSize(width: 2, height: 4))
    }

    @Test("显示缩图遵守旋转后的目标比例")
    func thumbnailRespectsTargetSize() async throws {
        let url = try makeRotatedImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try #require(await DisplayImageLoader.shared.image(
            at: url,
            target: DisplayImageTarget(size: CGSize(width: 1, height: 2), scale: 1, fillsBounds: false)
        ))
        #expect(prepared.image.size == CGSize(width: 1, height: 2))
        #expect(prepared.sourcePixelScale == 0.5)
        #expect(!prepared.sourceRevision.isEmpty)
    }

    private func makeRotatedImage() throws -> URL {
        let context = try #require(CGContext(
            data: nil,
            width: 4,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-image-\(UUID()).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
#endif
