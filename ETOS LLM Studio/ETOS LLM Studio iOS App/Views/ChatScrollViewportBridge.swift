// ============================================================================
// ChatScrollViewportBridge.swift
// ============================================================================
// UIScrollView 语义度量、流式跟随与一次性几何偏移桥。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore

struct ChatScrollAnchorAdjustment: Equatable, Identifiable, Sendable {
    let id: UUID
    let deltaY: CGFloat

    nonisolated init(id: UUID = UUID(), deltaY: CGFloat) {
        self.id = id
        self.deltaY = deltaY
    }
}

struct ChatScrollMetricThresholds: Equatable, Sendable {
    let arrival: CGFloat
    let bottomPinned: CGFloat
    let bottomButton: CGFloat
    let historyLoading: CGFloat
}

struct ChatScrollMetricRegion: Equatable, Sendable {
    let isAtTop: Bool
    let isNearTopHistoryBoundary: Bool
    let isAtBottom: Bool
    let isBottomPinned: Bool
    let isPastBottomButtonThreshold: Bool
    let isNearBottomHistoryBoundary: Bool
}

struct ChatScrollMetricsObserver: UIViewRepresentable {
    @Binding var keepsBottomPinned: Bool
    let isStreaming: Bool
    let streamingDisplayMode: ChatStreamingDisplayMode
    let reduceMotion: Bool
    let metricsRefreshGeneration: UInt
    let metricThresholds: ChatScrollMetricThresholds
    let isViewportTransitioning: Bool
    let hasProgrammaticScrollCommand: Bool
    let anchorAdjustment: ChatScrollAnchorAdjustment?
    let onAnchorAdjustmentApplied: (UUID) -> Void
    let onUserPanBegan: () -> Void
    let onMetricsChange: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            keepsBottomPinned: $keepsBottomPinned,
            isStreaming: isStreaming,
            streamingDisplayMode: streamingDisplayMode,
            reduceMotion: reduceMotion,
            metricsRefreshGeneration: metricsRefreshGeneration,
            metricThresholds: metricThresholds,
            isViewportTransitioning: isViewportTransitioning,
            hasProgrammaticScrollCommand: hasProgrammaticScrollCommand,
            anchorAdjustment: anchorAdjustment,
            onAnchorAdjustmentApplied: onAnchorAdjustmentApplied,
            onUserPanBegan: onUserPanBegan,
            usesNativeSizeChangeAnchor: Self.usesNativeSizeChangeAnchor,
            onMetricsChange: onMetricsChange
        )
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMetricsChange = onMetricsChange
        coordinator.keepsBottomPinned = $keepsBottomPinned
        coordinator.streamingDisplayMode = streamingDisplayMode
        coordinator.reduceMotion = reduceMotion
        coordinator.metricsRefreshGeneration = metricsRefreshGeneration
        coordinator.metricThresholds = metricThresholds
        coordinator.anchorAdjustment = anchorAdjustment
        coordinator.onAnchorAdjustmentApplied = onAnchorAdjustmentApplied
        coordinator.onUserPanBegan = onUserPanBegan
        coordinator.updateScrollOwnership(
            isStreaming: isStreaming,
            isViewportTransitioning: isViewportTransitioning,
            hasProgrammaticScrollCommand: hasProgrammaticScrollCommand
        )
        uiView.coordinator = coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
            coordinator.applyAnchorAdjustmentIfNeeded()
        }
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.coordinator = nil
    }

    final class Coordinator: NSObject {
        private enum ViewportFollowMode {
            case animated
            case immediate
        }

        var onMetricsChange: (CGFloat, CGFloat, Bool) -> Void
        var keepsBottomPinned: Binding<Bool>
        var isStreaming: Bool
        var streamingDisplayMode: ChatStreamingDisplayMode
        var reduceMotion: Bool
        var metricsRefreshGeneration: UInt
        var metricThresholds: ChatScrollMetricThresholds
        var isViewportTransitioning: Bool
        var hasProgrammaticScrollCommand: Bool
        var anchorAdjustment: ChatScrollAnchorAdjustment?
        var onAnchorAdjustmentApplied: (UUID) -> Void
        var onUserPanBegan: () -> Void
        let usesNativeSizeChangeAnchor: Bool
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var pendingViewportFollow: DispatchWorkItem?
        private var pendingViewportFollowMode: ViewportFollowMode?
        private var pendingViewportFollowContentHeight: CGFloat?
        private var pendingViewportFollowForcesMinimumOffset = false
        private var pendingStreamingLayoutSettle: DispatchWorkItem?
        private var pendingStreamingLayoutSafeContentHeight: CGFloat?
        private var pendingStreamingLayoutStableContentHeight: CGFloat?
        private var pendingStreamingLayoutStableContentOverflowsViewport: Bool?
        private var pendingDistanceNotification: DispatchWorkItem?
        private var streamingFollowAnimator: UIViewPropertyAnimator?
        private var awaitsStreamingEndHandoff = false
        private var lastBoundsSize: CGSize?
        private var lastDistanceToBottom: CGFloat = 0
        private var lastDistanceToTop: CGFloat = 0
        private var hasReportedDistance = false
        private var lastReportedInteractionState = false
        private var lastReportedMetricRegion: ChatScrollMetricRegion?
        private var lastAppliedAnchorAdjustmentID: UUID?
        private var lastServicedMetricsRefreshGeneration: UInt

        init(
            keepsBottomPinned: Binding<Bool>,
            isStreaming: Bool,
            streamingDisplayMode: ChatStreamingDisplayMode,
            reduceMotion: Bool,
            metricsRefreshGeneration: UInt,
            metricThresholds: ChatScrollMetricThresholds,
            isViewportTransitioning: Bool,
            hasProgrammaticScrollCommand: Bool,
            anchorAdjustment: ChatScrollAnchorAdjustment?,
            onAnchorAdjustmentApplied: @escaping (UUID) -> Void,
            onUserPanBegan: @escaping () -> Void,
            usesNativeSizeChangeAnchor: Bool,
            onMetricsChange: @escaping (CGFloat, CGFloat, Bool) -> Void
        ) {
            self.keepsBottomPinned = keepsBottomPinned
            self.isStreaming = isStreaming
            self.streamingDisplayMode = streamingDisplayMode
            self.reduceMotion = reduceMotion
            self.metricsRefreshGeneration = metricsRefreshGeneration
            self.metricThresholds = metricThresholds
            self.isViewportTransitioning = isViewportTransitioning
            self.hasProgrammaticScrollCommand = hasProgrammaticScrollCommand
            self.anchorAdjustment = anchorAdjustment
            self.onAnchorAdjustmentApplied = onAnchorAdjustmentApplied
            self.onUserPanBegan = onUserPanBegan
            self.usesNativeSizeChangeAnchor = usesNativeSizeChangeAnchor
            self.onMetricsChange = onMetricsChange
            self.lastServicedMetricsRefreshGeneration = metricsRefreshGeneration
            super.init()
        }

        private var reliesOnNativeSizeChangeAnchor: Bool {
            usesNativeSizeChangeAnchor && !isStreaming
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                scheduleDistanceChangeNotification()
                applyAnchorAdjustmentIfNeeded()
                return
            }

            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            self.scrollView?.panGestureRecognizer.removeTarget(
                self,
                action: #selector(handlePanGesture(_:))
            )
            cancelPendingViewportFollow()
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutSafeContentHeight = nil
            pendingStreamingLayoutStableContentHeight = nil
            pendingStreamingLayoutStableContentOverflowsViewport = nil
            awaitsStreamingEndHandoff = false
            stopStreamingFollowAnimator(preservingVisiblePosition: false)
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            lastBoundsSize = scrollView.bounds.size
            hasReportedDistance = false
            lastDistanceToBottom = 0
            lastDistanceToTop = 0
            lastReportedInteractionState = false
            lastReportedMetricRegion = nil
            lastAppliedAnchorAdjustmentID = nil
            self.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(
                self,
                action: #selector(handlePanGesture(_:))
            )
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.scheduleDistanceChangeNotification()
            }
            contentSizeObservation = scrollView.observe(
                \.contentSize,
                options: [.initial, .old, .new]
            ) { [weak self] scrollView, change in
                self?.handleContentSizeChange(
                    from: change.oldValue,
                    to: change.newValue ?? scrollView.contentSize
                )
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] scrollView, _ in
                self?.handleBoundsChange(scrollView.bounds.size)
            }
            applyAnchorAdjustmentIfNeeded()
        }

        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(
                self,
                action: #selector(handlePanGesture(_:))
            )
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            boundsObservation?.invalidate()
            boundsObservation = nil
            cancelPendingViewportFollow()
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutSafeContentHeight = nil
            pendingStreamingLayoutStableContentHeight = nil
            pendingStreamingLayoutStableContentOverflowsViewport = nil
            awaitsStreamingEndHandoff = false
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            stopStreamingFollowAnimator(preservingVisiblePosition: false)
            lastAppliedAnchorAdjustmentID = nil
            scrollView = nil
        }

        func applyAnchorAdjustmentIfNeeded() {
            guard let anchorAdjustment,
                  anchorAdjustment.id != lastAppliedAnchorAdjustmentID,
                  let scrollView,
                  !isViewportTransitioning,
                  !hasProgrammaticScrollCommand else {
                return
            }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard !isUserInteracting else { return }

            cancelPendingViewportFollow()
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutSafeContentHeight = nil
            pendingStreamingLayoutStableContentHeight = nil
            pendingStreamingLayoutStableContentOverflowsViewport = nil
            stopStreamingFollowAnimator(preservingVisiblePosition: true)

            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let targetOffsetY = ChatScrollMetricsObserver.anchorAdjustedContentOffsetY(
                currentOffsetY: scrollView.contentOffset.y,
                deltaY: anchorAdjustment.deltaY,
                minimumOffsetY: minimumOffsetY,
                maximumOffsetY: maximumOffsetY
            )
            lastAppliedAnchorAdjustmentID = anchorAdjustment.id
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                    animated: false
                )
            }
            scheduleDistanceChangeNotification()
            onAnchorAdjustmentApplied(anchorAdjustment.id)
        }

        func updateScrollOwnership(
            isStreaming: Bool,
            isViewportTransitioning: Bool,
            hasProgrammaticScrollCommand: Bool
        ) {
            let didEndStreaming = self.isStreaming && !isStreaming
            let didEndViewportTransition = self.isViewportTransitioning
                && !isViewportTransitioning
            self.isStreaming = isStreaming
            self.isViewportTransitioning = isViewportTransitioning
            self.hasProgrammaticScrollCommand = hasProgrammaticScrollCommand
            if isStreaming {
                awaitsStreamingEndHandoff = false
            }

            if hasProgrammaticScrollCommand {
                awaitsStreamingEndHandoff = false
                cancelPendingViewportFollow()
                pendingStreamingLayoutSettle?.cancel()
                pendingStreamingLayoutSettle = nil
                pendingStreamingLayoutSafeContentHeight = nil
                pendingStreamingLayoutStableContentHeight = nil
                pendingStreamingLayoutStableContentOverflowsViewport = nil
                stopStreamingFollowAnimator(preservingVisiblePosition: true)
            } else if didEndStreaming {
                awaitsStreamingEndHandoff = true
                cancelPendingViewportFollow()
                pendingStreamingLayoutSettle?.cancel()
                pendingStreamingLayoutSettle = nil
                pendingStreamingLayoutSafeContentHeight = nil
                pendingStreamingLayoutStableContentHeight = nil
                pendingStreamingLayoutStableContentOverflowsViewport = nil
                stopStreamingFollowAnimator(preservingVisiblePosition: true)
                DispatchQueue.main.async { [weak self] in
                    self?.completeStreamingEndHandoff()
                }
            } else if didEndViewportTransition, awaitsStreamingEndHandoff {
                DispatchQueue.main.async { [weak self] in
                    self?.completeStreamingEndHandoff()
                }
            } else if didEndViewportTransition,
                      isStreaming,
                      pendingStreamingLayoutSettle == nil {
                cancelPendingViewportFollow()
                pendingStreamingLayoutStableContentHeight = nil
                pendingStreamingLayoutStableContentOverflowsViewport = nil
                scheduleViewportFollow(mode: .animated)
            }
        }

        private func handleContentSizeChange(from oldSize: CGSize?, to newSize: CGSize) {
            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            if isStreaming, let oldSize {
                let heightDelta = newSize.height - oldSize.height
                if pendingStreamingLayoutSettle != nil
                    || ChatScrollMetricsObserver.requiresStreamingLayoutSettle(
                        heightDelta: heightDelta
                    ) {
                    scheduleStreamingLayoutSettle(stableContentHeight: oldSize.height)
                } else if isViewportTransitioning {
                    captureStableStreamingLayoutIfNeeded(
                        contentHeight: oldSize.height,
                        boundsHeight: scrollView?.bounds.height
                    )
                    pendingStreamingLayoutStableContentHeight = newSize.height
                    scheduleViewportFollow(
                        mode: .immediate,
                        contentHeight: pendingStreamingLayoutStableContentHeight,
                        forcesMinimumOffset:
                            pendingStreamingLayoutStableContentOverflowsViewport == false
                    )
                } else {
                    scheduleViewportFollow(mode: .animated)
                }
            } else if ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
                keepsBottomPinned: keepsBottomPinned.wrappedValue,
                isUserInteracting: isUserInteracting,
                usesNativeSizeChangeAnchor: reliesOnNativeSizeChangeAnchor
            ) {
                scheduleViewportFollow(mode: .immediate)
            }
            scheduleDistanceChangeNotification()
        }

        /// 流式所有权交回原生尺寸锚点前闭合最后一小段距离，避免停在缓动半程。
        private func completeStreamingEndHandoff() {
            guard awaitsStreamingEndHandoff else { return }
            guard !isViewportTransitioning else { return }
            guard !isStreaming,
                  !hasProgrammaticScrollCommand,
                  anchorAdjustment == nil,
                  keepsBottomPinned.wrappedValue,
                  let scrollView else {
                awaitsStreamingEndHandoff = false
                return
            }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard !isUserInteracting else {
                awaitsStreamingEndHandoff = false
                return
            }
            awaitsStreamingEndHandoff = false
            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            guard abs(scrollView.contentOffset.y - maximumOffsetY) > 0.5 else { return }
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: maximumOffsetY),
                    animated: false
                )
            }
            scheduleDistanceChangeNotification()
        }

        private func handleBoundsChange(_ newSize: CGSize) {
            defer {
                lastBoundsSize = newSize
                scheduleDistanceChangeNotification()
            }
            guard let lastBoundsSize else { return }

            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            guard ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
                from: lastBoundsSize,
                to: newSize,
                keepsBottomPinned: keepsBottomPinned.wrappedValue,
                isUserInteracting: isUserInteracting,
                usesNativeSizeChangeAnchor: reliesOnNativeSizeChangeAnchor
            ) else {
                return
            }
            if isStreaming,
               isViewportTransitioning,
               pendingStreamingLayoutStableContentHeight == nil,
               let scrollView {
                captureStableStreamingLayoutIfNeeded(
                    contentHeight: scrollView.contentSize.height,
                    boundsHeight: lastBoundsSize.height
                )
            }
            scheduleViewportFollow(
                mode: .immediate,
                contentHeight: pendingStreamingLayoutStableContentHeight,
                forcesMinimumOffset: pendingStreamingLayoutStableContentOverflowsViewport == false
            )
        }

        private func captureStableStreamingLayoutIfNeeded(
            contentHeight: CGFloat,
            boundsHeight: CGFloat?
        ) {
            guard pendingStreamingLayoutStableContentHeight == nil,
                  let scrollView else {
                return
            }
            pendingStreamingLayoutStableContentHeight = contentHeight
            if hasReportedDistance {
                pendingStreamingLayoutStableContentOverflowsViewport =
                    lastDistanceToTop > 0.5 || lastDistanceToBottom > 0.5
            } else {
                pendingStreamingLayoutStableContentOverflowsViewport =
                    ChatScrollMetricsObserver.streamingContentOverflowsViewport(
                        contentHeight: contentHeight,
                        boundsHeight: boundsHeight ?? scrollView.bounds.height,
                        bottomInset: scrollView.adjustedContentInset.bottom
                    )
            }
        }

        /// bounds 与 contentSize 可能在同一布局批次交错变化；统一到下一轮只写一次偏移。
        private func scheduleViewportFollow(
            mode: ViewportFollowMode,
            contentHeight: CGFloat? = nil,
            forcesMinimumOffset: Bool = false
        ) {
            guard !reliesOnNativeSizeChangeAnchor else { return }
            if pendingViewportFollowMode != .immediate {
                pendingViewportFollowMode = mode
            }
            if let contentHeight {
                if let pendingHeight = pendingViewportFollowContentHeight {
                    pendingViewportFollowContentHeight = min(pendingHeight, contentHeight)
                } else {
                    pendingViewportFollowContentHeight = contentHeight
                }
            }
            pendingViewportFollowForcesMinimumOffset =
                pendingViewportFollowForcesMinimumOffset || forcesMinimumOffset
            guard pendingViewportFollow == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let mode = self.pendingViewportFollowMode ?? .immediate
                let contentHeight = self.pendingViewportFollowContentHeight
                let forcesMinimumOffset = self.pendingViewportFollowForcesMinimumOffset
                self.pendingViewportFollow = nil
                self.pendingViewportFollowMode = nil
                self.pendingViewportFollowContentHeight = nil
                self.pendingViewportFollowForcesMinimumOffset = false
                self.performViewportFollow(
                    mode: mode,
                    contentHeight: contentHeight,
                    forcesMinimumOffset: forcesMinimumOffset
                )
            }
            pendingViewportFollow = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func cancelPendingViewportFollow() {
            pendingViewportFollow?.cancel()
            pendingViewportFollow = nil
            pendingViewportFollowMode = nil
            pendingViewportFollowContentHeight = nil
            pendingViewportFollowForcesMinimumOffset = false
        }

        private func performViewportFollow(
            mode: ViewportFollowMode,
            contentHeight requestedContentHeight: CGFloat?,
            forcesMinimumOffset: Bool
        ) {
            guard let scrollView else { return }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard keepsBottomPinned.wrappedValue,
                  !isUserInteracting,
                  !hasProgrammaticScrollCommand else {
                return
            }

            let targetOffsetY = ChatScrollMetricsObserver.viewportFollowTargetOffsetY(
                requestedContentHeight: requestedContentHeight,
                actualContentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom,
                forcesMinimumOffset: forcesMinimumOffset
            )
            if mode == .immediate || !isStreaming {
                stopStreamingFollowAnimator(preservingVisiblePosition: false)
                if abs(scrollView.contentOffset.y - targetOffsetY) > 0.5 {
                    UIView.performWithoutAnimation {
                        scrollView.setContentOffset(
                            CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                            animated: false
                        )
                    }
                }
                scheduleDistanceChangeNotification()
                return
            }
            followSettledStreamingContent(targetOffsetY: targetOffsetY)
        }

        /// MarkdownUI 会在同一批内容内先后给出高、低两套测量值；窗口内只追最低安全底部。
        /// 保留已经开始的向上动画，避免每次测量都删除动画后让视口永久停在原位。
        private func scheduleStreamingLayoutSettle(stableContentHeight: CGFloat) {
            guard let scrollView else { return }
            cancelPendingViewportFollow()
            captureStableStreamingLayoutIfNeeded(
                contentHeight: stableContentHeight,
                boundsHeight: scrollView.bounds.height
            )
            let candidateContentHeight = scrollView.contentSize.height
            if let pendingStreamingLayoutSafeContentHeight {
                self.pendingStreamingLayoutSafeContentHeight = min(
                    pendingStreamingLayoutSafeContentHeight,
                    candidateContentHeight
                )
            } else {
                pendingStreamingLayoutSafeContentHeight = candidateContentHeight
            }
            if isViewportTransitioning {
                scheduleViewportFollow(
                    mode: .immediate,
                    contentHeight: pendingStreamingLayoutStableContentHeight,
                    forcesMinimumOffset:
                        pendingStreamingLayoutStableContentOverflowsViewport == false
                )
            }
            guard pendingStreamingLayoutSettle == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamingLayoutSettle = nil
                let safeContentHeight = self.pendingStreamingLayoutSafeContentHeight
                self.pendingStreamingLayoutSafeContentHeight = nil
                if self.isViewportTransitioning {
                    self.pendingStreamingLayoutStableContentHeight = safeContentHeight
                } else {
                    self.pendingStreamingLayoutStableContentHeight = nil
                    self.pendingStreamingLayoutStableContentOverflowsViewport = nil
                }
                self.scheduleViewportFollow(
                    mode: self.isViewportTransitioning ? .immediate : .animated,
                    contentHeight: safeContentHeight,
                    forcesMinimumOffset:
                        self.pendingStreamingLayoutStableContentOverflowsViewport == false
                )
            }
            pendingStreamingLayoutSettle = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: workItem)
        }

        /// 从呈现层接续运动并替换旧动画，确保任意时刻只有一个滚动所有者。
        private func followSettledStreamingContent(targetOffsetY requestedTargetOffsetY: CGFloat? = nil) {
            guard let scrollView else { return }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard isStreaming,
                  keepsBottomPinned.wrappedValue,
                  !isUserInteracting,
                  !hasProgrammaticScrollCommand else {
                return
            }

            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let targetOffsetY = min(requestedTargetOffsetY ?? maximumOffsetY, maximumOffsetY)
            let contentOverflowsViewport = ChatScrollMetricsObserver.streamingContentOverflowsViewport(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let visibleOffsetY = scrollView.layer.presentation()?.bounds.origin.y
                ?? scrollView.bounds.origin.y
            guard ChatScrollMetricsObserver.shouldApplyStreamingFollow(
                visibleOffsetY: visibleOffsetY,
                targetOffsetY: targetOffsetY
            ) else {
                // 高度回落时先停止仍朝旧高点运行的自有动画，保持用户当前可见位置。
                stopStreamingFollowAnimator(
                    preservingVisiblePosition: true,
                    clampsWithoutOwnedAnimator: true
                )
                return
            }
            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let startOffsetY = ChatScrollMetricsObserver.streamingFollowStartOffset(
                visibleOffsetY: visibleOffsetY,
                targetOffsetY: targetOffsetY,
                minimumOffsetY: minimumOffsetY
            )
            let shouldAnimate = ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
                contentOverflowsViewport: contentOverflowsViewport,
                visibleOffsetY: startOffsetY,
                targetOffsetY: targetOffsetY,
                reduceMotion: reduceMotion
            )

            stopStreamingFollowAnimator(preservingVisiblePosition: false)
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: startOffsetY),
                    animated: false
                )
            }
            let targetOffset = CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY)
            if shouldAnimate {
                let animator = UIViewPropertyAnimator(
                    duration: streamingDisplayMode.viewportFollowDuration,
                    curve: .easeOut
                ) {
                    scrollView.setContentOffset(targetOffset, animated: false)
                }
                streamingFollowAnimator = animator
                animator.addCompletion { [weak self, weak animator] _ in
                    guard let self, self.streamingFollowAnimator === animator else { return }
                    self.streamingFollowAnimator = nil
                }
                animator.startAnimation()
            } else {
                UIView.performWithoutAnimation {
                    scrollView.setContentOffset(targetOffset, animated: false)
                }
            }
        }

        private func stopStreamingFollowAnimator(
            preservingVisiblePosition: Bool,
            clampsWithoutOwnedAnimator: Bool = false
        ) {
            guard streamingFollowAnimator != nil || clampsWithoutOwnedAnimator else { return }
            let visibleOffsetY = scrollView?.layer.presentation()?.bounds.origin.y
                ?? scrollView?.bounds.origin.y
            if let animator = streamingFollowAnimator {
                animator.stopAnimation(true)
                streamingFollowAnimator = nil
            }
            guard preservingVisiblePosition,
                  let scrollView,
                  let visibleOffsetY,
                  visibleOffsetY.isFinite else {
                return
            }
            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let interruptedOffsetY = min(max(visibleOffsetY, minimumOffsetY), maximumOffsetY)
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: interruptedOffsetY),
                    animated: false
                )
            }
        }

        @objc private func handlePanGesture(_ gestureRecognizer: UIPanGestureRecognizer) {
            guard gestureRecognizer.state == .began else { return }
            // 新的触摸边沿必须无条件抢占；减速阶段 interaction Bool 可能仍为 true。
            onUserPanBegan()
            awaitsStreamingEndHandoff = false
            cancelPendingViewportFollow()
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutSafeContentHeight = nil
            pendingStreamingLayoutStableContentHeight = nil
            pendingStreamingLayoutStableContentOverflowsViewport = nil
            stopStreamingFollowAnimator(preservingVisiblePosition: true)
            keepsBottomPinned.wrappedValue = false
            notifyDistanceChange(forcesRefresh: true)
        }

        private func scheduleDistanceChangeNotification() {
            guard pendingDistanceNotification == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDistanceNotification = nil
                self.notifyDistanceChange()
            }
            pendingDistanceNotification = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func notifyDistanceChange(forcesRefresh explicitRefresh: Bool = false) {
            guard let scrollView else { return }
            let visibleMaxY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(scrollView.contentSize.height - visibleMaxY, 0)
            let distanceToTop = max(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, 0)
            let isUserInteracting = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
            let metricRegion = ChatScrollMetricsObserver.metricRegion(
                distanceToBottom: distanceToBottom,
                distanceToTop: distanceToTop,
                thresholds: metricThresholds
            )
            let semanticRegionChanged = lastReportedMetricRegion != metricRegion
            let generationForcesRefresh = ChatScrollMetricsObserver.shouldForceMetricsRefresh(
                generation: metricsRefreshGeneration,
                lastServicedGeneration: lastServicedMetricsRefreshGeneration
            )
            guard ChatScrollMetricsObserver.shouldNotifyMetrics(
                forcesRefresh: explicitRefresh || generationForcesRefresh,
                hasReportedDistance: hasReportedDistance,
                semanticRegionChanged: semanticRegionChanged,
                interactionChanged: lastReportedInteractionState != isUserInteracting
            ) else {
                lastDistanceToBottom = distanceToBottom
                lastDistanceToTop = distanceToTop
                return
            }
            if generationForcesRefresh {
                lastServicedMetricsRefreshGeneration = metricsRefreshGeneration
            }
            lastDistanceToBottom = distanceToBottom
            lastDistanceToTop = distanceToTop
            hasReportedDistance = true
            lastReportedInteractionState = isUserInteracting
            lastReportedMetricRegion = metricRegion
            onMetricsChange(distanceToBottom, distanceToTop, isUserInteracting)
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToScrollViewIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
        }

        func attachToScrollViewIfNeeded() {
            guard let coordinator, let scrollView = enclosingScrollView() else { return }
            coordinator.attach(to: scrollView)
        }

        private func enclosingScrollView() -> UIScrollView? {
            var currentSuperview = superview
            while let view = currentSuperview {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                currentSuperview = view.superview
            }
            return nil
        }
    }
}
