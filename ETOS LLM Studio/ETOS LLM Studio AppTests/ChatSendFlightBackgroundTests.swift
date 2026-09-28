import CoreGraphics
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送气泡背景一致性", .serialized)
@MainActor
struct ChatSendFlightBackgroundTests {
    @Test("自定义透明度与壁纸透明度相乘，文件保留原纯色且图片不染色", arguments: [false, true])
    func sourceBackgroundPreservesAlphaAndMaterial(enableBackground: Bool) throws {
        let colors = ChatOutgoingBubbleColors(profile: .init(
            name: "测试", userBubble: .init(isEnabled: true, hex: "33669980")
        ))
        for source in [ChatSendPresentationSource.text, .audio(UUID()), .file(UUID())] {
            let background = try #require(ChatSendFlightBackground.resolved(
                for: source, colors: colors, enableBackground: enableBackground, enableLiquidGlass: true
            ))
            let isFile: Bool
            if case .file = source { isFile = true } else { isFile = false }
            #expect(background.enableLiquidGlass == !isFile)
            #expect(background.cornerRadius == (isFile ? 12 : 18))
            // 透明像素检验不经过玻璃合成，单独证明颜色解析没有替换用户 alpha。
            let renderer = ImageRenderer(content: ChatBubbleBackground(
                shape: Rectangle(), fill: background.fill, enableLiquidGlass: false
            ).frame(width: 80, height: 60))
            renderer.scale = 1
            renderer.isOpaque = false
            let pixel = try rgba(in: #require(renderer.uiImage), at: CGPoint(x: 40, y: 30))
            let expectedAlpha = 128.0 * (enableBackground && !isFile ? 0.85 : 1)
            #expect(abs(Double(pixel[3]) - expectedAlpha) <= 2)
        }
        #expect(ChatSendFlightBackground.resolved(
            for: .image(UUID()), colors: colors, enableBackground: enableBackground, enableLiquidGlass: true
        ) == nil)
    }

    @Test("真实背景宿主保留环境与无边距几何，展开不替换宿主")
    func hostingConfigurationKeepsEnvironmentAndGeometry() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        window.overrideUserInterfaceStyle = .light
        let root = UIViewController()
        window.rootViewController = root
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        let host = ChatSendFlightBackgroundHost(
            background: .init(fill: AnyShapeStyle(Color.primary), enableLiquidGlass: false, isFile: true),
            environment: environment
        )
        let originalView = host.view
        root.view.addSubview(host.view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let frame = CGRect(x: 20, y: 60, width: 84, height: 48)
        host.update(frame: frame, progress: 0.5)
        #expect(host.view.alpha == 0.5)
        host.update(frame: frame, progress: 1)
        #expect(host.view === originalView && host.view.frame == frame)
        #expect(!host.view.isUserInteractionEnabled)
        var renderedImage: UIImage?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { context in
                host.view.layer.render(in: context.cgContext)
            }
            renderedImage = image
            if try rgba(in: image, at: CGPoint(x: 42, y: 24))[3] > 240 { break }
        }
        let image = try #require(renderedImage)
        let center = try rgba(in: image, at: CGPoint(x: 42, y: 24))
        // UIWindow 是浅色，只有宿主接到 SwiftUI 深色环境时 primary 才是白色。
        #expect(center[0] > 240 && center[1] > 240 && center[2] > 240 && center[3] > 240)
        let edge = try rgba(in: image, at: CGPoint(x: 1, y: 24))
        #expect(edge[3] > 240)
    }

    @Test("发送取消会移除并释放纯背景宿主")
    func cancellingFlightReleasesBackgroundHost() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        let composer = UIView(frame: CGRect(x: 0, y: 720, width: 390, height: 180))
        window.addSubview(surface)
        window.addSubview(composer)
        let controller = ChatSendFlightController()
        controller.surface = surface
        controller.viewportAnchor = surface
        controller.composerAnchor = composer
        controller.composerContentAnchor = composer
        defer { controller.cancel() }
        let colors = ChatOutgoingBubbleColors(profile: .init(name: "测试"))
        let background = try #require(ChatSendFlightBackground.resolved(
            for: .text, colors: colors, enableBackground: true, enableLiquidGlass: false
        ))
        controller.begin(
            id: UUID(), captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [.text: background],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { _, _ in true }, onCompletion: {}
        )
        weak let backgroundView = surface.subviews.first?.subviews.first
        #expect(backgroundView is any UIContentView)
        controller.cancel()
        #expect(surface.subviews.isEmpty)
        for _ in 0..<30 where backgroundView != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(backgroundView == nil)
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let x = min(width - 1, Int(point.x * image.scale))
        let y = min(height - 1, Int(point.y * image.scale))
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
