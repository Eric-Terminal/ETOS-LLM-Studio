// ============================================================================
// ChatViewTimelineNavigation.swift
// ============================================================================
// 四键时间线导航的目标解析、活动显隐与一次性顶部命令。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension ChatView {
    nonisolated static func shouldEnableTimelineEdgeNavigation(
        isHistoryBoundaryLoaded: Bool,
        distanceToEdge: CGFloat,
        arrivalTolerance: CGFloat = 1
    ) -> Bool {
        !isHistoryBoundaryLoaded || distanceToEdge > arrivalTolerance
    }

    nonisolated static func shouldEnableTimelineBottomNavigation(
        isLaterHistoryBoundaryLoaded: Bool,
        keepsBottomPinned: Bool,
        distanceToBottom: CGFloat,
        arrivalTolerance: CGFloat = 1
    ) -> Bool {
        if !isLaterHistoryBoundaryLoaded { return true }
        return !keepsBottomPinned && distanceToBottom > arrivalTolerance
    }

    nonisolated static func canPresentExpandedScrollNavigation(
        viewportHeight: CGFloat,
        panelHeight: CGFloat,
        minimumClearance: CGFloat = 32
    ) -> Bool {
        viewportHeight >= panelHeight + minimumClearance
    }

    nonisolated static func shouldRevealScrollNavigationForEdgeSwipe(
        startLocationX: CGFloat,
        viewportWidth: CGFloat,
        translation: CGSize,
        edgeActivationWidth: CGFloat = 56,
        minimumHorizontalDistance: CGFloat = 14
    ) -> Bool {
        guard viewportWidth > 0,
              startLocationX >= viewportWidth - edgeActivationWidth,
              translation.width <= -minimumHorizontalDistance else {
            return false
        }
        return abs(translation.width) > abs(translation.height) * 1.2
    }

    nonisolated static func shouldSuspendAdjacentNavigationForBottomArrival(
        awaitsFreshSnapshot: Bool,
        hasProgrammaticScrollOwnership: Bool,
        currentSnapshotRevision: UInt,
        baselineSnapshotRevision: UInt
    ) -> Bool {
        awaitsFreshSnapshot
            && (hasProgrammaticScrollOwnership
                || currentSnapshotRevision <= baselineSnapshotRevision)
    }

    var canNavigateToTimelineTop: Bool {
        !scrollCoordinator.chatNavigationMessageIDs.isEmpty
            && Self.shouldEnableTimelineEdgeNavigation(
                isHistoryBoundaryLoaded: viewModel.isHistoryFullyLoaded,
                distanceToEdge: scrollCoordinator.scrollDistanceToTop
            )
    }

    var canNavigateToTimelineBottom: Bool {
        !viewModel.displayMessages.isEmpty
            && Self.shouldEnableTimelineBottomNavigation(
                isLaterHistoryBoundaryLoaded: viewModel.isLaterHistoryFullyLoaded,
                keepsBottomPinned: scrollCoordinator.shouldKeepBottomPinned,
                distanceToBottom: scrollCoordinator.scrollDistanceToBottom
            )
    }

    func handleScrollToTopButtonTap() {
        guard appConfig.chatTimelineNavigationEnabled,
              let firstMessageID = viewModel.messageNavigationIDs().first else { return }
        revealScrollNavigationPanel()
        prepareForMessageJump()
        scrollCoordinator.messageNavigationCursorID = firstMessageID
        refreshMessageNavigationTargets()
        scheduleTimelineTopNavigation()
    }

    func handleScrollToBottomButtonTap() {
        revealScrollNavigationPanel()
        scrollCoordinator.pendingHistoryResetWorkItem?.cancel()
        scrollCoordinator.pendingHistoryResetWorkItem = nil
        shouldRestorePendingJumpOnAppear = false
        scrollCoordinator.lastAutomaticHistoryLoadAnchorID = nil
        scrollCoordinator.messageNavigationCursorID = nil
        scrollCoordinator.awaitsFreshBottomNavigationSnapshot = true
        scrollCoordinator.bottomNavigationSnapshotBaselineRevision = scrollCoordinator.chatLayoutIntegrityMonitor.currentSnapshotRevision
        scrollCoordinator.previousMessageNavigationTargetID = nil
        scrollCoordinator.nextMessageNavigationTargetID = nil

        let shouldResetHistoryWindow = viewModel.usesManualHistoryLoading
            || viewModel.usesAutomaticHistoryWindow
        scrollCoordinator.shouldKeepBottomPinned = true
        scrollCoordinator.showScrollToBottom = false

        guard shouldResetHistoryWindow else {
            scrollToBottom(
                animated: !accessibilityReduceMotion,
                animation: accessibilityReduceMotion
                    ? .linear(duration: 0)
                    : scrollToBottomButtonAnimation
            )
            return
        }

        scrollCoordinator.pendingBottomSnapTask?.cancel()
        scrollCoordinator.pendingBottomSnapTask = nil
        cancelPendingScrollTargetCommand()
        scrollCoordinator.chatScrollPositionController.releaseCommand()
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            viewModel.resetLazyLoadState()
        }
        let workItem = DispatchWorkItem {
            scrollCoordinator.pendingHistoryResetWorkItem = nil
            scheduleDeferredBottomSnap()
        }
        scrollCoordinator.pendingHistoryResetWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func handleAdjacentMessageNavigation(_ direction: ChatMessageNavigationDirection) {
        guard appConfig.chatTimelineNavigationEnabled,
              !scrollCoordinator.awaitsFreshBottomNavigationSnapshot else { return }
        let navigationMessageIDs = viewModel.messageNavigationIDs()
        guard let targetMessageID = scrollCoordinator.chatLayoutIntegrityMonitor.adjacentMessageID(
            in: navigationMessageIDs,
            viewportHeight: scrollCoordinator.chatScrollViewportHeight,
            retainedAnchorID: scrollCoordinator.messageNavigationCursorID,
            direction: direction
        ) else { return }

        revealScrollNavigationPanel()
        prepareForMessageJump()
        scrollCoordinator.messageNavigationCursorID = targetMessageID
        refreshMessageNavigationTargets()
        scheduleMessageJump(to: targetMessageID, usesAdjacentAnimation: true)
    }

    private func scheduleTimelineTopNavigation() {
        let generation = scrollCoordinator.scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        scrollCoordinator.pendingScrollTargetTask = Task { @MainActor in
            defer {
                if generation == scrollCoordinator.scrollTargetGeneration {
                    releaseMessageJumpScrollTarget()
                    pendingJumpRequest = nil
                    isMessageJumpInFlight = false
                    shouldRestorePendingJumpOnAppear = false
                    scrollCoordinator.pendingScrollTargetTask = nil
                }
            }

            await Task.yield()
            guard !Task.isCancelled,
                  canApplyScrollTarget(.top, generation: generation, sessionID: sessionID) else {
                return
            }
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.moveHistoryWindowToStart()
                scrollCoordinator.chatScrollPositionController.issueCommand(to: .top, anchor: .top)
            }
            scrollCoordinator.bottomScrollCommandGeneration &+= 1
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func refreshMessageNavigationIndex() {
        guard appConfig.chatTimelineNavigationEnabled else { return }
        let messageIDs = viewModel.messageNavigationIDs()
        guard scrollCoordinator.chatNavigationMessageIDs != messageIDs else {
            refreshMessageNavigationTargets()
            return
        }
        scrollCoordinator.chatNavigationMessageIDs = messageIDs
        scrollCoordinator.chatNavigationIndexByMessageID = Dictionary(
            uniqueKeysWithValues: messageIDs.enumerated().map { ($0.element, $0.offset) }
        )
        if let cursor = scrollCoordinator.messageNavigationCursorID,
           scrollCoordinator.chatNavigationIndexByMessageID[cursor] == nil {
            scrollCoordinator.messageNavigationCursorID = nil
        }
        refreshMessageNavigationTargets()
    }

    func refreshMessageNavigationTargets() {
        guard appConfig.chatTimelineNavigationEnabled else { return }
        if scrollCoordinator.awaitsFreshBottomNavigationSnapshot {
            let shouldSuspend = Self.shouldSuspendAdjacentNavigationForBottomArrival(
                awaitsFreshSnapshot: true,
                hasProgrammaticScrollOwnership: hasChatProgrammaticScrollOwnership,
                currentSnapshotRevision: scrollCoordinator.chatLayoutIntegrityMonitor.currentSnapshotRevision,
                baselineSnapshotRevision: scrollCoordinator.bottomNavigationSnapshotBaselineRevision
            )
            if shouldSuspend {
                scrollCoordinator.previousMessageNavigationTargetID = nil
                scrollCoordinator.nextMessageNavigationTargetID = nil
                return
            }
            scrollCoordinator.awaitsFreshBottomNavigationSnapshot = false
        }

        guard let anchorMessageID = scrollCoordinator.chatLayoutIntegrityMonitor.navigationAnchorMessageID(
            in: scrollCoordinator.chatNavigationIndexByMessageID,
            viewportHeight: scrollCoordinator.chatScrollViewportHeight,
            retainedAnchorID: scrollCoordinator.messageNavigationCursorID
        ), let anchorIndex = scrollCoordinator.chatNavigationIndexByMessageID[anchorMessageID] else {
            scrollCoordinator.previousMessageNavigationTargetID = nil
            scrollCoordinator.nextMessageNavigationTargetID = nil
            return
        }

        let previousTarget = anchorIndex > 0
            ? scrollCoordinator.chatNavigationMessageIDs[anchorIndex - 1]
            : nil
        let nextIndex = anchorIndex + 1
        let nextTarget = scrollCoordinator.chatNavigationMessageIDs.indices.contains(nextIndex)
            ? scrollCoordinator.chatNavigationMessageIDs[nextIndex]
            : nil
        if scrollCoordinator.previousMessageNavigationTargetID != previousTarget {
            scrollCoordinator.previousMessageNavigationTargetID = previousTarget
        }
        if scrollCoordinator.nextMessageNavigationTargetID != nextTarget {
            scrollCoordinator.nextMessageNavigationTargetID = nextTarget
        }
    }

    func revealScrollNavigationPanel() {
        guard appConfig.chatTimelineNavigationEnabled,
              !viewModel.displayMessages.isEmpty else { return }
        scrollCoordinator.scrollNavigationHideTask?.cancel()
        scrollCoordinator.scrollNavigationHideTask = nil
        if !scrollCoordinator.showScrollNavigationPanel {
            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)) {
                scrollCoordinator.showScrollNavigationPanel = true
            }
        }
        if !scrollCoordinator.isChatScrollUserInteracting {
            scheduleScrollNavigationPanelHide()
        }
    }

    func scheduleScrollNavigationPanelHide() {
        scrollCoordinator.scrollNavigationHideTask?.cancel()
        scrollCoordinator.scrollNavigationHideTask = nil
        guard scrollCoordinator.showScrollNavigationPanel, !accessibilityVoiceOverEnabled else { return }
        scrollCoordinator.scrollNavigationHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !scrollCoordinator.isChatScrollUserInteracting else { return }
            withAnimation(accessibilityReduceMotion ? nil : .easeIn(duration: 0.16)) {
                scrollCoordinator.showScrollNavigationPanel = false
            }
            scrollCoordinator.scrollNavigationHideTask = nil
        }
    }

    func hideScrollNavigationPanel() {
        scrollCoordinator.scrollNavigationHideTask?.cancel()
        scrollCoordinator.scrollNavigationHideTask = nil
        guard scrollCoordinator.showScrollNavigationPanel else { return }
        withAnimation(accessibilityReduceMotion ? nil : .easeIn(duration: 0.16)) {
            scrollCoordinator.showScrollNavigationPanel = false
        }
    }

    var scrollNavigationEdgeRevealGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard appConfig.chatTimelineNavigationEnabled,
                      !scrollCoordinator.showScrollNavigationPanel,
                      Self.shouldRevealScrollNavigationForEdgeSwipe(
                        startLocationX: value.startLocation.x,
                        viewportWidth: scrollCoordinator.chatScrollViewportWidth,
                        translation: value.translation
                      ) else { return }
                revealScrollNavigationPanel()
            }
            .onEnded { _ in
                guard scrollCoordinator.showScrollNavigationPanel else { return }
                scheduleScrollNavigationPanelHide()
            }
    }

    func handleChatScrollPanBegan() {
        let shouldCancelCommand = scrollCoordinator.prepareForUserPan(
            isMessageJumpInFlight: isMessageJumpInFlight,
            bottomScrollTarget: bottomScrollTarget
        )
        refreshMessageNavigationTargets()
        guard shouldCancelCommand else { return }
        cancelPendingScrollTargetCommand()
    }
}
