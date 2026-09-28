// ============================================================================
// ChatViewportMotionBridgeTests.swift
// ============================================================================

import Foundation
import SwiftUI
import Testing
import UIKit
import ETOSCore
@testable import ETOS_LLM_Studio_App

@MainActor
struct ChatViewportMotionBridgeTests {
    @Test("最后一轮 Markdown 增高等待期间不会提前交还流式滚动所有权")
    func finalLayoutGrowthRetainsMotionOwnership() async {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 1_000)
        scrollView.contentOffset.y = 400
        var observesFinalGrowth = false
        var isFollowing = false
        var releaseOffsets: [CGFloat] = []
        let coordinator = makeCoordinator { isActive in
            isFollowing = isActive
            if observesFinalGrowth, !isActive { releaseOffsets.append(scrollView.contentOffset.y) }
        }
        defer { coordinator.detach() }
        coordinator.attach(to: scrollView)
        await flushMainQueue()

        scrollView.contentSize.height = 1_020
        await flushMainQueue()
        coordinator.updateScrollOwnership(
            isStreaming: false,
            isViewportTransitioning: false,
            hasProgrammaticScrollCommand: false
        )
        await flushMainQueue()
        // 先进入收尾，再用真实位置确认旧运动接近结束；此时仍有运动所有权。
        await waitUntil { scrollView.contentOffset.y >= 419.7 }
        #expect(isFollowing)
        observesFinalGrowth = true
        scrollView.contentSize.height = 1_400
        await waitUntil { !releaseOffsets.isEmpty && abs(scrollView.contentOffset.y - 800) < 0.5 }

        #expect(!releaseOffsets.isEmpty)
        #expect(releaseOffsets.allSatisfy { abs($0 - 800) < 0.5 })
        #expect(abs(scrollView.contentOffset.y - 800) < 0.5)
    }

    @Test("非活动聊天停止跟随并在恢复后使用当前几何")
    func inactiveViewportDoesNotFollowBackgroundGrowth() async {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 1_000)
        scrollView.contentOffset.y = 400
        var isFollowing = false
        let coordinator = makeCoordinator { isFollowing = $0 }
        defer { coordinator.detach() }
        coordinator.attach(to: scrollView)
        await flushMainQueue()
        scrollView.contentSize.height = 1_060
        await flushMainQueue()
        coordinator.updateScrollOwnership(
            isStreaming: true,
            isViewportTransitioning: false,
            hasProgrammaticScrollCommand: false,
            isViewportActive: false
        )
        await flushMainQueue()
        let suspendedOffset = scrollView.contentOffset.y
        scrollView.contentSize.height = 1_500
        await flushMainQueue()

        #expect(!isFollowing)
        #expect(scrollView.contentOffset.y == suspendedOffset)

        coordinator.updateScrollOwnership(
            isStreaming: true,
            isViewportTransitioning: false,
            hasProgrammaticScrollCommand: false,
            isViewportActive: true
        )
        await flushMainQueue()
        #expect(scrollView.contentOffset.y == 900)
    }

    private func makeCoordinator(
        onActivityChange: @escaping (Bool) -> Void
    ) -> ChatScrollMetricsObserver.Coordinator {
        ChatScrollMetricsObserver.Coordinator(
            keepsBottomPinned: .constant(true),
            isStreaming: true,
            streamingDisplayMode: .immediate,
            reduceMotion: false,
            metricsRefreshGeneration: 0,
            metricThresholds: ChatScrollMetricThresholds(
                arrival: 1,
                bottomPinned: 24,
                bottomButton: 48,
                historyLoading: 240
            ),
            isViewportTransitioning: false,
            hasProgrammaticScrollCommand: false,
            anchorAdjustment: nil,
            onAnchorAdjustmentApplied: { _ in },
            viewportPageRequest: nil,
            onViewportPageRequestCompleted: { _ in },
            onUserPanBegan: {},
            usesNativeSizeChangeAnchor: false,
            onStreamingFollowActivityChange: onActivityChange,
            onMetricsChange: { _, _, _ in }
        )
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
