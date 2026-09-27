// ============================================================================
// ChatViewportMotionDriver.swift
// ============================================================================
// 仅在运动或布局交接期间逐帧读取 UIKit；不向 SwiftUI 发布逐像素状态。
// ============================================================================

import UIKit

@MainActor
final class ChatViewportMotionDriver {
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var spring: ChatMotionSpring?
    private var previousTimestamp: CFTimeInterval?
    private var shouldContinue: () -> Bool = { false }
    private var onCompletion: () -> Void = {}

    var isActive: Bool { displayLink != nil }

    func follow(
        to targetOffsetY: CGFloat,
        in scrollView: UIScrollView,
        responseDuration: TimeInterval,
        shouldContinue: @escaping () -> Bool,
        onCompletion: @escaping () -> Void
    ) {
        self.scrollView = scrollView
        self.shouldContinue = shouldContinue
        self.onCompletion = onCompletion
        if spring != nil {
            // 输出改变终点时不重置起点和速度，避免反复 easeOut 产生追赶节奏。
            spring?.retarget(to: targetOffsetY, responseDuration: responseDuration)
        } else {
            spring = ChatMotionSpring(
                position: scrollView.contentOffset.y,
                target: targetOffsetY,
                responseDuration: responseDuration
            )
        }
        guard displayLink == nil else { return }
        previousTimestamp = CACurrentMediaTime()
        let target = ChatViewportDisplayLinkTarget { [weak self] link in self?.advance(link) }
        let link = CADisplayLink(target: target, selector: #selector(ChatViewportDisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        spring = nil
        previousTimestamp = nil
        shouldContinue = { false }
        onCompletion = {}
    }

    private func advance(_ link: CADisplayLink) {
        guard let scrollView, var spring, shouldContinue() else {
            complete()
            return
        }
        let timestamp = link.targetTimestamp
        let deltaTime = max(timestamp - (previousTimestamp ?? timestamp), 0)
        previousTimestamp = timestamp
        spring.advance(by: deltaTime)

        let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
        // 临时缩高不允许继续追旧终点；合法范围缩小时交回布局系统处理。
        guard maximumOffsetY >= scrollView.contentOffset.y - 0.5 else {
            complete()
            return
        }
        let target = min(spring.target, maximumOffsetY)
        let offset = min(max(spring.position, scrollView.contentOffset.y), target)
        let reachedTarget = spring.isSettled || spring.position >= target
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: reachedTarget ? target : offset),
                animated: false
            )
        }
        self.spring = spring
        if reachedTarget { complete() }
    }

    private func complete() {
        let completion = onCompletion
        stop()
        completion()
    }
}

/// 布局完成依赖连续呈现帧的实际几何，而不是某个猜测的键盘动画时长。
@MainActor
final class ChatViewportLayoutSettlementObserver {
    private struct Geometry: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets
    }

    private var displayLink: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var previousGeometry: Geometry?
    private var stableFrameCount = 0
    private var onSettled: () -> Void = {}

    func observe(_ scrollView: UIScrollView, onSettled: @escaping () -> Void) {
        stop()
        self.scrollView = scrollView
        self.onSettled = onSettled
        let target = ChatViewportDisplayLinkTarget { [weak self] _ in self?.sample() }
        let link = CADisplayLink(target: target, selector: #selector(ChatViewportDisplayLinkTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousGeometry = nil
        stableFrameCount = 0
        onSettled = {}
    }

    private func sample() {
        guard let scrollView else { stop(); return }
        let geometry = Geometry(
            size: scrollView.layer.presentation()?.bounds.size ?? scrollView.bounds.size,
            insets: scrollView.adjustedContentInset
        )
        stableFrameCount = geometry == previousGeometry ? stableFrameCount + 1 : 0
        previousGeometry = geometry
        guard stableFrameCount >= 2 else { return }
        let completion = onSettled
        stop()
        completion()
    }
}

@MainActor
private final class ChatViewportDisplayLinkTarget: NSObject {
    private let onFrame: (CADisplayLink) -> Void

    init(onFrame: @escaping (CADisplayLink) -> Void) { self.onFrame = onFrame }

    @objc func tick(_ link: CADisplayLink) { onFrame(link) }
}
