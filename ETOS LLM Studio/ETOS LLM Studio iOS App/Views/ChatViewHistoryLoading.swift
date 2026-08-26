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
        guard viewModel.usesAutomaticHistoryWindow,
              !isHistoryLoadInFlight,
              lastAutomaticHistoryLoadAnchorID != request.anchorMessageID else {
            return
        }
        let displayedMessageIDs = viewModel.displayMessages.map(\.id)
        guard chatHistoryViewportAnchorController.beginMutation(
            anchorMessageID: request.anchorMessageID,
            displayedMessageIDs: displayedMessageIDs
        ) else {
            return
        }
        lastAutomaticHistoryLoadAnchorID = request.anchorMessageID
        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
        isHistoryLoadInFlight = true
        let didLoad: Bool
        switch request.direction {
        case .earlier:
            didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        case .later:
            didLoad = viewModel.loadMoreAutomaticLaterHistoryIfNeeded()
        }
        guard didLoad else {
            suppressAutoScrollOnce = false
            isHistoryLoadInFlight = false
            chatHistoryViewportAnchorController.cancel()
            return
        }
    }

    func performManualHistoryLoad() {
        guard viewModel.usesManualHistoryLoading,
              !isHistoryLoadInFlight,
              let anchorMessageID = viewModel.displayMessages.first?.id else {
            return
        }
        let displayedMessageIDs = viewModel.displayMessages.map(\.id)
        guard chatHistoryViewportAnchorController.beginMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: displayedMessageIDs
        ) else {
            return
        }

        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
        isHistoryLoadInFlight = true
        guard viewModel.loadMoreHistoryChunk() else {
            suppressAutoScrollOnce = false
            isHistoryLoadInFlight = false
            chatHistoryViewportAnchorController.cancel()
            return
        }
    }

    var pendingChatAnchorAdjustment: ChatScrollAnchorAdjustment? {
        chatHistoryViewportAnchorController.pendingAdjustment
            ?? chatLayoutIntegrityMonitor.pendingAnchorAdjustment
    }

    func completeChatAnchorAdjustment(id: UUID) {
        if chatHistoryViewportAnchorController.completeAdjustment(id: id) {
            isHistoryLoadInFlight = false
            return
        }
        chatLayoutIntegrityMonitor.completeAnchorAdjustment(id: id)
    }

    func handleChatScrollMetrics(
        distanceToBottom: CGFloat,
        distanceToTop: CGFloat,
        isUserInteracting: Bool
    ) {
        scrollDistanceToTop = max(distanceToTop, 0)
        updateChatScrollInteractionState(isUserInteracting)
        updateScrollToBottomVisibility(
            distanceToBottom: distanceToBottom,
            isUserInteracting: isUserInteracting
        )
        resolveActiveBottomScrollCommand(
            distanceToBottom: distanceToBottom
        )
        guard !hasExplicitChatNavigationCommand else {
            pendingAutomaticHistoryLoadRequest = nil
            return
        }

        let firstMessageID = viewModel.displayMessages.first?.id
        let lastMessageID = viewModel.displayMessages.last?.id
        if !isHistoryLoadInFlight,
           !viewModel.isHistoryFullyLoaded,
           Self.shouldQueueAutomaticHistoryLoad(
            usesAutomaticHistoryWindow: viewModel.usesAutomaticHistoryWindow,
            isUserInteracting: isUserInteracting,
            distanceToEdge: distanceToTop,
            triggerDistance: automaticHistoryLoadTriggerDistance,
            anchorMessageID: firstMessageID,
            lastLoadAnchorID: lastAutomaticHistoryLoadAnchorID
           ), let firstMessageID {
            pendingAutomaticHistoryLoadRequest = ChatAutomaticHistoryLoadRequest(
                direction: .earlier,
                anchorMessageID: firstMessageID
            )
        } else if !isHistoryLoadInFlight,
                  !viewModel.isLaterHistoryFullyLoaded,
                  Self.shouldQueueAutomaticHistoryLoad(
                    usesAutomaticHistoryWindow: viewModel.usesAutomaticHistoryWindow,
                    isUserInteracting: isUserInteracting,
                    distanceToEdge: distanceToBottom,
                    triggerDistance: automaticHistoryLoadTriggerDistance,
                    anchorMessageID: lastMessageID,
                    lastLoadAnchorID: lastAutomaticHistoryLoadAnchorID
                  ), let lastMessageID {
            pendingAutomaticHistoryLoadRequest = ChatAutomaticHistoryLoadRequest(
                direction: .later,
                anchorMessageID: lastMessageID
            )
        }

        guard !isUserInteracting,
              !isHistoryLoadInFlight,
              let request = pendingAutomaticHistoryLoadRequest else {
            return
        }
        let remainsNearRequestedEdge = request.direction == .earlier
            ? distanceToTop < automaticHistoryLoadTriggerDistance
            : distanceToBottom < automaticHistoryLoadTriggerDistance
        pendingAutomaticHistoryLoadRequest = nil
        guard remainsNearRequestedEdge else { return }
        performAutomaticHistoryLoad(request)
    }


    func cancelAutomaticHistoryNavigation() {
        cancelHistoryAnchorRestoration()
        pendingAutomaticHistoryLoadRequest = nil
        lastAutomaticHistoryLoadAnchorID = nil
    }

    func cancelHistoryAnchorRestoration() {
        isHistoryLoadInFlight = false
        chatHistoryViewportAnchorController.cancel()
    }

}
