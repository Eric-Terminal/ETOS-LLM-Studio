// ============================================================================
// ChatScrollCoordinatorTests.swift
// ============================================================================
// 聊天滚动协调、历史锚点、UIKit 滚动桥与时间线导航回归测试。
// ============================================================================

import Foundation
import SwiftUI
import Testing
import UIKit
import ETOSCore
@testable import ETOS_LLM_Studio_App

struct ChatScrollCoordinatorTests {

    @Test("弹性滚动不会拉开同轮相连气泡")
    func testChatScrollTransitionKeepsConnectedBubblesTogether() {
        let standaloneOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: false
        )
        #expect(standaloneOffset == 16)

        let connectedOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: true
        )
        #expect(connectedOffset == 0)

        let disabledOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: false,
            isConnectedToAdjacentBubble: false
        )
        #expect(disabledOffset == 0)

        let bottomPinnedStreamingOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: false,
            isBottomPinnedStreamingBubble: true
        )
        #expect(bottomPinnedStreamingOffset == 0)

        let viewportTransitionOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: false,
            isViewportTransitioning: true
        )
        #expect(viewportTransitionOffset == 0)
    }

    @MainActor
    @Test("吸底命令使用消息栈的真实尾部锚点")
    func testChatBottomScrollTargetsTrueStackEnd() {
        #expect(ChatView.resolvedBottomScrollTarget == .bottom)
    }

    @MainActor
    @Test("系统位置回写不会被误判为程序化滚动")
    func testObservedScrollPositionDoesNotClaimCommandOwnership() {
        let controller = ChatScrollPositionController()

        controller.acceptObservedPosition(.message(UUID()))

        #expect(!controller.hasActiveCommand)
    }

    @MainActor
    @Test("程序化滚动期间拒绝中间位置回写并在释放后恢复观测")
    func testScrollCommandOwnsBindingOnlyForItsLifetime() {
        let controller = ChatScrollPositionController()
        let target = ChatScrollTargetID.message(UUID())
        let intermediate = ChatScrollTargetID.message(UUID())

        controller.issueCommand(to: target, anchor: .center)
        controller.acceptObservedPosition(intermediate)

        #expect(controller.hasActiveCommand)
        #expect(controller.positionBinding.wrappedValue == target)

        controller.releaseCommand(expectedTarget: target)
        controller.acceptObservedPosition(intermediate)

        #expect(!controller.hasActiveCommand)
        #expect(controller.positionBinding.wrappedValue == intermediate)
    }

    @MainActor
    @Test("历史扩窗按同一消息行的几何差生成一次偏移校正")
    func testHistoryWindowMutationPreservesViewportAnchor() {
        let controller = ChatHistoryViewportAnchorController()
        let earlierMessageID = UUID()
        let anchorMessageID = UUID()
        let trailingMessageID = UUID()
        let initialMessageIDs = [anchorMessageID, trailingMessageID]

        controller.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 24, width: 300, height: 80)],
            displayedMessageIDs: initialMessageIDs
        )
        #expect(controller.beginMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: initialMessageIDs
        ))

        // 与历史窗口无关的重排不能提前消费锚点。
        controller.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 30, width: 300, height: 80)],
            displayedMessageIDs: initialMessageIDs
        )
        #expect(controller.pendingAdjustment == nil)

        controller.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 184, width: 300, height: 80)],
            displayedMessageIDs: [earlierMessageID, anchorMessageID, trailingMessageID]
        )

        let adjustment = controller.pendingAdjustment
        #expect(adjustment?.deltaY == 160)
        #expect(adjustment.map { controller.completeAdjustment(id: $0.id) } == true)
        #expect(!controller.isRestoringAnchor)
    }

    @MainActor
    @Test("缺少真实行几何时不会开始历史窗口变更")
    func testHistoryWindowMutationRequiresVisibleAnchorFrame() {
        let controller = ChatHistoryViewportAnchorController()
        let messageID = UUID()

        #expect(!controller.beginMutation(
            anchorMessageID: messageID,
            displayedMessageIDs: [messageID]
        ))
        #expect(!controller.isRestoringAnchor)
    }

    @MainActor
    @Test("滚动协调器统一持有历史扩窗的完整生命周期")
    func testScrollCoordinatorOwnsHistoryMutationLifecycle() {
        let coordinator = ChatScrollCoordinator()
        let earlierMessageID = UUID()
        let anchorMessageID = UUID()
        let initialMessageIDs = [anchorMessageID]

        coordinator.chatHistoryViewportAnchorController.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 40, width: 300, height: 80)],
            displayedMessageIDs: initialMessageIDs
        )
        #expect(coordinator.beginAutomaticHistoryMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: initialMessageIDs
        ))
        #expect(coordinator.isHistoryLoadInFlight)
        #expect(coordinator.suppressAutoScrollOnce)
        #expect(!coordinator.shouldKeepBottomPinned)
        #expect(!coordinator.beginAutomaticHistoryMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: initialMessageIDs
        ))

        coordinator.chatHistoryViewportAnchorController.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 180, width: 300, height: 80)],
            displayedMessageIDs: [earlierMessageID, anchorMessageID]
        )
        let adjustment = coordinator.pendingAnchorAdjustment
        #expect(adjustment?.deltaY == 140)
        #expect(adjustment.map { coordinator.completeAnchorAdjustment(id: $0.id) } == true)
        #expect(!coordinator.isHistoryLoadInFlight)

        coordinator.cancelAutomaticHistoryNavigation()
        #expect(coordinator.lastAutomaticHistoryLoadAnchorID == nil)
        #expect(!coordinator.chatHistoryViewportAnchorController.isRestoringAnchor)
    }

    @MainActor
    @Test("历史数据未变化时协调器释放锚点与自动滚动抑制")
    func testScrollCoordinatorCancelsUnchangedHistoryMutation() {
        let coordinator = ChatScrollCoordinator()
        let anchorMessageID = UUID()

        coordinator.chatHistoryViewportAnchorController.updateFrames(
            [anchorMessageID: CGRect(x: 0, y: 40, width: 300, height: 80)],
            displayedMessageIDs: [anchorMessageID]
        )
        #expect(coordinator.beginManualHistoryMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: [anchorMessageID]
        ))

        coordinator.finishHistoryMutation(didLoad: false)

        #expect(!coordinator.isHistoryLoadInFlight)
        #expect(!coordinator.suppressAutoScrollOnce)
        #expect(!coordinator.chatHistoryViewportAnchorController.isRestoringAnchor)
    }

    @Test("吸底命令抵达底部或超过最长占用时间后释放")
    func testChatBottomScrollCommandReleaseLifecycle() {
        #expect(ChatView.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: true,
            distanceToBottom: 0,
            arrivalTolerance: 1
        ))
        #expect(!ChatView.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: true,
            distanceToBottom: 8,
            arrivalTolerance: 1
        ))
        #expect(ChatView.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: true,
            distanceToBottom: 8,
            arrivalTolerance: 1,
            hasExceededMaximumLifetime: true
        ))
        #expect(!ChatView.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: false,
            distanceToBottom: 0,
            arrivalTolerance: 1,
            hasExceededMaximumLifetime: true
        ))
    }

    @Test("无位移吸底命令按代次只越过去重边界一次")
    func testActiveBottomCommandForcesMetricsCallback() {
        #expect(ChatScrollMetricsObserver.shouldForceMetricsRefresh(
            generation: 8,
            lastServicedGeneration: 7
        ))
        #expect(!ChatScrollMetricsObserver.shouldForceMetricsRefresh(
            generation: 8,
            lastServicedGeneration: 8
        ))
        #expect(ChatScrollMetricsObserver.shouldNotifyMetrics(
            forcesRefresh: true,
            hasReportedDistance: true,
            semanticRegionChanged: false,
            interactionChanged: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldNotifyMetrics(
            forcesRefresh: false,
            hasReportedDistance: true,
            semanticRegionChanged: false,
            interactionChanged: false
        ))
        #expect(ChatScrollMetricsObserver.shouldNotifyMetrics(
            forcesRefresh: false,
            hasReportedDistance: true,
            semanticRegionChanged: true,
            interactionChanged: false
        ))
    }

    @Test("滚动度量只在跨过交互语义边界时进入 SwiftUI")
    func testChatScrollMetricRegionsIgnorePixelMotion() {
        let thresholds = ChatScrollMetricThresholds(
            arrival: 1,
            bottomPinned: 24,
            bottomButton: 48,
            historyLoading: 240
        )
        let first = ChatScrollMetricsObserver.metricRegion(
            distanceToBottom: 90,
            distanceToTop: 100,
            thresholds: thresholds
        )
        let sameRegion = ChatScrollMetricsObserver.metricRegion(
            distanceToBottom: 120,
            distanceToTop: 140,
            thresholds: thresholds
        )
        let crossedHistoryBoundary = ChatScrollMetricsObserver.metricRegion(
            distanceToBottom: 260,
            distanceToTop: 140,
            thresholds: thresholds
        )

        #expect(first == sameRegion)
        #expect(first != crossedHistoryBoundary)
    }

    @MainActor
    @Test("UIKit 滚动桥不会把同一区域内的逐像素移动回写给 SwiftUI")
    func testChatScrollBridgeSuppressesPixelLevelCallbacks() async {
        var keepsBottomPinned = false
        var callbackCount = 0
        let coordinator = ChatScrollMetricsObserver.Coordinator(
            keepsBottomPinned: Binding(
                get: { keepsBottomPinned },
                set: { keepsBottomPinned = $0 }
            ),
            isStreaming: false,
            streamingDisplayMode: .immediate,
            reduceMotion: true,
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
            onUserPanBegan: {},
            usesNativeSizeChangeAnchor: false,
            onMetricsChange: { _, _, _ in callbackCount += 1 }
        )
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 600)

        coordinator.attach(to: scrollView)
        await flushMainQueue()
        #expect(callbackCount == 1)

        for offsetY in [620.0, 640.0, 660.0] {
            scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
            await flushMainQueue()
        }
        #expect(callbackCount == 1)

        scrollView.contentOffset = CGPoint(x: 0, y: 200)
        await flushMainQueue()
        #expect(callbackCount == 2)
        coordinator.detach()
    }

    @MainActor
    @Test("UIKit 滚动桥只应用一次历史锚点偏移")
    func testChatScrollBridgeAppliesHistoryAnchorExactlyOnce() {
        var keepsBottomPinned = false
        var appliedAdjustmentIDs: [UUID] = []
        let adjustment = ChatScrollAnchorAdjustment(deltaY: 150)
        let coordinator = ChatScrollMetricsObserver.Coordinator(
            keepsBottomPinned: Binding(
                get: { keepsBottomPinned },
                set: { keepsBottomPinned = $0 }
            ),
            isStreaming: false,
            streamingDisplayMode: .immediate,
            reduceMotion: true,
            metricsRefreshGeneration: 0,
            metricThresholds: ChatScrollMetricThresholds(
                arrival: 1,
                bottomPinned: 24,
                bottomButton: 48,
                historyLoading: 240
            ),
            isViewportTransitioning: false,
            hasProgrammaticScrollCommand: false,
            anchorAdjustment: adjustment,
            onAnchorAdjustmentApplied: { appliedAdjustmentIDs.append($0) },
            onUserPanBegan: {},
            usesNativeSizeChangeAnchor: false,
            onMetricsChange: { _, _, _ in }
        )
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        scrollView.contentOffset = CGPoint(x: 0, y: 200)

        coordinator.attach(to: scrollView)
        #expect(scrollView.contentOffset.y == 350)
        #expect(appliedAdjustmentIDs == [adjustment.id])

        coordinator.applyAnchorAdjustmentIfNeeded()
        #expect(scrollView.contentOffset.y == 350)
        #expect(appliedAdjustmentIDs == [adjustment.id])
        coordinator.detach()
    }

    @MainActor
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test("只有贴底的布局变化暂停气泡滚动波浪")
    func testChatViewportTransitionSuppressionKeepsUserControl() {
        #expect(ChatView.shouldSuppressScrollTransitionForViewportChange(
            isLayoutSettling: true,
            keepsBottomPinned: true,
            isUserInteracting: false
        ))
        #expect(!ChatView.shouldSuppressScrollTransitionForViewportChange(
            isLayoutSettling: true,
            keepsBottomPinned: false,
            isUserInteracting: false
        ))
        #expect(!ChatView.shouldSuppressScrollTransitionForViewportChange(
            isLayoutSettling: true,
            keepsBottomPinned: true,
            isUserInteracting: true
        ))
        #expect(!ChatView.shouldSuppressScrollTransitionForViewportChange(
            isLayoutSettling: false,
            keepsBottomPinned: true,
            isUserInteracting: false
        ))
    }

    @Test("消息版本切换会释放已经消失的滚动目标")
    func testChatScrollTargetDropsInvisibleMessage() {
        let visibleMessageID = UUID()
        let removedMessageID = UUID()

        #expect(ChatView.retainedChatScrollTarget(
            .message(visibleMessageID),
            visibleMessageIDs: [visibleMessageID]
        ) == .message(visibleMessageID))
        #expect(ChatView.retainedChatScrollTarget(
            .message(removedMessageID),
            visibleMessageIDs: [visibleMessageID]
        ) == nil)
        #expect(ChatView.retainedChatScrollTarget(
            .top,
            visibleMessageIDs: []
        ) == .top)
        #expect(ChatView.retainedChatScrollTarget(
            .bottom,
            visibleMessageIDs: []
        ) == .bottom)
        #expect(ChatView.isChatScrollTargetAvailable(
            .message(visibleMessageID),
            visibleMessageIDs: [visibleMessageID]
        ))
        #expect(!ChatView.isChatScrollTargetAvailable(
            .message(removedMessageID),
            visibleMessageIDs: [visibleMessageID]
        ))
        #expect(ChatView.isChatScrollTargetAvailable(
            .top,
            visibleMessageIDs: []
        ))
        #expect(ChatView.isChatScrollTargetAvailable(
            .bottom,
            visibleMessageIDs: []
        ))
    }

    @Test("新的拖动边沿会抢占任何正在进行的程序滚动")
    func testPanBeganCancelsEveryProgrammaticScrollOwner() {
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: true,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: false,
            hasScrollTarget: false,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: false
        ))
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: true,
            hasPendingTargetTask: false,
            hasScrollTarget: false,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: false
        ))
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: true,
            hasScrollTarget: false,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: false
        ))
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: false,
            hasScrollTarget: true,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: false
        ))
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: false,
            hasScrollTarget: false,
            hasActiveBottomTarget: true,
            isMessageJumpInFlight: false
        ))
        #expect(ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: false,
            hasScrollTarget: false,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: true
        ))
        #expect(!ChatScrollCoordinator.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasPendingTargetTask: false,
            hasScrollTarget: false,
            hasActiveBottomTarget: false,
            isMessageJumpInFlight: false
        ))
    }

    @Test("时间线首尾按钮同时考虑全局窗口边界和真实距离")
    func testTimelineEdgeNavigationAvailability() {
        #expect(ChatView.shouldEnableTimelineEdgeNavigation(
            isHistoryBoundaryLoaded: false,
            distanceToEdge: 0
        ))
        #expect(ChatView.shouldEnableTimelineEdgeNavigation(
            isHistoryBoundaryLoaded: true,
            distanceToEdge: 20
        ))
        #expect(!ChatView.shouldEnableTimelineEdgeNavigation(
            isHistoryBoundaryLoaded: true,
            distanceToEdge: 0.5
        ))
        #expect(ChatView.shouldEnableTimelineBottomNavigation(
            isLaterHistoryBoundaryLoaded: false,
            keepsBottomPinned: true,
            distanceToBottom: 0
        ))
        #expect(!ChatView.shouldEnableTimelineBottomNavigation(
            isLaterHistoryBoundaryLoaded: true,
            keepsBottomPinned: true,
            distanceToBottom: 100
        ))
    }

    @Test("回底命令必须等新几何快照后才能恢复相邻导航")
    func testAdjacentNavigationWaitsForFreshBottomSnapshot() {
        #expect(ChatView.shouldSuspendAdjacentNavigationForBottomArrival(
            awaitsFreshSnapshot: true,
            hasProgrammaticScrollOwnership: true,
            currentSnapshotRevision: 12,
            baselineSnapshotRevision: 10
        ))
        #expect(ChatView.shouldSuspendAdjacentNavigationForBottomArrival(
            awaitsFreshSnapshot: true,
            hasProgrammaticScrollOwnership: false,
            currentSnapshotRevision: 10,
            baselineSnapshotRevision: 10
        ))
        #expect(!ChatView.shouldSuspendAdjacentNavigationForBottomArrival(
            awaitsFreshSnapshot: true,
            hasProgrammaticScrollOwnership: false,
            currentSnapshotRevision: 11,
            baselineSnapshotRevision: 10
        ))
    }

    @Test("显式导航期间暂停自动历史请求")
    func testExplicitNavigationSuspendsAutomaticHistoryRequests() {
        #expect(ChatView.shouldSuspendAutomaticHistoryNavigation(
            isMessageJumpInFlight: true,
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasActiveBottomTarget: false,
            hasPendingOrAppliedTarget: true
        ))
        #expect(!ChatView.shouldSuspendAutomaticHistoryNavigation(
            isMessageJumpInFlight: false,
            hasPendingHistoryReset: false,
            hasPendingBottomSnap: false,
            hasActiveBottomTarget: false,
            hasPendingOrAppliedTarget: false
        ))
    }

    @Test("紧凑聊天视口不会挤入完整四键导航栏")
    func testExpandedScrollNavigationRequiresVerticalClearance() {
        #expect(ChatView.canPresentExpandedScrollNavigation(
            viewportHeight: 240,
            panelHeight: 188
        ))
        #expect(!ChatView.canPresentExpandedScrollNavigation(
            viewportHeight: 210,
            panelHeight: 188
        ))
    }

    @Test("四键导航仅响应聊天区右缘向左横扫")
    func testScrollNavigationEdgeRevealGestureIntent() {
        #expect(ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 370,
            viewportWidth: 390,
            translation: CGSize(width: -24, height: 4)
        ))
        #expect(!ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 300,
            viewportWidth: 390,
            translation: CGSize(width: -24, height: 4)
        ))
        #expect(!ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 370,
            viewportWidth: 390,
            translation: CGSize(width: 24, height: 2)
        ))
        #expect(!ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 370,
            viewportWidth: 390,
            translation: CGSize(width: -18, height: 24)
        ))
    }

    @Test("输入栏收缩扩大聊天视口时会恢复底部锚点")
    func testChatScrollViewportResizeRestoresBottomAnchor() {
        let expandedComposerViewport = CGSize(width: 390, height: 248)
        let compactComposerViewport = CGSize(width: 390, height: 446)

        #expect(ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
            from: expandedComposerViewport,
            to: compactComposerViewport,
            keepsBottomPinned: true,
            isUserInteracting: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
            from: compactComposerViewport,
            to: compactComposerViewport,
            keepsBottomPinned: true,
            isUserInteracting: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
            from: expandedComposerViewport,
            to: compactComposerViewport,
            keepsBottomPinned: false,
            isUserInteracting: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
            from: expandedComposerViewport,
            to: compactComposerViewport,
            keepsBottomPinned: true,
            isUserInteracting: true
        ))
    }

    @Test("锁定底部时消息增长不会被增长后的距离拒绝")
    func testChatScrollContentGrowthPreservesBottomIntent() {
        #expect(ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: true,
            isUserInteracting: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: false,
            isUserInteracting: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: true,
            isUserInteracting: true
        ))
    }

    @Test("原生尺寸锚点生效时 UIKit 不会重复校正偏移")
    func testNativeSizeChangeAnchorOwnsContinuousBottomPinning() {
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: true,
            isUserInteracting: false,
            usesNativeSizeChangeAnchor: true
        ))
        #expect(!ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
            from: CGSize(width: 390, height: 248),
            to: CGSize(width: 390, height: 446),
            keepsBottomPinned: true,
            isUserInteracting: false,
            usesNativeSizeChangeAnchor: true
        ))
    }

    @Test("流式滚动只从屏幕实际位置向最终底部推进")
    func testStreamingFollowUsesVisibleOffset() {
        #expect(ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
            contentOverflowsViewport: true,
            visibleOffsetY: 52,
            targetOffsetY: 76,
            reduceMotion: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
            contentOverflowsViewport: true,
            visibleOffsetY: 76,
            targetOffsetY: 52,
            reduceMotion: false
        ))
        #expect(!ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
            contentOverflowsViewport: true,
            visibleOffsetY: 52,
            targetOffsetY: 76,
            reduceMotion: true
        ))
        #expect(!ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
            contentOverflowsViewport: false,
            visibleOffsetY: 52,
            targetOffsetY: 76,
            reduceMotion: false
        ))

        #expect(ChatScrollMetricsObserver.shouldApplyStreamingFollow(
            visibleOffsetY: 52,
            targetOffsetY: 76
        ))
        #expect(!ChatScrollMetricsObserver.shouldApplyStreamingFollow(
            visibleOffsetY: 76,
            targetOffsetY: 52
        ))

        #expect(ChatScrollMetricsObserver.requiresStreamingLayoutSettle(heightDelta: 640))
        #expect(ChatScrollMetricsObserver.requiresStreamingLayoutSettle(heightDelta: -458))
        #expect(!ChatScrollMetricsObserver.requiresStreamingLayoutSettle(heightDelta: 48))

        #expect(ChatScrollMetricsObserver.streamingFollowStartOffset(
            visibleOffsetY: 52,
            targetOffsetY: 76,
            minimumOffsetY: 0
        ) == 64)
        #expect(ChatScrollMetricsObserver.streamingFollowStartOffset(
            visibleOffsetY: 72,
            targetOffsetY: 76,
            minimumOffsetY: 0
        ) == 72)

        #expect(ChatScrollMetricsObserver.viewportFollowTargetOffsetY(
            requestedContentHeight: 1_000,
            actualContentHeight: 1_000,
            boundsHeight: 600,
            topInset: 0,
            bottomInset: 0,
            forcesMinimumOffset: false
        ) == 400)
        #expect(ChatScrollMetricsObserver.viewportFollowTargetOffsetY(
            requestedContentHeight: 1_000,
            actualContentHeight: 900,
            boundsHeight: 600,
            topInset: 0,
            bottomInset: 0,
            forcesMinimumOffset: false
        ) == 300)
        #expect(ChatScrollMetricsObserver.viewportFollowTargetOffsetY(
            requestedContentHeight: 1_000,
            actualContentHeight: 1_000,
            boundsHeight: 600,
            topInset: 12,
            bottomInset: 0,
            forcesMinimumOffset: true
        ) == -12)
    }
}
