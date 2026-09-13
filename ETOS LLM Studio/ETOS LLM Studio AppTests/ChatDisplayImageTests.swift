import CoreGraphics
import ETOSCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("聊天背景显示尺寸与状态切换", .serialized)
@MainActor
struct ChatDisplayImageTests {
    @Test("真实气泡从几何尺寸触发图片加载并显示缩略图")
    func mountedBubbleLoadsThumbnail() async throws {
        let name = "display-attachment-test-\(UUID().uuidString).png"
        let url = Persistence.getImageDirectory().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 3_200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let source = try #require(context.makeImage())
        try #require(UIImage(cgImage: source).pngData()).write(to: url)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        let canvas = AttachmentImageView(
            fileName: name, minWidth: 220, maxWidth: 220, height: 180, cornerRadius: 16,
            onPreview: { _ in }
        ).ignoresSafeArea()
        let host = UIHostingController(rootView: canvas)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        var displayedImage = false
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            let captured = UIGraphicsImageRenderer(bounds: host.view.bounds).image { renderer in
                host.view.layer.render(in: renderer.cgContext)
            }
            guard let image = captured.cgImage,
                  let pixel = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)),
                  let sample = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let bytes = sample.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            displayedImage = bytes[0] > 200 && bytes[1] < 60 && bytes[2] < 60
            if displayedImage { break }
        }
        #expect(displayedImage)
    }

    @Test("预览升级原图时保留缩放和阅读位置")
    func originalImagePreservesZoomPosition() throws {
        func image(width: Int, height: Int) throws -> UIImage {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return UIImage(cgImage: try #require(context.makeImage()))
        }
        let container = ZoomableUIImageScrollContainerView(image: try image(width: 40, height: 27))
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        container.layoutIfNeeded()
        let scrollView = try #require(container.subviews.compactMap { $0 as? UIScrollView }.first)
        scrollView.setZoomScale(3, animated: false)
        scrollView.contentOffset = CGPoint(x: 70, y: 80)
        container.image = try image(width: 4_000, height: 2_667)
        container.layoutIfNeeded()
        #expect(scrollView.zoomScale == 3)
        #expect(abs(scrollView.contentOffset.x - 70) < 1)
        #expect(abs(scrollView.contentOffset.y - 80) < 1)
    }

    @Test("实际背景按显示尺寸准备，旋转重算且关闭后旧任务不能覆盖")
    func backgroundUsesDisplayPixels() async throws {
        let config = AppConfigStore.shared
        let saved = (config.enableBackground, config.currentBackgroundImage, config.backgroundBlur, config.backgroundContentMode)
        let name = "display-background-test-\(UUID().uuidString).png"
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 1_200, height: 800, bitsPerComponent: 8, bytesPerRow: 4_800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let source = try #require(context.makeImage())
        try #require(UIImage(cgImage: source).pngData()).write(to: url)
        let model = ChatViewModel(chatService: ChatService())
        defer {
            model.enableBackground = false
            config.enableBackground = saved.0
            config.currentBackgroundImage = saved.1
            config.backgroundBlur = saved.2
            config.backgroundContentMode = saved.3
            try? FileManager.default.removeItem(at: url)
        }
        model.enableBackground = true
        model.currentBackgroundImage = name
        model.backgroundContentMode = "fill"
        model.backgroundBlur = 0
        model.updateBackgroundDisplayTarget(size: CGSize(width: 100, height: 100), scale: 2)
        await model.waitForBackgroundImage()
        #expect(model.currentBackgroundImageBlurredUIImage?.size == CGSize(width: 300, height: 200))
        let displayTarget = model.backgroundDisplayTarget
        let displayImage = model.currentBackgroundImageBlurredUIImage
        let exportImage = await model.backgroundImageForExport(size: CGSize(width: 300, height: 200), scale: 2)
        #expect(exportImage?.size == CGSize(width: 600, height: 400))
        #expect(model.backgroundDisplayTarget == displayTarget)
        #expect(model.currentBackgroundImageBlurredUIImage === displayImage)

        model.backgroundContentMode = "fit"
        model.updateBackgroundDisplayTarget(size: CGSize(width: 100, height: 100), scale: 2)
        await model.waitForBackgroundImage()
        let fitted = try #require(model.currentBackgroundImageBlurredUIImage)
        #expect(fitted.size.width == 200)
        #expect(fitted.size.height <= 134)

        model.backgroundBlur = 12
        await model.waitForBackgroundImage()
        #expect(model.currentBackgroundImageBlurredUIImage?.size == fitted.size)
        model.blurredBackgroundImageCache.removeAllObjects()
        model.refreshBlurredBackgroundImage()
        await model.waitForBackgroundImage()
        #expect(model.currentBackgroundImageBlurredUIImage?.size == fitted.size)
        model.updateBackgroundDisplayTarget(size: CGSize(width: 200, height: 100), scale: 2)
        model.enableBackground = false
        await model.waitForBackgroundImage()
        #expect(model.currentBackgroundImageBlurredUIImage == nil)
    }
}
