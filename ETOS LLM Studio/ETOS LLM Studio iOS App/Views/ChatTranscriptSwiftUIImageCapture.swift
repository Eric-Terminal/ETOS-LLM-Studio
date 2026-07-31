// ============================================================================
// ChatTranscriptSwiftUIImageCapture.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责将完整 SwiftUI 聊天画布稳定测高，并通过 UIKit 分片生成长图。
// ============================================================================

import ETOSCore
import SwiftUI
import UIKit

struct ChatTranscriptExportHeightTracker {
    private let requiredStableMeasurementCount = 3
    private let tolerance: CGFloat = 0.5
    private var previousHeight: CGFloat?
    private var stableMeasurementCount = 0

    mutating func record(_ height: CGFloat) -> Bool {
        if let previousHeight, abs(previousHeight - height) <= tolerance {
            stableMeasurementCount += 1
        } else {
            stableMeasurementCount = 1
        }
        previousHeight = height
        return stableMeasurementCount >= requiredStableMeasurementCount
    }
}

struct ChatTranscriptCapturedImage {
    let image: CGImage
    let scale: CGFloat
}

@MainActor
enum ChatTranscriptSwiftUIImageCapture {
    private static let maximumPixelHeight: CGFloat = 50_000
    private static let maximumBitmapBytes: CGFloat = 128 * 1_024 * 1_024
    private static let layoutPassIntervalNanoseconds: UInt64 = 16_000_000
    private static let maximumLayoutPassCount = 30

    static func capture<Canvas: View>(
        canvas: Canvas,
        width: CGFloat,
        viewportHeight: CGFloat,
        prefersDarkAppearance: Bool
    ) async throws -> ChatTranscriptCapturedImage {
        let hostingController = UIHostingController(rootView: canvas)
        hostingController.view.backgroundColor = .clear
        hostingController.overrideUserInterfaceStyle = prefersDarkAppearance ? .dark : .light
        let initialHeight = try measuredHeight(
            hostingController: hostingController,
            width: width
        )
        hostingController.view.frame = CGRect(x: 0, y: 0, width: width, height: initialHeight)

        let scrollView = UIScrollView(
            frame: CGRect(x: 0, y: 0, width: width, height: min(viewportHeight, initialHeight))
        )
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.isScrollEnabled = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: width, height: initialHeight)

        let rootController = UIViewController()
        rootController.view.backgroundColor = .clear
        rootController.overrideUserInterfaceStyle = prefersDarkAppearance ? .dark : .light
        rootController.addChild(hostingController)
        scrollView.addSubview(hostingController.view)
        rootController.view.addSubview(scrollView)
        hostingController.didMove(toParent: rootController)

        let window = makeOffscreenWindow(rootController: rootController)
        defer {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
        }

        window.overrideUserInterfaceStyle = prefersDarkAppearance ? .dark : .light
        window.isHidden = false
        let height = try await settleLayout(
            hostingController: hostingController,
            scrollView: scrollView,
            rootController: rootController,
            width: width
        )
        let scale = try renderScale(width: width, height: height)
        let pixelWidth = Int(ceil(width * scale))
        let pixelHeight = Int(ceil(height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        bitmapContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmapContext.scaleBy(x: scale, y: -scale)

        var originY: CGFloat = 0
        while originY < height {
            try Task.checkCancellation()
            let sliceHeight = min(viewportHeight, height - originY)
            scrollView.frame = CGRect(x: 0, y: 0, width: width, height: sliceHeight)
            scrollView.contentOffset = CGPoint(x: 0, y: originY)
            scrollView.layoutIfNeeded()
            hostingController.view.layoutIfNeeded()
            // 长内容移入可见区域后要留出一帧生成显示列表，否则分片可能截到尚未绘制的气泡。
            try await Task.sleep(nanoseconds: layoutPassIntervalNanoseconds)
            scrollView.layoutIfNeeded()
            hostingController.view.layoutIfNeeded()

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            var didCapture = false
            let sliceImage = autoreleasepool {
                UIGraphicsImageRenderer(
                    size: CGSize(width: width, height: sliceHeight),
                    format: format
                ).image { _ in
                    didCapture = scrollView.drawHierarchy(
                        in: CGRect(x: 0, y: 0, width: width, height: sliceHeight),
                        afterScreenUpdates: true
                    )
                }
            }
            guard didCapture else {
                throw ChatTranscriptExportError.imageRenderFailed
            }

            UIGraphicsPushContext(bitmapContext)
            sliceImage.draw(in: CGRect(x: 0, y: originY, width: width, height: sliceHeight))
            UIGraphicsPopContext()
            originY += sliceHeight
            await Task.yield()
        }

        guard let cgImage = bitmapContext.makeImage() else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        return ChatTranscriptCapturedImage(image: cgImage, scale: scale)
    }

    private static func settleLayout<Canvas: View>(
        hostingController: UIHostingController<Canvas>,
        scrollView: UIScrollView,
        rootController: UIViewController,
        width: CGFloat
    ) async throws -> CGFloat {
        var heightTracker = ChatTranscriptExportHeightTracker()
        var resolvedHeight = hostingController.view.frame.height

        // 测量与截图必须复用同一棵已挂载视图，等待异步 Markdown 和字体布局稳定。
        for _ in 0..<maximumLayoutPassCount {
            try Task.checkCancellation()
            rootController.view.layoutIfNeeded()
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()

            resolvedHeight = try measuredHeight(
                hostingController: hostingController,
                width: width
            )
            hostingController.view.frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: resolvedHeight
            )
            scrollView.contentSize = CGSize(width: width, height: resolvedHeight)

            if heightTracker.record(resolvedHeight) {
                return resolvedHeight
            }
            try await Task.sleep(nanoseconds: layoutPassIntervalNanoseconds)
        }

        return resolvedHeight
    }

    private static func measuredHeight<Canvas: View>(
        hostingController: UIHostingController<Canvas>,
        width: CGFloat
    ) throws -> CGFloat {
        let measured = hostingController.sizeThatFits(
            in: CGSize(width: width, height: maximumPixelHeight * 4)
        )
        let height = ceil(measured.height)
        guard height.isFinite, height > 0 else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        return height
    }

    private static func renderScale(width: CGFloat, height: CGFloat) throws -> CGFloat {
        for scale: CGFloat in [2, 1] {
            let pixelWidth = ceil(width * scale)
            let pixelHeight = ceil(height * scale)
            let estimatedBytes = pixelWidth * pixelHeight * 4
            if pixelHeight <= maximumPixelHeight && estimatedBytes <= maximumBitmapBytes {
                return scale
            }
        }
        throw ChatTranscriptExportError.imageTooLong
    }

    private static func makeOffscreenWindow(rootController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        window.rootViewController = rootController
        return window
    }
}
