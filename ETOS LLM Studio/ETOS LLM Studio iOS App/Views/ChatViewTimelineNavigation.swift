// ============================================================================
// ChatViewTimelineNavigation.swift
// ============================================================================
// 四键时间线导航的视口翻页、活动显隐与首尾命令。
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

    nonisolated static func shouldLoadHistoryBeforeViewportPage(
        isHistoryBoundaryLoaded: Bool,
        distanceToEdge: CGFloat,
        arrivalTolerance: CGFloat = 1
    ) -> Bool {
        !isHistoryBoundaryLoaded && distanceToEdge <= arrivalTolerance
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
        !viewModel.displayMessages.isEmpty
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

    var canNavigateOnePageUp: Bool {
        !viewModel.displayMessages.isEmpty
            && Self.shouldEnableTimelineEdgeNavigation(
                isHistoryBoundaryLoaded: viewModel.isHistoryFullyLoaded,
                distanceToEdge: scrollCoordinator.scrollDistanceToTop
            )
    }

    var canNavigateOnePageDown: Bool {
        !viewModel.displayMessages.isEmpty
            && Self.shouldEnableTimelineEdgeNavigation(
                isHistoryBoundaryLoaded: viewModel.isLaterHistoryFullyLoaded,
                distanceToEdge: scrollCoordinator.scrollDistanceToBottom
            )
    }

    func handleScrollToTopButtonTap() {
        guard appConfig.chatTimelineNavigationEnabled,
              !viewModel.displayMessages.isEmpty else { return }
        revealScrollNavigationPanel()
        prepareForMessageJump()
        scheduleTimelineTopNavigation()
    }

    func handleScrollToBottomButtonTap() {
        revealScrollNavigationPanel()
        scrollCoordinator.prepareForExclusiveViewportNavigation()
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
                    : scrollToBottomButtonAnimation,
                allowsDuringUserInteraction: true
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
            scheduleDeferredBottomSnap(allowsDuringUserInteraction: true)
        }
        scrollCoordinator.pendingHistoryResetWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func handleViewportPageNavigation(_ direction: ChatViewportPageDirection) {
        guard appConfig.chatTimelineNavigationEnabled,
              !scrollCoordinator.awaitsFreshBottomNavigationSnapshot,
              (direction == .upward ? canNavigateOnePageUp : canNavigateOnePageDown) else {
            return
        }

        revealScrollNavigationPanel()
        cancelPendingScrollTargetCommand()
        scrollCoordinator.prepareForExclusiveViewportNavigation()
        scrollCoordinator.pendingHistoryResetWorkItem?.cancel()
        scrollCoordinator.pendingHistoryResetWorkItem = nil
        scrollCoordinator.pendingBottomSnapTask?.cancel()
        scrollCoordinator.pendingBottomSnapTask = nil
        scrollCoordinator.awaitsFreshBottomNavigationSnapshot = false
        scrollCoordinator.lastAutomaticHistoryLoadAnchorID = nil
        scrollCoordinator.messageNavigationCursorID = nil
        scrollCoordinator.previousMessageNavigationTargetID = nil
        scrollCoordinator.nextMessageNavigationTargetID = nil
        scrollCoordinator.needsImmediateBottomSnap = false
        scrollCoordinator.shouldKeepBottomPinned = false
        pendingJumpRequest = nil
        isMessageJumpInFlight = false
        shouldRestorePendingJumpOnAppear = false

        let generation = scrollCoordinator.scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        scrollCoordinator.pendingScrollTargetTask = Task { @MainActor in
            var pageRequestID: UUID?
            defer {
                if let pageRequestID {
                    scrollCoordinator.cancelViewportPageRequest(id: pageRequestID)
                }
                if generation == scrollCoordinator.scrollTargetGeneration {
                    if scrollCoordinator.isHistoryLoadInFlight {
                        scrollCoordinator.cancelHistoryAnchorRestoration()
                    }
                    scrollCoordinator.pendingScrollTargetTask = nil
                }
            }

            await Task.yield()
            guard !Task.isCancelled,
                  generation == scrollCoordinator.scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id else {
                return
            }

            let distanceToEdge = direction == .upward
                ? scrollCoordinator.scrollDistanceToTop
                : scrollCoordinator.scrollDistanceToBottom
            let isHistoryBoundaryLoaded = direction == .upward
                ? viewModel.isHistoryFullyLoaded
                : viewModel.isLaterHistoryFullyLoaded
            if Self.shouldLoadHistoryBeforeViewportPage(
                isHistoryBoundaryLoaded: isHistoryBoundaryLoaded,
                distanceToEdge: distanceToEdge
            ) {
                // 边界行的 frame 可能和按键显现处于同一布局轮；短暂等待真实锚点再换窗。
                var beganHistoryMutation = false
                for _ in 0..<12 {
                    guard !Task.isCancelled,
                          generation == scrollCoordinator.scrollTargetGeneration,
                          sessionID == viewModel.currentSession?.id else {
                        return
                    }
                    let displayedMessageIDs = viewModel.displayMessages.map(\.id)
                    let anchorMessageID = direction == .upward
                        ? displayedMessageIDs.first
                        : displayedMessageIDs.last
                    if let anchorMessageID,
                       scrollCoordinator.beginViewportPageHistoryMutation(
                           anchorMessageID: anchorMessageID,
                           displayedMessageIDs: displayedMessageIDs
                       ) {
                        beganHistoryMutation = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                guard beganHistoryMutation else { return }

                let shiftDirection: ChatHistoryWindowShiftDirection = direction == .upward
                    ? .earlier
                    : .later
                let didLoad = viewModel.shiftHistoryWindow(
                    shiftDirection,
                    weightedBatchSize: 1,
                    preservesCurrentWindowSize: true
                )
                scrollCoordinator.finishHistoryMutation(didLoad: didLoad)
                guard didLoad else { return }

                for _ in 0..<75 {
                    guard !Task.isCancelled,
                          generation == scrollCoordinator.scrollTargetGeneration,
                          sessionID == viewModel.currentSession?.id else {
                        return
                    }
                    if !scrollCoordinator.isHistoryLoadInFlight { break }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                guard !scrollCoordinator.isHistoryLoadInFlight else {
                    scrollCoordinator.cancelHistoryAnchorRestoration()
                    return
                }
            }

            guard !Task.isCancelled,
                  generation == scrollCoordinator.scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id else {
                return
            }
            let requestID = scrollCoordinator.issueViewportPageRequest(direction: direction)
            pageRequestID = requestID
            for _ in 0..<75 {
                guard !Task.isCancelled,
                      generation == scrollCoordinator.scrollTargetGeneration,
                      sessionID == viewModel.currentSession?.id else {
                    return
                }
                if scrollCoordinator.pendingViewportPageRequest?.id != requestID { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
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
                scrollCoordinator.chatScrollPositionController.issueCommand(
                    to: .top,
                    anchor: .top,
                    allowsDuringUserInteraction: true
                )
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
        guard appConfig.chatTimelineNavigationEnabled,
              !scrollCoordinator.isChatScrollUserInteracting else { return }
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
        guard shouldCancelCommand else { return }
        cancelPendingScrollTargetCommand()
    }
}
