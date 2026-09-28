import CoreGraphics
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("待发送图片比例与裁切连续性", .serialized)
@MainActor
struct ChatPendingImagePreviewTests {
    @Test("真实输入图片与飞行共用原比例位图，半露出切边不增加圆角", arguments: [false, true])
    func preparedSourcePreservesAspectAndClipping(partiallyVisible: Bool) async throws {
        let attachment = ImageAttachment(
            data: try patternImageData(), mimeType: "image/png", fileName: "pattern.png",
            thumbnailData: Data("旧缩略图不可作为显示来源".utf8)
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        let root = UIViewController()
        window.rootViewController = root
        let sources = ChatSendFlightSources()
        let sourceID = ChatSendPresentationSource.image(attachment.id)
        let host = UIHostingController(rootView:
            ChatPendingImagePreview(attachment: attachment)
                .environment(\.chatSendFlightSources, sources)
                .environment(\.displayScale, 1)
                .ignoresSafeArea()
        )
        let clip = UIView(frame: CGRect(x: 20, y: 340, width: partiallyVisible ? 36 : 72, height: 72))
        clip.clipsToBounds = true
        root.view.addSubview(clip)
        root.addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: partiallyVisible ? -36 : 0, y: 0, width: 72, height: 72)
        clip.addSubview(host.view)
        host.didMove(toParent: root)
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        window.addSubview(surface)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        var captures: [ChatSendFlightCapture] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            captures = sources.capture(in: surface, ids: [sourceID])
            if !captures.isEmpty { break }
        }
        let capture = try #require(captures.first)
        let bitmapView = try #require(capture.content as? UIImageView)
        let prepared = try #require(await DisplayImageLoader.shared.pendingAttachment(
            attachment, target: DisplayImageTarget(size: CGSize(width: 220, height: 180), scale: 1)
        ))
        #expect(bitmapView.image === prepared.image)
        #expect(bitmapView.image?.size == CGSize(width: 240, height: 160))
        #expect(bitmapView.contentMode == .scaleAspectFill)
        #expect(abs(capture.frame.width - (partiallyVisible ? 36 : 72)) < 0.5)
        #expect(abs((capture.sourceContentFrame?.minX ?? 0) - (partiallyVisible ? -36 : 0)) < 0.5)
        #expect(capture.sourceContentFrame?.size == CGSize(width: 72, height: 72))

        let target = CGRect(x: 110, y: 80, width: 220, height: 180)
        let targetHost = UIHostingController(rootView:
            AttachmentImageView(
                fileName: attachment.fileName, minWidth: 220, maxWidth: 220, height: 180, cornerRadius: 16,
                onPreview: { _ in }
            )
            .environment(\.chatTranscriptPreloadedAttachmentImages, [attachment.fileName: prepared.image])
            .frame(width: 220, height: 180)
            .ignoresSafeArea()
        )
        root.addChild(targetHost)
        targetHost.view.backgroundColor = .clear
        targetHost.view.frame = target
        root.view.addSubview(targetHost.view)
        targetHost.didMove(toParent: root)
        let targetCarrier = ChatSendFlightTargetCarrier(frame: target)
        root.view.addSubview(targetCarrier)
        try await Task.sleep(for: .milliseconds(40))
        targetHost.view.layoutIfNeeded()
        let realTargetPixels = try pixels(of: targetHost.view)
        let realTargetCircle = try #require(realTargetPixels.redBounds)

        let viewport = UIView(frame: window.bounds)
        let composer = UIView(frame: CGRect(x: 0, y: 330, width: 360, height: 150))
        window.addSubview(viewport)
        window.addSubview(composer)
        let controller = ChatSendFlightController()
        controller.surface = surface
        controller.viewportAnchor = viewport
        controller.composerAnchor = composer
        controller.composerContentAnchor = composer
        defer { controller.cancel() }
        let started = CACurrentMediaTime()
        let flightID = UUID()
        controller.begin(
            id: flightID, captures: [capture], response: 0.2, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { _, _ in true }, onCompletion: {}
        )
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [sourceID: UUID()], responseGroupID: UUID()), for: flightID, at: started)
        controller.registerTarget(targetCarrier, for: ChatSendFlightTarget(flightID: flightID, source: sourceID))
        let flight = try #require(surface.subviews.first)
        let initialPixels = try pixels(of: flight)
        if partiallyVisible {
            // 这里是图片中部被视口切开的边，不是原图片的左上圆角。
            #expect(initialPixels.alpha(x: 1, y: 1) > 240)
            #expect(initialPixels.alpha(x: initialPixels.width - 2, y: 1) < 40)
        } else {
            let circle = try #require(initialPixels.redBounds)
            #expect(abs(circle.width - circle.height) <= 2)
            #expect(initialPixels.alpha(x: 1, y: 1) < 40)
        }
        controller.retarget([sourceID: target], at: started)
        controller.advance(at: started + 3)
        #expect(controller.isActive && flight.superview === targetCarrier)
        #expect(abs(flight.frame.width - target.width) < 0.5)
        #expect(abs(flight.frame.height - target.height) < 0.5)
        let landedPixels = try pixels(of: flight)
        let landedCircle = try #require(landedPixels.redBounds)
        #expect(abs(landedCircle.width - landedCircle.height) <= 2)
        #expect(landedCircle.width > 50)
        #expect(abs(landedCircle.width - realTargetCircle.width) <= 2)
        #expect(abs(landedCircle.height - realTargetCircle.height) <= 2)
        #expect(landedPixels.alpha(x: 1, y: 1) < 40)
        #expect(bitmapView.image === prepared.image)
        for y in [23, 49, 83, 121, 151] {
            for x in [31, 58, 93, 137, 181] {
                let index = (y * landedPixels.width + x) * 4
                for channel in 0..<3 {
                    #expect(abs(Int(landedPixels.bytes[index + channel]) - Int(realTargetPixels.bytes[index + channel])) <= 4)
                }
            }
        }

        let expected = UIImageView(image: prepared.image)
        expected.frame = CGRect(origin: .zero, size: target.size)
        expected.contentMode = .scaleAspectFill
        expected.clipsToBounds = true
        expected.layer.cornerRadius = 16
        expected.layer.cornerCurve = .continuous
        let expectedPixels = try pixels(of: expected)
        // 对照完整原图的中心填充，不能只断言“有图片”而漏掉不同密度的格子和裁切跳变。
        #expect(landedPixels.bytes == expectedPixels.bytes)
    }

    @Test("未准备好的图片没有可捕获来源")
    func unpreparedImageDoesNotCapture() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let source = UIImageView(frame: CGRect(x: 20, y: 20, width: 72, height: 72))
        let surface = UIView(frame: window.bounds)
        window.addSubview(source)
        window.addSubview(surface)
        let registry = ChatSendFlightSources()
        let sourceID = ChatSendPresentationSource.image(UUID())
        registry.register(source, id: sourceID)
        #expect(registry.capture(in: surface, ids: [sourceID]).isEmpty)
    }

    private func patternImageData() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 960,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        context.setFillColor(UIColor.green.cgColor)
        for row in 0..<8 {
            for column in 0..<12 where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: column * 20, y: row * 20, width: 20, height: 20))
            }
        }
        context.setFillColor(UIColor.red.cgColor)
        context.fillEllipse(in: CGRect(x: 96, y: 56, width: 48, height: 48))
        let image = UIImage(cgImage: try #require(context.makeImage()))
        return try #require(image.pngData())
    }

    private func pixels(of view: UIView) throws -> ImagePixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        let context = try #require(CGContext(
            data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let data = try #require(context.data)
        return ImagePixels(
            width: cgImage.width, height: cgImage.height,
            bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: cgImage.width * cgImage.height * 4))
        )
    }

    private struct ImagePixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        var redBounds: CGRect? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    guard bytes[index] > 200, bytes[index + 1] < 60, bytes[index + 2] < 60, bytes[index + 3] > 240 else { continue }
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
}
