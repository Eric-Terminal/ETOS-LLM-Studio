import Combine
import CoreGraphics
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送交接的双层实际呈现", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatSendFlightHandoffPresentationTests {
    @Test("真实层显现与原生淡出期间移动并变尺寸，两层保持同帧几何", arguments: HandoffMovementMoment.allCases)
    func movingLayersSharePresentedGeometry(moment: HandoffMovementMoment) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = ChatSendFlightController()
        let state = HandoffPresentationState(controller: controller, moment: moment)
        let host = UIHostingController(rootView: HandoffPresentationHost(state: state))
        host.safeAreaRegions = []
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded()
        let surface = UIView(frame: container.view.bounds)
        surface.isUserInteractionEnabled = false
        surface.backgroundColor = .clear
        container.view.addSubview(surface)
        let viewport = UIView(frame: container.view.bounds)
        let composer = UIView(frame: CGRect(x: 0, y: 720, width: 402, height: 154))
        container.view.addSubview(viewport)
        container.view.addSubview(composer)
        controller.surface = surface
        controller.viewportAnchor = viewport
        controller.composerAnchor = composer
        controller.composerContentAnchor = composer
        defer {
            controller.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let crop = CGRect(x: 40, y: 200, width: 330, height: 230)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let readyDeadline = ContinuousClock.now + .seconds(2)
        while (state.marker?.window !== window || state.reportedFrame?.isEmpty != false
               || state.marker?.layer.presentation() == nil || container.view.layer.presentation() == nil),
              ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        let marker = try #require(state.marker)
        let initialLayer = try #require(marker.layer.presentation())
        let initialRoot = try #require(container.view.layer.presentation())
        let initialPresentation = initialLayer.convert(initialLayer.bounds, to: initialRoot)
        let initialPixels = try colorBounds(in: render(initialRoot, crop: crop, format: format))
        let initialRed = try #require(initialPixels.red).offsetBy(dx: crop.minX, dy: crop.minY)
        let initialReport = try #require(state.reportedFrame)
        print("交接像素静态基准 moment=\(moment.rawValue) declared=\(state.frame) presentation=\(initialPresentation) report=\(initialReport) pixels=\(initialRed)")
        try #require(rectError(initialPresentation, state.frame) <= 0.5)
        try #require(rectError(initialPresentation, initialReport) <= 0.5)
        try #require(rectError(initialPresentation, initialRed) <= 0.5)

        // 基准封口后先隐藏真实层；后续显现完全使用生产的 opacity 动画与 removed 回执。
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) { state.opacity = 0 }
        let hiddenDeadline = ContinuousClock.now + .seconds(2)
        var realLayerHidden = false
        while ContinuousClock.now < hiddenDeadline {
            try await Task.sleep(for: .milliseconds(8))
            guard let rootLayer = container.view.layer.presentation() else { continue }
            if try colorBounds(in: render(rootLayer, crop: crop, format: format)).red == nil {
                realLayerHidden = true
                break
            }
        }
        try #require(realLayerHidden)

        // 图片来源没有文本 padding；半透明蓝色覆盖完整浮层，混色时仍可分别读出红/蓝两层边界。
        let sourceFormat = UIGraphicsImageRendererFormat()
        sourceFormat.scale = 2
        sourceFormat.opaque = false
        let sourceImage = UIGraphicsImageRenderer(size: state.frame.size, format: sourceFormat).image { context in
            UIColor.blue.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(origin: .zero, size: state.frame.size))
        }
        let sourceContent = UIImageView(image: sourceImage)
        controller.begin(
            id: state.flightID, sessionID: state.sessionID,
            captures: [.init(source: state.source, content: sourceContent, frame: state.frame)],
            response: 0.3, damping: 1, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { [weak state] _ in state?.retired = true },
            onHandoff: { [weak state] id, sessionID in
                guard let state else { return false }
                state.handoffCount += 1
                withAnimation(.easeOut(duration: 0.12), completionCriteria: .removed) {
                    state.opacity = 1
                } completion: { [weak state] in
                    guard let state else { return }
                    state.acknowledged = true
                    state.controller.completeHandoff(for: id, sessionID: sessionID)
                }
                if state.moment == .appearanceStart { state.moveTarget() }
                return true
            },
            onCompletion: { [weak state] in state?.completionCount += 1 }
        )
        let floating = try #require(surface.subviews.first)
        state.target = ChatSendFlightTarget(flightID: state.flightID, source: state.source)
        controller.accept(.init(
            sessionID: state.sessionID, messageIDsBySource: [state.source: state.messageID], responseGroupID: UUID()
        ), for: state.flightID)

        var samples = 0
        var movingSamples = 0
        var preAcknowledgementSamples = 0
        var fadingSamples = 0
        var maximumGeometryError: CGFloat = 0
        var maximumPixelError: CGFloat = 0
        var maximumPixelOracleError: CGFloat = 0
        var pixelSamples: [(image: UIImage, real: CGRect, floating: CGRect)] = []
        var lastRealFrame: CGRect?
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(8))
            guard let rootLayer = container.view.layer.presentation(), let realLayer = marker.layer.presentation() else { continue }
            let realFrame = realLayer.convert(realLayer.bounds, to: rootLayer)
            lastRealFrame = realFrame
            if let floatingLayer = floating.layer.presentation(), floating.window === window {
                let floatingFrame = floatingLayer.convert(floatingLayer.bounds, to: rootLayer)
                // 蓝图本身为半透明；8% 层透明度仍给完整覆盖像素至少 10/255 的可测颜色。
                if effectiveOpacity(of: realLayer) > 0.08, effectiveOpacity(of: floatingLayer) > 0.08 {
                    samples += 1
                    if !state.acknowledged { preAcknowledgementSamples += 1 }
                    if floatingLayer.opacity < 0.99 { fadingSamples += 1 }
                    if rectError(realFrame, initialPresentation) > 1, rectError(realFrame, state.finalFrame) > 1 {
                        movingSamples += 1
                    }
                    maximumGeometryError = max(maximumGeometryError, rectError(realFrame, floatingFrame))
                    // 动画中只保留同一呈现树的截图；像素扫描在动画结束后执行，不挤占 0.12 秒淡出窗口。
                    pixelSamples.append((render(rootLayer, crop: crop, format: format), realFrame, floatingFrame))
                    if !state.movementStarted {
                        if moment == .beforeAcknowledgement, !state.acknowledged {
                            state.moveTarget()
                        } else if moment == .nativeFade, state.acknowledged, floatingLayer.opacity < 0.99 {
                            state.moveTarget()
                        }
                    }
                }
            }
            if state.completionCount == 1, state.movementCompleted, rectError(realFrame, state.finalFrame) <= 0.5 { break }
        }
        for sample in pixelSamples {
            let pixels = try colorBounds(in: sample.image)
            let redFrame = try #require(pixels.red, "实际可见的真实层必须有红色像素").offsetBy(dx: crop.minX, dy: crop.minY)
            let blueFrame = try #require(pixels.blue, "实际可见的覆盖层必须有蓝色像素").offsetBy(dx: crop.minX, dy: crop.minY)
            maximumPixelError = max(maximumPixelError, rectError(redFrame, blueFrame))
            maximumPixelOracleError = max(maximumPixelOracleError, rectError(sample.real, redFrame), rectError(sample.floating, blueFrame))
        }
        print("交接双层核对 moment=\(moment.rawValue) samples=\(samples) moving=\(movingSamples) beforeAck=\(preAcknowledgementSamples) fading=\(fadingSamples) geometry=\(maximumGeometryError) pixels=\(maximumPixelError) pixelOracle=\(maximumPixelOracleError)")
        try #require(state.handoffCount == 1 && state.completionCount == 1 && !state.retired)
        try #require(state.movementStarted && state.movementCompleted)
        try #require(samples >= 3 && movingSamples >= 2 && preAcknowledgementSamples >= 1 && fadingSamples >= 1)
        #expect(rectError(try #require(lastRealFrame), state.finalFrame) <= 0.5)
        #expect(maximumGeometryError <= 0.5)
        #expect(maximumPixelError <= 0.5)
        #expect(maximumPixelOracleError <= 0.5)
        #expect(!controller.isActive && floating.superview == nil)
    }

    private func rectError(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY), abs(lhs.maxX - rhs.maxX), abs(lhs.maxY - rhs.maxY))
    }

    private func render(_ layer: CALayer, crop: CGRect, format: UIGraphicsImageRendererFormat) -> UIImage {
        UIGraphicsImageRenderer(bounds: crop, format: format).image { context in layer.render(in: context.cgContext) }
    }

    private func effectiveOpacity(of layer: CALayer) -> Float {
        var opacity: Float = 1
        var current: CALayer? = layer
        while let part = current {
            opacity *= part.opacity
            current = part.superlayer
        }
        return opacity
    }

    private func colorBounds(in image: UIImage) throws -> (red: CGRect?, blue: CGRect?) {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var redMinX = width, redMinY = height, redMaxX = -1, redMaxY = -1
        var blueMinX = width, blueMinY = height, blueMaxX = -1, blueMaxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // 重叠区域同时保留红/蓝贡献，不能只认纯色并把另一层排除。
                if bytes[offset] > 8 {
                    redMinX = min(redMinX, x)
                    redMinY = min(redMinY, y)
                    redMaxX = max(redMaxX, x)
                    redMaxY = max(redMaxY, y)
                }
                if bytes[offset + 2] > 8 {
                    blueMinX = min(blueMinX, x)
                    blueMinY = min(blueMinY, y)
                    blueMaxX = max(blueMaxX, x)
                    blueMaxY = max(blueMaxY, y)
                }
            }
        }
        let bounds = [(minX: redMinX, minY: redMinY, maxX: redMaxX, maxY: redMaxY),
                      (minX: blueMinX, minY: blueMinY, maxX: blueMaxX, maxY: blueMaxY)].map { value -> CGRect? in
            guard value.maxX >= value.minX, value.maxY >= value.minY else { return nil }
            return CGRect(
                x: CGFloat(value.minX) / image.scale, y: CGFloat(value.minY) / image.scale,
                width: CGFloat(value.maxX - value.minX + 1) / image.scale,
                height: CGFloat(value.maxY - value.minY + 1) / image.scale
            )
        }
        return (bounds[0], bounds[1])
    }
}

enum HandoffMovementMoment: String, CaseIterable {
    case appearanceStart, beforeAcknowledgement, nativeFade
}

@MainActor
private final class HandoffPresentationState: ObservableObject {
    let controller: ChatSendFlightController
    let moment: HandoffMovementMoment
    let flightID = UUID()
    let sessionID = UUID()
    let messageID = UUID()
    let source = ChatSendPresentationSource.image(UUID())
    let finalFrame = CGRect(x: 170, y: 310, width: 180, height: 100)
    @Published var frame = CGRect(x: 60, y: 220, width: 120, height: 60)
    @Published var opacity: Double = 1
    @Published var target: ChatSendFlightTarget?
    weak var marker: UIView?
    var reportedFrame: CGRect?
    var handoffCount = 0
    var acknowledged = false
    var completionCount = 0
    var retired = false
    var movementStarted = false
    var movementCompleted = false

    init(controller: ChatSendFlightController, moment: HandoffMovementMoment) {
        self.controller = controller
        self.moment = moment
    }

    func moveTarget() {
        movementStarted = true
        withAnimation(.linear(duration: 0.28), completionCriteria: .removed) {
            frame = finalFrame
        } completion: { [weak self] in
            self?.movementCompleted = true
        }
    }
}

@MainActor
private struct HandoffPresentationHost: View {
    @ObservedObject var state: HandoffPresentationState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            HandoffPresentationMarker(state: state)
                .frame(width: state.frame.width, height: state.frame.height)
                .opacity(state.opacity)
                .overlay {
                    GeometryReader { proxy in
                        Group {
                            if let target = state.target { ChatSendFlightTargetAnchor(target: target) }
                            else { Color.clear }
                        }
                        .preference(key: FlightTargetRectKey.self, value: [state.messageID: proxy.frame(in: .named(ChatView.flightCoordinateSpace))])
                    }
                }
                .geometryGroup()
                .position(x: state.frame.midX, y: state.frame.midY)
        }
        .ignoresSafeArea()
        .coordinateSpace(.named(ChatView.flightCoordinateSpace))
        .environment(\.chatSendFlightController, state.controller)
        .onPreferenceChange(FlightTargetRectKey.self) { frames in
            state.reportedFrame = frames[state.messageID]
            if let frame = state.reportedFrame { state.controller.retarget([state.source: frame]) }
        }
    }
}

@MainActor
private struct HandoffPresentationMarker: UIViewRepresentable {
    let state: HandoffPresentationState

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .red
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        state.marker = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
