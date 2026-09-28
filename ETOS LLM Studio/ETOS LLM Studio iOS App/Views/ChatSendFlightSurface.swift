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
        controller.backgroundEnvironment = context.environment
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.backgroundEnvironment = context.environment
        controller.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.controller?.detach(from: uiView)
    }

    final class Coordinator {
        weak var controller: ChatSendFlightController?
        init(controller: ChatSendFlightController) { self.controller = controller }
    }
}

/// 飞行保留速度；真实层开始显现后，两层共用实际目标几何，不再各自追赶。
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

    private enum Readiness {
        case waitingIdentity(deadline: CFTimeInterval)
        case waitingDisplay(deadline: CFTimeInterval)
        case waitingLayout(deadline: CFTimeInterval)
        case landed

        var deadline: CFTimeInterval? {
            switch self {
            case .waitingIdentity(let deadline), .waitingDisplay(let deadline), .waitingLayout(let deadline): deadline
            case .landed: nil
            }
        }
    }

    private static let readinessTimeout: CFTimeInterval = 1.6

    private final class Item {
        let view: UIView
        let content: UIView
        let sourceContentFrame: CGRect
        let contentVerticalPosition: CGFloat
        let backgroundHost: ChatSendFlightBackgroundHost?
        let targetCornerRadius: CGFloat
        let isImage: Bool
        weak var targetAnchor: ChatSendFlightTargetCarrier?
        var x: Axis
        var y: Axis
        var width: Axis
        var height: Axis
        var contentReveal: ChatMotionSpring
        var readiness: Readiness
        var hasLanding: Bool {
            if case .landed = readiness { return true }
            return false
        }

        init(
            capture: ChatSendFlightCapture,
            response: Double,
            damping: Double,
            background: ChatSendFlightBackground?,
            environment: EnvironmentValues,
            identityDeadline: CFTimeInterval
        ) {
            readiness = .waitingIdentity(deadline: identityDeadline)
            sourceContentFrame = capture.sourceContentFrame ?? CGRect(origin: .zero, size: capture.frame.size)
            contentVerticalPosition = capture.contentVerticalPosition
            content = capture.content
            view = UIView(frame: capture.frame)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            if case .image = capture.source { isImage = true } else { isImage = false }
            targetCornerRadius = background?.cornerRadius ?? 18
            // 来源被横向滚动裁掉时，视口切边应保持直线；圆角属于完整图片而不是可见交集。
            if isImage {
                content.layer.cornerRadius = 10
                content.layer.cornerCurve = .continuous
                content.clipsToBounds = true
            }
            if !isImage, let background {
                let host = ChatSendFlightBackgroundHost(background: background, environment: environment)
                view.addSubview(host.view)
                backgroundHost = host
            } else {
                backgroundHost = nil
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

        func depart(by translationY: CGFloat, at now: CFTimeInterval) {
            // 等待消息身份时先离开输入区；它不是落点，不能提前交接或显示气泡材质。
            y.retarget(to: view.center.y + translationY, at: now)
        }

        func retarget(_ frame: CGRect, at now: CFTimeInterval) {
            readiness = .landed
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
            updateView(
                frame: CGRect(
                    x: x.position - max(1, width.position) / 2,
                    y: y.position - max(1, height.position) / 2,
                    width: max(1, width.position), height: max(1, height.position)
                ),
                material: min(1, max(0, contentReveal.position))
            )
        }

        func presentationFrame(in surface: UIView) -> CGRect? {
            guard let targetAnchor, let window = surface.window, targetAnchor.window === window else { return nil }
            let frame: CGRect
            if let targetLayer = targetAnchor.layer.presentation(), let surfaceLayer = surface.layer.presentation() {
                frame = targetLayer.convert(targetLayer.bounds, to: surfaceLayer)
            } else if targetAnchor.layer.presentation() == nil, surface.layer.presentation() == nil {
                // 尚无呈现树时只使用同一原生视图树，不能混合模型层与呈现层坐标。
                frame = targetAnchor.convert(targetAnchor.bounds, to: surface)
            } else {
                return nil
            }
            guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width > 1, frame.height > 1 else { return nil }
            return frame
        }

        func isAligned(with frame: CGRect) -> Bool {
            abs(view.frame.minX - frame.minX) < 0.5 && abs(view.frame.minY - frame.minY) < 0.5
                && abs(view.frame.maxX - frame.maxX) < 0.5 && abs(view.frame.maxY - frame.maxY) < 0.5
        }

        func moveIntoTargetCarrier() -> Bool {
            guard let targetAnchor else { return false }
            targetAnchor.install(view) { [weak self] bounds in self?.updateView(frame: bounds, material: 1) }
            return true
        }

        private func updateView(frame: CGRect, material: CGFloat) {
            view.bounds.size = frame.size
            view.center = CGPoint(x: frame.midX, y: frame.midY)
            if isImage {
                content.layer.cornerRadius = 10 + 6 * material
            } else {
                view.layer.cornerRadius = targetCornerRadius * material
            }
            backgroundHost?.update(frame: view.bounds, progress: material)
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
    var backgroundEnvironment = EnvironmentValues()
    weak var composerAnchor: UIView?
    weak var composerContentAnchor: UIView?
    weak var viewportAnchor: UIView?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var items: [ChatSendPresentationSource: Item] = [:]
    private var flightID: UUID?
    private var sessionID: UUID?
    private var startedAt: CFTimeInterval = 0
    private var previousFrameAt: CFTimeInterval?
    private enum Handoff {
        case flying
        case awaitingPresentation
        case presented
        case fading(startedAt: CFTimeInterval)
    }
    private var handoff = Handoff.flying
    private var onHandoff: ((UUID, UUID?) -> Bool)?
    private var onCompletion: (() -> Void)?
    private var onMessagesPrepared: ((ChatSendPresentation) -> Bool)?
    private var onSourcesRetired: ((Set<ChatSendPresentationSource>) -> Void)?

    var isActive: Bool { flightID != nil }
    var capturedSources: Set<ChatSendPresentationSource> { Set(items.keys) }

    func registerTarget(_ view: ChatSendFlightTargetCarrier, for target: ChatSendFlightTarget) {
        guard flightID == target.flightID else { return }
        items[target.source]?.targetAnchor = view
    }

    func unregisterTarget(_ view: ChatSendFlightTargetCarrier, for target: ChatSendFlightTarget) {
        guard flightID == target.flightID, items[target.source]?.targetAnchor === view else { return }
        items[target.source]?.targetAnchor = nil
        // 拆除可发生在 SwiftUI 更新中；下一显示帧负责退役，不能在这里发布页面状态。
    }


    func attach(to view: UIView) {
        guard surface !== view else { return }
        if isActive { finishAfterSurfaceUpdate() }
        surface = view
    }

    func detach(from view: UIView) {
        guard surface === view else { return }
        surface = nil
        finishAfterSurfaceUpdate()
    }

    private func finishAfterSurfaceUpdate() {
        let completion = onCompletion
        cancel()
        // Representable 更新或拆除中不能同步发布 SwiftUI 状态；旧回执仍由发送身份过滤。
        if let completion { Task { @MainActor in completion() } }
    }

    func begin(
        id: UUID,
        sessionID: UUID? = nil,
        captures: [ChatSendFlightCapture],
        response: Double,
        damping: Double,
        backgrounds: [ChatSendPresentationSource: ChatSendFlightBackground],
        departureBounds capturedDepartureBounds: CGRect? = nil,
        at requestedStart: CFTimeInterval? = nil,
        onMessagesPrepared: @escaping (ChatSendPresentation) -> Bool,
        onSourcesRetired: @escaping (Set<ChatSendPresentationSource>) -> Void,
        onHandoff: @escaping (UUID, UUID?) -> Bool,
        onCompletion: @escaping () -> Void
    ) {
        cancel()
        guard let surface,
              let departureBounds = capturedDepartureBounds ?? self.departureBounds,
              !captures.isEmpty else { return }
        flightID = id
        self.sessionID = sessionID
        self.onHandoff = onHandoff
        self.onCompletion = onCompletion
        self.onMessagesPrepared = onMessagesPrepared
        self.onSourcesRetired = onSourcesRetired
        let preparationStart = requestedStart ?? CACurrentMediaTime()
        handoff = .flying
        let sourceBottom = captures.map(\.frame.maxY).max() ?? departureBounds.maxY
        let translationY = min(0, departureBounds.maxY - sourceBottom)
        for capture in captures {
            let item = Item(
                capture: capture, response: response, damping: damping,
                background: backgrounds[capture.source], environment: backgroundEnvironment,
                identityDeadline: preparationStart + Self.readinessTimeout
            )
            items[capture.source] = item
            surface.addSubview(item.view)
        }
        // 背景宿主的首次创建发生在运动启动前，不能消耗尚未获得显示帧的等待预算。
        // 测试显式时钟保持确定性；正式入口从全部来源装配完成后开始运动。
        let now = requestedStart ?? CACurrentMediaTime()
        startedAt = now
        previousFrameAt = now
        for item in items.values {
            item.readiness = .waitingIdentity(deadline: now + Self.readinessTimeout)
            item.depart(by: translationY, at: now)
        }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func accept(_ presentation: ChatSendPresentation, for id: UUID, at now: CFTimeInterval = CACurrentMediaTime()) {
        guard flightID == id, sessionID == nil || sessionID == presentation.sessionID else { return }
        expireUnreadySources(at: now)
        guard flightID == id, sessionID == nil || sessionID == presentation.sessionID,
              let prepared = onMessagesPrepared else { return }
        // 先取走一次性身份回执，重复或重入的 accept 不能再次筛除已绑定来源。
        onMessagesPrepared = nil
        sessionID = presentation.sessionID
        // 未保存成功的来源不能永远占着输入位置；其余来源继续完成发送交接。
        retireSources(Set(items.keys.filter { presentation.messageIDsBySource[$0] == nil }))
        guard flightID == id, sessionID == presentation.sessionID else { return }
        for item in items.values {
            if case .waitingIdentity = item.readiness {
                item.readiness = .waitingDisplay(deadline: now + Self.readinessTimeout)
            }
        }
        // UI 回执可以同步确认展示或落点；返回后不能把已前进的阶段写回去。
        let accepted = prepared(presentation)
        guard flightID == id, sessionID == presentation.sessionID else { return }
        if !accepted || items.isEmpty { finish() }
    }

    /// 输入必须是当前完整展示集合；曾展示的来源退出分页窗口后不能悬留在旧落点。
    func updateDisplayedSources(
        _ sources: Set<ChatSendPresentationSource>,
        for id: UUID,
        sessionID: UUID?,
        at now: CFTimeInterval = CACurrentMediaTime()
    ) {
        guard flightID == id, self.sessionID == sessionID else { return }
        expireUnreadySources(at: now)
        guard flightID == id, self.sessionID == sessionID else { return }
        let removedSources = Set(items.compactMap { source, item in
            switch item.readiness {
            case .waitingLayout, .landed: sources.contains(source) ? nil : source
            case .waitingIdentity, .waitingDisplay: nil
            }
        })
        retireSources(removedSources)
        guard flightID == id, self.sessionID == sessionID else { return }
        if items.isEmpty { finish(); return }
        for source in sources {
            guard let item = items[source], case .waitingDisplay = item.readiness else { continue }
            item.readiness = .waitingLayout(deadline: now + Self.readinessTimeout)
        }
    }

    func retarget(_ frames: [ChatSendPresentationSource: CGRect], at now: CFTimeInterval = CACurrentMediaTime()) {
        guard let flightID, let surface else { return }
        expireUnreadySources(at: now)
        guard self.flightID == flightID else { return }
        var retiredSources: Set<ChatSendPresentationSource> = []
        for (source, proposedFrame) in frames {
            guard let item = items[source] else { continue }
            // 真实落点可以早于展示事件，但不能绕过准确消息身份与 UI 的绑定过程。
            if case .waitingIdentity = item.readiness { continue }
            let frame: CGRect
            if item.targetAnchor != nil {
                // 锚点接管后不能交替采样布局终值与呈现中间值，否则会污染同一弹簧的速度估计。
                guard let presented = item.presentationFrame(in: surface) else { continue }
                frame = presented
            } else {
                frame = proposedFrame
            }
            guard frame.width.isFinite, frame.height.isFinite,
                  frame.minX.isFinite, frame.minY.isFinite else { continue }
            let visibleFrame = frame.intersection(surface.bounds)
            if visibleFrame.isNull || visibleFrame.width <= 1 || visibleFrame.height <= 1 {
                // 新行可能先在屏外实现，再随贴底进入视口；屏外回执不延长当前阶段截止。
                // 已接受可见落点的来源再次离屏时，才立即退出并放行真实消息。
                if item.hasLanding { retiredSources.insert(source) }
            } else {
                // 裁切由最外层负责，不能把半露出的完整气泡压缩成视口内的残片。
                if case .flying = handoff { item.retarget(frame, at: now) }
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

    private func expireUnreadySources(at now: CFTimeInterval) {
        guard let flightID else { return }
        let expiredSources = Set(items.compactMap { source, item in
            item.readiness.deadline.map { now >= $0 } == true ? source : nil
        })
        // 回执也检查截止，不能依赖可能被主线程工作延迟的第一帧来淘汰旧来源。
        retireSources(expiredSources)
        guard self.flightID == flightID else { return }
        if items.isEmpty { finish() }
    }

    /// SwiftUI 的显现动画完成后才允许原生淡出；旧会话或旧发送的回执没有处置权。
    func completeHandoff(for id: UUID, sessionID: UUID?) {
        guard flightID == id, self.sessionID == sessionID,
              case .awaitingPresentation = handoff else { return }
        handoff = .presented
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        items.values.forEach { $0.view.removeFromSuperview() }
        items.removeAll()
        flightID = nil
        sessionID = nil
        onHandoff = nil
        onCompletion = nil
        onMessagesPrepared = nil
        onSourcesRetired = nil
        handoff = .flying
        previousFrameAt = nil
    }

    /// 同一运动方程用于显示刷新与回归测试，测试不依赖真实帧率或动画计时器。
    func advance(at now: CFTimeInterval) {
        guard let flightID, let surface, surface.window != nil else {
            finish()
            return
        }
        let elapsed = now - startedAt
        let delta = max(0, previousFrameAt.map { now - $0 } ?? 0)
        previousFrameAt = now
        expireUnreadySources(at: now)
        guard self.flightID == flightID else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var missingTargets: Set<ChatSendPresentationSource> = []
        for (source, item) in items {
            if case .flying = handoff {
                if case .waitingIdentity = item.readiness {
                    // 已挂载的锚点也不能替代 Core 的准确身份确认。
                } else if let frame = item.presentationFrame(in: surface) {
                    let visible = frame.intersection(surface.bounds)
                    if visible.isNull || visible.width <= 1 || visible.height <= 1 {
                        if item.hasLanding {
                            missingTargets.insert(source)
                        }
                    } else {
                        // 首个布局回执可能早于呈现树挂载；已有显示帧负责接续就绪，不等第二次布局回执。
                        item.retarget(frame, at: now)
                    }
                }
                item.advance(by: delta, at: now)
            } else {
                guard item.view.superview === item.targetAnchor,
                      let frame = item.presentationFrame(in: surface) else {
                    missingTargets.insert(source)
                    continue
                }
                let visible = frame.intersection(surface.bounds)
                guard !visible.isNull, visible.width > 1, visible.height > 1 else {
                    missingTargets.insert(source)
                    continue
                }
                // 覆盖层已是目标 carrier 的子视图；这里仅判生命周期，不再逐帧写屏幕位置。
            }
            if case .fading(let startedAt) = handoff {
                item.view.alpha = max(0, 1 - (now - startedAt) / 0.12)
            }
        }
        CATransaction.commit()
        retireSources(missingTargets)
        guard self.flightID == flightID else { return }
        if items.isEmpty { finish(); return }

        let isSettled = items.values.allSatisfy(\.isSettled)
        if case .fading(let startedAt) = handoff {
            if now - startedAt >= 0.12 { finish() }
        } else if case .flying = handoff, elapsed >= 0.12, isSettled {
            let frames = items.compactMapValues { $0.presentationFrame(in: surface) }
            retireSources(Set(items.keys).subtracting(frames.keys))
            guard self.flightID == flightID else { return }
            if items.isEmpty { finish(); return }
            // 布局回执可以先给出动画终值，必须等覆盖层与实际呈现位置也对齐才显现真实层。
            guard items.allSatisfy({ source, item in frames[source].map { item.isAligned(with: $0) } == true }) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let failedSources = Set(items.compactMap { source, item in item.moveIntoTargetCarrier() ? nil : source })
            CATransaction.commit()
            retireSources(failedSources)
            guard self.flightID == flightID else { return }
            if items.isEmpty { finish(); return }
            handoff = .awaitingPresentation
            let requestHandoff = onHandoff
            onHandoff = nil
            let accepted = requestHandoff?(flightID, sessionID) ?? false
            if !accepted, self.flightID == flightID { finish() }
        }
        // 显现后的位移已共用真实几何，回执之后不再等待另一套弹簧重新收敛。
        if self.flightID == flightID, case .presented = handoff {
            handoff = .fading(startedAt: now)
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
