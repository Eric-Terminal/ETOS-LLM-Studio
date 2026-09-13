import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ETOSCore

@Suite("显示图片后台解码", .serialized)
struct DisplayImageLoaderTests {
    @Test("大图按气泡像素解码，预览保留原尺寸且不修改附件")
    func thumbnailPreservesOriginal() async throws {
        let url = try makeImage(width: 4_000, height: 3_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let originalData = try Data(contentsOf: url)
        let loader = DisplayImageLoader()
        let target = DisplayImageTarget(size: CGSize(width: 220, height: 180), scale: 3)
        let prepared = try #require(await loader.image(at: url, target: target))
        let thumbnail = try #require(prepared.image.cgImage)
        let original = try #require(await loader.original(at: url)?.cgImage)
        #expect(thumbnail.width == 720)
        #expect(thumbnail.height == 540)
        #expect(original.width == 4_000)
        #expect(original.height == 3_000)
        #expect(try Data(contentsOf: url) == originalData)
        #expect(prepared.sourcePixelScale == 0.18)
        let originalBytes = original.bytesPerRow * original.height
        let thumbnailBytes = thumbnail.bytesPerRow * thumbnail.height
        #expect(thumbnailBytes * 20 < originalBytes)
        print("图片位图对照 original_bytes=\(originalBytes) thumbnail_bytes=\(thumbnailBytes)")
    }

    @Test("并发相同请求复用同一位图，尺寸变化独立准备")
    func concurrentRequestsShareImage() async throws {
        let url = try makeImage(width: 1_200, height: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = DisplayImageLoader()
        let target = DisplayImageTarget(size: CGSize(width: 100, height: 100), scale: 2)
        let results = await withTaskGroup(of: PreparedDisplayImage?.self) { group in
            for _ in 0..<20 {
                group.addTask { await loader.image(at: url, target: target) }
            }
            var values: [PreparedDisplayImage] = []
            for await result in group { if let result { values.append(result) } }
            return values
        }
        #expect(results.count == 20)
        let first = try #require(results.first)
        #expect(results.allSatisfy { $0.image === first.image })
        let larger = try #require(await loader.image(
            at: url, target: DisplayImageTarget(size: CGSize(width: 300, height: 300), scale: 2)
        ))
        #expect(larger.image !== first.image)
        #expect(larger.image.size.width > first.image.size.width)
    }

    @Test("照片旋转元数据先应用到显示尺寸，填充与适应分别保留清晰度")
    func orientationAndContentMode() async throws {
        let url = try makeImage(width: 800, height: 400, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = DisplayImageLoader()
        let filled = try #require(await loader.image(
            at: url, target: DisplayImageTarget(size: CGSize(width: 100, height: 100), scale: 1)
        ))
        #expect(filled.image.size == CGSize(width: 100, height: 200))
        #expect(filled.image.imageOrientation == .up)
        let original = try #require(await loader.original(at: url))
        #expect(original.imageOrientation == .right)
        #expect(original.cgImage?.width == 800)
        let fitted = try #require(await loader.image(
            at: url, target: DisplayImageTarget(size: CGSize(width: 100, height: 100), scale: 1, fillsBounds: false)
        ))
        #expect(fitted.image.size == CGSize(width: 50, height: 100))
    }

    @Test("替换原文件后失效，缺失文件失败后仍可重新加载")
    func fileReplacementInvalidatesCache() async throws {
        let url = try makeImage(width: 80, height: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = DisplayImageLoader()
        let target = DisplayImageTarget(size: CGSize(width: 100, height: 100), scale: 1)
        let first = try #require(await loader.image(at: url, target: target))
        #expect(first.image.size == CGSize(width: 80, height: 40))
        try FileManager.default.removeItem(at: url)
        #expect(await loader.image(at: url, target: target) == nil)
        let replacement = try makeImage(width: 40, height: 80)
        try FileManager.default.moveItem(at: replacement, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: url.path)
        let second = try #require(await loader.image(at: url, target: target))
        #expect(second.image.size == CGSize(width: 40, height: 80))
    }

    @Test("超过原来的附件缓存张数仍可加载，旧附件可再次访问")
    func manyAttachmentsRemainAccessible() async throws {
        let source = try makeImage(width: 40, height: 30)
        defer { try? FileManager.default.removeItem(at: source) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = DisplayImageLoader()
        let target = DisplayImageTarget(size: CGSize(width: 20, height: 20), scale: 1)
        for index in 0..<180 {
            let url = directory.appendingPathComponent("\(index).jpg")
            try FileManager.default.copyItem(at: source, to: url)
            #expect(await loader.image(at: url, target: target) != nil)
        }
        #expect(await loader.image(at: directory.appendingPathComponent("0.jpg"), target: target) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 180)
    }

    private func makeImage(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("display-image-\(UUID().uuidString).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
