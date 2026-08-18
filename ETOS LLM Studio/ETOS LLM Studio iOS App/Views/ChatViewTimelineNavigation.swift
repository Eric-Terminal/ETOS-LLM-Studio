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
        !chatNavigationMessageIDs.isEmpty
            && Self.shouldEnableTimelineEdgeNavigation(
                isHistoryBoundaryLoaded: viewModel.isHistoryFullyLoaded,
                distanceToEdge: scrollDistanceToTop
            )
    }

    var canNavigateToTimelineBottom: Bool {
        !viewModel.displayMessages.isEmpty
            && Self.shouldEnableTimelineBottomNavigation(
                isLaterHistoryBoundaryLoaded: viewModel.isLaterHistoryFullyLoaded,
                keepsBottomPinned: shouldKeepBottomPinned,
                distanceToBottom: scrollDistanceToBottom
            )
    }

    func handleScrollToTopButtonTap() {
        guard appConfig.chatTimelineNavigationEnabled,
              let firstMessageID = viewModel.messageNavigationIDs().first else { return }
        revealScrollNavigationPanel()
        prepareForMessageJump()
        messageNavigationCursorID = firstMessageID
        refreshMessageNavigationTargets()
        scheduleTimelineTopNavigation()
    }

    func handleScrollToBottomButtonTap() {
        revealScrollNavigationPanel()
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        shouldRestorePendingJumpOnAppear = false
        lastAutomaticHistoryLoadAnchorID = nil
        messageNavigationCursorID = nil
        awaitsFreshBottomNavigationSnapshot = true
        bottomNavigationSnapshotBaselineRevision = chatLayoutIntegrityMonitor.currentSnapshotRevision
        previousMessageNavigationTargetID = nil
        nextMessageNavigationTargetID = nil

        let shouldResetHistoryWindow = viewModel.usesManualHistoryLoading
            || viewModel.usesAutomaticHistoryWindow
        shouldKeepBottomPinned = true
        showScrollToBottom = false

        guard shouldResetHistoryWindow else {
            scrollToBottom(
                animated: !accessibilityReduceMotion,
                animation: accessibilityReduceMotion
                    ? .linear(duration: 0)
                    : scrollToBottomButtonAnimation
            )
            return
        }

        let workItem = DispatchWorkItem {
            pendingBottomSnapTask?.cancel()
            pendingBottomSnapTask = nil
            cancelPendingScrollTargetCommand()
            chatScrollTarget = nil
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                viewModel.resetLazyLoadState()
            }
            pendingHistoryResetWorkItem = nil
            scheduleDeferredBottomSnap()
        }
        pendingHistoryResetWorkItem = workItem

        DispatchQueue.main.async(execute: workItem)
    }

    func handleAdjacentMessageNavigation(_ direction: ChatMessageNavigationDirection) {
        guard appConfig.chatTimelineNavigationEnabled,
              !awaitsFreshBottomNavigationSnapshot else { return }
        let navigationMessageIDs = viewModel.messageNavigationIDs()
        guard let targetMessageID = chatLayoutIntegrityMonitor.adjacentMessageID(
            in: navigationMessageIDs,
            viewportHeight: chatScrollViewportHeight,
            retainedAnchorID: messageNavigationCursorID,
            direction: direction
        ) else { return }

        revealScrollNavigationPanel()
        prepareForMessageJump()
        messageNavigationCursorID = targetMessageID
        refreshMessageNavigationTargets()
        scheduleMessageJump(to: targetMessageID, usesAdjacentAnimation: true)
    }

    private func scheduleTimelineTopNavigation() {
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        pendingScrollTargetTask = Task { @MainActor in
            defer {
                if generation == scrollTargetGeneration {
                    releaseMessageJumpScrollTarget()
                    pendingJumpRequest = nil
                    isMessageJumpInFlight = false
                    shouldRestorePendingJumpOnAppear = false
                    pendingScrollTargetTask = nil
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
                chatScrollTargetAnchor = .top
                chatScrollTarget = .top
            }
            bottomScrollCommandGeneration &+= 1
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func refreshMessageNavigationIndex() {
        guard appConfig.chatTimelineNavigationEnabled else { return }
        let messageIDs = viewModel.messageNavigationIDs()
        guard chatNavigationMessageIDs != messageIDs else {
            refreshMessageNavigationTargets()
            return
        }
        chatNavigationMessageIDs = messageIDs
        chatNavigationIndexByMessageID = Dictionary(
            uniqueKeysWithValues: messageIDs.enumerated().map { ($0.element, $0.offset) }
        )
        if let cursor = messageNavigationCursorID,
           chatNavigationIndexByMessageID[cursor] == nil {
            messageNavigationCursorID = nil
        }
        refreshMessageNavigationTargets()
    }

    func refreshMessageNavigationTargets() {
        guard appConfig.chatTimelineNavigationEnabled else { return }
        if awaitsFreshBottomNavigationSnapshot {
            let shouldSuspend = Self.shouldSuspendAdjacentNavigationForBottomArrival(
                awaitsFreshSnapshot: true,
                hasProgrammaticScrollOwnership: hasChatProgrammaticScrollOwnership,
                currentSnapshotRevision: chatLayoutIntegrityMonitor.currentSnapshotRevision,
                baselineSnapshotRevision: bottomNavigationSnapshotBaselineRevision
            )
            if shouldSuspend {
                previousMessageNavigationTargetID = nil
                nextMessageNavigationTargetID = nil
                return
            }
            awaitsFreshBottomNavigationSnapshot = false
        }

        guard let anchorMessageID = chatLayoutIntegrityMonitor.navigationAnchorMessageID(
            in: chatNavigationIndexByMessageID,
            viewportHeight: chatScrollViewportHeight,
            retainedAnchorID: messageNavigationCursorID
        ), let anchorIndex = chatNavigationIndexByMessageID[anchorMessageID] else {
            previousMessageNavigationTargetID = nil
            nextMessageNavigationTargetID = nil
            return
        }

        let previousTarget = anchorIndex > 0
            ? chatNavigationMessageIDs[anchorIndex - 1]
            : nil
        let nextIndex = anchorIndex + 1
        let nextTarget = chatNavigationMessageIDs.indices.contains(nextIndex)
            ? chatNavigationMessageIDs[nextIndex]
            : nil
        if previousMessageNavigationTargetID != previousTarget {
            previousMessageNavigationTargetID = previousTarget
        }
        if nextMessageNavigationTargetID != nextTarget {
            nextMessageNavigationTargetID = nextTarget
        }
    }

    func revealScrollNavigationPanel() {
        guard appConfig.chatTimelineNavigationEnabled,
              !viewModel.displayMessages.isEmpty else { return }
        scrollNavigationHideTask?.cancel()
        scrollNavigationHideTask = nil
        if !showScrollNavigationPanel {
            withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)) {
                showScrollNavigationPanel = true
            }
        }
        if !isChatScrollUserInteracting {
            scheduleScrollNavigationPanelHide()
        }
    }

    func scheduleScrollNavigationPanelHide() {
        scrollNavigationHideTask?.cancel()
        scrollNavigationHideTask = nil
        guard showScrollNavigationPanel, !accessibilityVoiceOverEnabled else { return }
        scrollNavigationHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !isChatScrollUserInteracting else { return }
            withAnimation(accessibilityReduceMotion ? nil : .easeIn(duration: 0.16)) {
                showScrollNavigationPanel = false
            }
            scrollNavigationHideTask = nil
        }
    }

    func hideScrollNavigationPanel() {
        scrollNavigationHideTask?.cancel()
        scrollNavigationHideTask = nil
        guard showScrollNavigationPanel else { return }
        withAnimation(accessibilityReduceMotion ? nil : .easeIn(duration: 0.16)) {
            showScrollNavigationPanel = false
        }
    }

    func handleChatScrollPanBegan() {
        revealScrollNavigationPanel()
        awaitsFreshBottomNavigationSnapshot = false
        messageNavigationCursorID = nil
        refreshMessageNavigationTargets()
        let shouldCancelCommand = Self.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: pendingHistoryResetWorkItem != nil,
            hasPendingBottomSnap: pendingBottomSnapTask != nil,
            hasPendingTargetTask: pendingScrollTargetTask != nil,
            hasScrollTarget: chatScrollTarget != nil,
            hasActiveBottomTarget: activeBottomScrollCommandTarget != nil,
            isMessageJumpInFlight: isMessageJumpInFlight
        )
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        guard shouldCancelCommand else { return }
        needsImmediateBottomSnap = false
        cancelPendingScrollTargetCommand()
    }
}
