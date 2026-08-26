// ============================================================================
// ChatViewHistoryLoading.swift
// ============================================================================
// iOS 聊天自动/手动历史扩窗与几何锚点恢复。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension ChatView {
    /// 手势阶段只记录加载意图，避免窗口变化打断 UIScrollView 的惯性减速。
    nonisolated static func shouldQueueAutomaticHistoryLoad(
        usesAutomaticHistoryWindow: Bool,
        isUserInteracting: Bool,
        distanceToEdge: CGFloat,
        triggerDistance: CGFloat,
        anchorMessageID: UUID?,
        lastLoadAnchorID: UUID?
    ) -> Bool {
        guard usesAutomaticHistoryWindow,
              isUserInteracting,
              distanceToEdge < triggerDistance,
              let anchorMessageID else {
            return false
        }
        return anchorMessageID != lastLoadAnchorID
    }


    func performAutomaticHistoryLoad(_ request: ChatAutomaticHistoryLoadRequest) {
        guard viewModel.usesAutomaticHistoryWindow else {
            return
        }
        let displayedMessageIDs = viewModel.displayMessages.map(\.id)
        guard scrollCoordinator.beginAutomaticHistoryMutation(
            anchorMessageID: request.anchorMessageID,
            displayedMessageIDs: displayedMessageIDs
        ) else {
            return
        }
        let didLoad: Bool
        switch request.direction {
        case .earlier:
            didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        case .later:
            didLoad = viewModel.loadMoreAutomaticLaterHistoryIfNeeded()
        }
        scrollCoordinator.finishHistoryMutation(didLoad: didLoad)
    }

    func performManualHistoryLoad() {
        guard viewModel.usesManualHistoryLoading,
              let anchorMessageID = viewModel.displayMessages.first?.id else {
            return
        }
        let displayedMessageIDs = viewModel.displayMessages.map(\.id)
        guard scrollCoordinator.beginManualHistoryMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: displayedMessageIDs
        ) else {
            return
        }
        scrollCoordinator.finishHistoryMutation(didLoad: viewModel.loadMoreHistoryChunk())
    }

    var pendingChatAnchorAdjustment: ChatScrollAnchorAdjustment? {
        scrollCoordinator.pendingAnchorAdjustment
    }

    func completeChatAnchorAdjustment(id: UUID) {
        scrollCoordinator.completeAnchorAdjustment(id: id)
    }

    func handleChatScrollMetrics(
        distanceToBottom: CGFloat,
        distanceToTop: CGFloat,
        isUserInteracting: Bool
    ) {
        scrollCoordinator.scrollDistanceToTop = max(distanceToTop, 0)
        updateChatScrollInteractionState(isUserInteracting)
        updateScrollToBottomVisibility(
            distanceToBottom: distanceToBottom,
            isUserInteracting: isUserInteracting
        )
        resolveActiveBottomScrollCommand(
            distanceToBottom: distanceToBottom
        )
        guard !hasExplicitChatNavigationCommand else {
            scrollCoordinator.pendingAutomaticHistoryLoadRequest = nil
            return
        }

        let firstMessageID = viewModel.displayMessages.first?.id
        let lastMessageID = viewModel.displayMessages.last?.id
        if !scrollCoordinator.isHistoryLoadInFlight,
           !viewModel.isHistoryFullyLoaded,
           Self.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: viewModel.usesAutomaticHistoryWindow,
            isUserInteracting: isUserInteracting,
            distanceToEdge: distanceToTop,
            triggerDistance: automaticHistoryLoadTriggerDistance,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: scrollCoordinator.lastAutomaticHistoryLoadAnchorID
           ), let firstMessageID {
            scrollCoordinator.pendingAutomaticHistoryLoadRequest = ChatAutomaticHistoryLoadRequest(
                direction: .earlier,
                anchorMessageID: firstMessageID
            )
        } else if !scrollCoordinator.isHistoryLoadInFlight,
                  !viewModel.isLaterHistoryFullyLoaded,
                  Self.shouldQueueAutomaticHistoryLoad(
                    usesAutomaticHistoryWindow: viewModel.usesAutomaticHistoryWindow,
                    isUserInteracting: isUserInteracting,
                    distanceToEdge: distanceToBottom,
                    triggerDistance: automaticHistoryLoadTriggerDistance,
                    anchorMessageID: lastMessageID,
                    lastLoadAnchorID: scrollCoordinator.lastAutomaticHistoryLoadAnchorID
                  ), let lastMessageID {
            scrollCoordinator.pendingAutomaticHistoryLoadRequest = ChatAutomaticHistoryLoadRequest(
                direction: .later,
                anchorMessageID: lastMessageID
            )
        }

        guard !isUserInteracting,
              !scrollCoordinator.isHistoryLoadInFlight,
              let request = scrollCoordinator.pendingAutomaticHistoryLoadRequest else {
            return
        }
        let remainsNearRequestedEdge = request.direction == .earlier
            ? distanceToTop < automaticHistoryLoadTriggerDistance
            : distanceToBottom < automaticHistoryLoadTriggerDistance
        scrollCoordinator.pendingAutomaticHistoryLoadRequest = nil
        guard remainsNearRequestedEdge else { return }
        performAutomaticHistoryLoad(request)
    }


    func cancelAutomaticHistoryNavigation() {
        scrollCoordinator.cancelAutomaticHistoryNavigation()
    }

    func cancelHistoryAnchorRestoration() {
        scrollCoordinator.cancelHistoryAnchorRestoration()
    }

}
