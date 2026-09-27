import ETOSCore
import SwiftUI
import UIKit

struct ChatSendFlightSurface: UIViewRepresentable {
    let controller: ChatSendFlightController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        controller.surface = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { controller.surface = uiView }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.controller?.cancel()
    }

    final class Coordinator {
        weak var controller: ChatSendFlightController?
        init(controller: ChatSendFlightController) { self.controller = controller }
    }
}

/// 重定向保留速度；即使已经开始淡出，飞行内容仍随真实消息移动到交接结束。
@MainActor
final class ChatSendFlightController {
    /// 位置与速度属于屏幕坐标；入场误差在移动目标坐标中衰减，避免跟随匀速列表时永远落后。
    private struct Axis {
        private(set) var position: CGFloat
        private(set) var velocity: CGFloat = 0
        private let response: Double
        private let damping: CGFloat
        private var target: CGFloat
        private var reportedAt: CFTimeInterval?
        private var sampledTarget: CGFloat
        private var sampledAt: CFTimeInterval?
        private var maximumSampleInterval: CFTimeInterval = 1.0 / 60
        private var previousSampleVelocity: CGFloat?
        private var targetVelocity: CGFloat = 0
        private var alignmentVelocity: CGFloat = 0
        private var alignmentSampleAge: CFTimeInterval = 0

        init(position: CGFloat, response: Double, damping: CGFloat = 1) {
            self.position = position
            self.target = position
            self.sampledTarget = position
            self.response = response
            self.damping = damping
        }

        var isAligned: Bool {
            // 比较同一采样时刻的位置，避免 60Hz 几何与 120Hz 显示的相位差变成永久误差。
            let positionAtSample = position - velocity * CGFloat(alignmentSampleAge)
            return abs(positionAtSample - target) < 0.5 && abs(velocity - alignmentVelocity) < 4
        }

        mutating func retarget(to target: CGFloat, at now: CFTimeInterval) {
            guard target != self.target else { return }
            if let sampledAt, now - sampledAt >= 1.0 / 240, now - sampledAt <= 0.12 {
                let interval = now - sampledAt
                let candidate = (target - sampledTarget) / CGFloat(interval)
                // 一次性键盘终值或跳点不能冒充列表速度；至少两个连续且接近的回执才外推。
                if let previousSampleVelocity,
                   abs(candidate - previousSampleVelocity) <= max(8, abs(previousSampleVelocity) * 0.5) {
                    targetVelocity = candidate
                } else {
                    targetVelocity = 0
                }
                previousSampleVelocity = candidate
                // 短回执不能收窄同一连续段已观察到的慢回执窗口，否则不均匀采样会反复假停。
                maximumSampleInterval = max(maximumSampleInterval, interval)
            } else if sampledAt == nil || now - (sampledAt ?? now) > 0.12 {
                previousSampleVelocity = nil
                targetVelocity = 0
                maximumSampleInterval = 1.0 / 60
            } else {
                // 同一布局批次可能给出多个中间值；保留上一份有效速度采样，不制造零速边沿。
                self.target = target
                reportedAt = now
                return
            }
            self.target = target
            sampledTarget = target
            sampledAt = now
            reportedAt = now
        }

        mutating func advance(by delta: TimeInterval, at now: CFTimeInterval) {
            let age = max(0, now - (reportedAt ?? now))
            let isFresh = age <= max(1.0 / 30, maximumSampleInterval * 2)
            let movingVelocity = isFresh ? targetVelocity : 0
            let projectedTarget = target + movingVelocity * CGFloat(isFresh ? age : 0)
            let targetAtPreviousFrame = projectedTarget - movingVelocity * CGFloat(delta)
            var relativeMotion = ChatMotionSpring(
                position: position - targetAtPreviousFrame,
                velocity: velocity - movingVelocity,
                target: 0,
                responseDuration: response,
                dampingRatio: damping
            )
            relativeMotion.advance(by: delta)
            position = projectedTarget + relativeMotion.position
            velocity = movingVelocity + relativeMotion.velocity
            alignmentVelocity = movingVelocity
            alignmentSampleAge = isFresh ? age : 0
        }
    }

    private final class Item {
        let view: UIView
        let content: UIView
        let sourceContentFrame: CGRect
        let contentVerticalPosition: CGFloat
        let gradient: CAGradientLayer?
        let isImage: Bool
        var x: Axis
        var y: Axis
        var width: Axis
        var height: Axis
        var contentReveal: ChatMotionSpring
        var hasLanding = false

        init(capture: ChatSendFlightCapture, response: Double, damping: Double, colors: [CGColor]) {
            sourceContentFrame = capture.sourceContentFrame ?? CGRect(origin: .zero, size: capture.frame.size)
            contentVerticalPosition = capture.contentVerticalPosition
            content = capture.content
            view = UIView(frame: capture.frame)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            if case .image = capture.source { isImage = true } else { isImage = false }
            view.layer.cornerRadius = isImage ? 10 : 0
            if isImage {
                gradient = nil
            } else {
                let layer = CAGradientLayer()
                layer.colors = colors
                layer.startPoint = CGPoint(x: 0, y: 0)
                layer.endPoint = CGPoint(x: 1, y: 1)
                layer.opacity = 0
                view.layer.addSublayer(layer)
                gradient = layer
            }
            content.frame = sourceContentFrame
            view.addSubview(content)
            x = Axis(position: capture.frame.midX, response: response * 0.55, damping: CGFloat(damping))
            y = Axis(position: capture.frame.midY, response: response, damping: CGFloat(damping))
            width = Axis(position: capture.frame.width, response: response * 0.6)
            height = Axis(position: capture.frame.height, response: response * 0.7)
            contentReveal = ChatMotionSpring(position: 0, target: 0, responseDuration: response * 0.7)
        }

        var isSettled: Bool {
            hasLanding && x.isAligned && y.isAligned && width.isAligned && height.isAligned && contentReveal.isSettled
        }

        func retarget(_ frame: CGRect, at now: CFTimeInterval) {
            hasLanding = true
            x.retarget(to: frame.midX, at: now)
            y.retarget(to: frame.midY, at: now)
            width.retarget(to: frame.width, at: now)
            height.retarget(to: frame.height, at: now)
            contentReveal.retarget(to: 1)
        }

        func advance(by delta: TimeInterval, at now: CFTimeInterval) {
            x.advance(by: delta, at: now)
            y.advance(by: delta, at: now)
            width.advance(by: delta, at: now)
            height.advance(by: delta, at: now)
            contentReveal.advance(by: delta)
            view.bounds.size = CGSize(width: max(1, width.position), height: max(1, height.position))
            view.center = CGPoint(x: x.position, y: y.position)
            let material = min(1, max(0, contentReveal.position))
            view.layer.cornerRadius = isImage ? 10 + 6 * material : 18 * material
            gradient?.frame = view.bounds
            gradient?.opacity = Float(material)
            let reveal = material
            let sourceSize = sourceContentFrame.size
            let targetContentFrame: CGRect
            if isImage {
                targetContentFrame = view.bounds
            } else {
                // 原字形保持等比，短句从真实字形宽度扩展，不把整条空白输入栏压成小字。
                let scale = min(1, min(view.bounds.width / sourceSize.width, view.bounds.height / sourceSize.height))
                let contentHeight = sourceSize.height * scale
                let verticalInset = min(8 * material, max(0, (view.bounds.height - contentHeight) / 2))
                let freeHeight = max(0, view.bounds.height - contentHeight - 2 * verticalInset)
                targetContentFrame = CGRect(
                    x: (view.bounds.width - sourceSize.width * scale) / 2,
                    y: verticalInset + freeHeight * contentVerticalPosition,
                    width: sourceSize.width * scale,
                    height: contentHeight
                )
            }
            let contentFrame = CGRect(
                x: sourceContentFrame.minX + (targetContentFrame.minX - sourceContentFrame.minX) * reveal,
                y: sourceContentFrame.minY + (targetContentFrame.minY - sourceContentFrame.minY) * reveal,
                width: sourceSize.width + (targetContentFrame.width - sourceSize.width) * reveal,
                height: sourceSize.height + (targetContentFrame.height - sourceSize.height) * reveal
            )
            if isImage {
                content.frame = contentFrame
            } else {
                content.transform = CGAffineTransform(
                    scaleX: contentFrame.width / sourceSize.width,
                    y: contentFrame.height / sourceSize.height
                )
                content.center = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
            }
        }
    }

    weak var surface: UIView?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var items: [ChatSendPresentationSource: Item] = [:]
    private var flightID: UUID?
    private var startedAt: CFTimeInterval = 0
    private var previousFrameAt: CFTimeInterval?
    private var handoffStartedAt: CFTimeInterval?
    private var onHandoff: (() -> Void)?
    private var onCompletion: (() -> Void)?
    private var onMessagesPrepared: ((ChatSendPresentation) -> Void)?
    private var onSourcesRetired: ((Set<ChatSendPresentationSource>) -> Void)?

    var isActive: Bool { flightID != nil }
    var capturedSources: Set<ChatSendPresentationSource> { Set(items.keys) }

    func begin(
        id: UUID,
        captures: [ChatSendFlightCapture],
        response: Double,
        damping: Double,
        colors: [CGColor],
        onMessagesPrepared: @escaping (ChatSendPresentation) -> Void,
        onSourcesRetired: @escaping (Set<ChatSendPresentationSource>) -> Void,
        onHandoff: @escaping () -> Void,
        onCompletion: @escaping () -> Void
    ) {
        cancel()
        guard let surface, !captures.isEmpty else { return }
        flightID = id
        self.onHandoff = onHandoff
        self.onCompletion = onCompletion
        self.onMessagesPrepared = onMessagesPrepared
        self.onSourcesRetired = onSourcesRetired
        startedAt = CACurrentMediaTime()
        previousFrameAt = nil
        handoffStartedAt = nil
        for capture in captures {
            let item = Item(capture: capture, response: response, damping: damping, colors: colors)
            items[capture.source] = item
            surface.addSubview(item.view)
        }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func accept(_ presentation: ChatSendPresentation, for id: UUID) {
        guard flightID == id else { return }
        // 未保存成功的来源不能永远占着输入位置；其余来源继续完成发送交接。
        retireSources(Set(items.keys.filter { presentation.messageIDsBySource[$0] == nil }))
        guard flightID == id else { return }
        let prepared = onMessagesPrepared
        onMessagesPrepared = nil
        prepared?(presentation)
        if items.isEmpty { finish() }
    }

    func retarget(_ frames: [ChatSendPresentationSource: CGRect], at now: CFTimeInterval = CACurrentMediaTime()) {
        guard let flightID, let surface else { return }
        var retiredSources: Set<ChatSendPresentationSource> = []
        for (source, proposedFrame) in frames {
            guard let item = items[source], proposedFrame.width.isFinite, proposedFrame.height.isFinite,
                  proposedFrame.minX.isFinite, proposedFrame.minY.isFinite else { continue }
            let visibleFrame = proposedFrame.intersection(surface.bounds)
            if visibleFrame.isNull || visibleFrame.width <= 1 || visibleFrame.height <= 1 {
                // 离屏的目标无需继续等待，其他可见附件仍独立完成自己的运动。
                retiredSources.insert(source)
            } else {
                // 裁切由最外层负责，不能把半露出的完整气泡压缩成视口内的残片。
                item.retarget(proposedFrame, at: now)
            }
        }
        retireSources(retiredSources)
        guard self.flightID == flightID else { return }
        if items.isEmpty { finish() }
    }

    private func retireSources(_ sources: Set<ChatSendPresentationSource>) {
        guard !sources.isEmpty else { return }
        for source in sources {
            items.removeValue(forKey: source)?.view.removeFromSuperview()
        }
        onSourcesRetired?(sources)
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        items.values.forEach { $0.view.removeFromSuperview() }
        items.removeAll()
        flightID = nil
        onHandoff = nil
        onCompletion = nil
        onMessagesPrepared = nil
        onSourcesRetired = nil
        handoffStartedAt = nil
        previousFrameAt = nil
    }

    /// 同一运动方程用于显示刷新与回归测试，测试不依赖真实帧率或动画计时器。
    func advance(at now: CFTimeInterval) {
        guard let flightID, surface?.window != nil else {
            finish()
            return
        }
        let elapsed = now - startedAt
        let delta = max(0, previousFrameAt.map { now - $0 } ?? 0)
        previousFrameAt = now
        if elapsed >= 1.6 {
            // 只有始终缺失落点的来源需要安全释放，已在运动的合法落点没有全局硬截止。
            retireSources(Set(items.compactMap { $0.value.hasLanding ? nil : $0.key }))
            guard self.flightID == flightID else { return }
            if items.isEmpty { finish(); return }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items.values {
            item.advance(by: delta, at: now)
            if let handoffStartedAt {
                item.view.alpha = max(0, 1 - (now - handoffStartedAt) / 0.12)
            }
        }
        CATransaction.commit()

        if let handoffStartedAt {
            if now - handoffStartedAt >= 0.12 { finish() }
        } else if elapsed >= 0.12 && items.values.allSatisfy(\.isSettled) {
            handoffStartedAt = now
            let handoff = onHandoff
            onHandoff = nil
            handoff?()
        }
    }

    private func finish() {
        let completion = onCompletion
        cancel()
        completion?()
    }

    private final class DisplayLinkTarget: NSObject {
        weak var owner: ChatSendFlightController?
        init(owner: ChatSendFlightController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            // 几何回执与推进都使用同一单调时钟的处理时刻，不能混用上一帧的 vsync 时间。
            owner.advance(at: CACurrentMediaTime())
        }
    }
}
