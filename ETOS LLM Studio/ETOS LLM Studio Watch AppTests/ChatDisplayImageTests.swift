import CoreGraphics
import ETOSCore
import Foundation
import Testing
import UIKit
@testable import ETOS_LLM_Studio_Watch_App

@Suite("手表背景显示尺寸与状态切换", .serialized)
@MainActor
struct ChatDisplayImageTests {
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
