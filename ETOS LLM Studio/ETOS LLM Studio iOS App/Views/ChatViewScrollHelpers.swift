// ============================================================================
// ChatViewScrollHelpers.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的消息跳转、滚动到底部和消息时间线合并判断。
// ============================================================================

import SwiftUI
import UIKit
import ETOSCore

extension ChatView {
    func resolvePendingSearchJumpIfNeeded() {
        guard let target = viewModel.pendingSearchJumpTarget,
              viewModel.currentSession?.id == target.sessionID,
              !viewModel.allMessagesForSession.isEmpty else {
            return
        }
        guard jumpToMessage(displayIndex: target.messageOrdinal) else { return }
        viewModel.clearPendingMessageJumpTarget()
    }

    func jumpToMessage(displayIndex: Int) -> Bool {
        let targetZeroBasedIndex = displayIndex - 1
        guard targetZeroBasedIndex >= 0, targetZeroBasedIndex < viewModel.allMessagesForSession.count else {
            return false
        }

        prepareForMessageJump()

        let targetMessageID = viewModel.allMessagesForSession[targetZeroBasedIndex].id
        let isVisible = viewModel.displayMessages.contains(where: { $0.id == targetMessageID })
        if !isVisible {
            viewModel.loadEntireHistory()
        }

        DispatchQueue.main.async {
            pendingJumpRequest = MessageJumpRequest(messageID: targetMessageID)
        }
        return true
    }

    func prepareForMessageJump() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        needsImmediateBottomSnap = false
        shouldRestorePendingJumpOnAppear = true
        shouldKeepBottomPinned = false
    }

    func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, nextMessage)
    }

    func shouldContinueMessageActionBar(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        if shouldMergeTurnMessages(message, with: nextMessage) {
            return true
        }
        return message.role == .user && nextMessage.role == .user
    }

    func shouldConnectTimeline(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard shouldMergeTurnMessages(message, with: nextMessage) else { return false }
        return hasTimelineLineContent(message) && hasTimelineLineContent(nextMessage)
    }

    func hasTimelineLineContent(_ message: ChatMessage?) -> Bool {
        guard let message, isAssistantTurnMessage(message) else { return false }
        let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasNonWidgetToolCall = (message.toolCalls ?? []).contains { call in
            call.toolName != AppToolKind.showWidget.toolName
        }
        return hasReasoning || hasNonWidgetToolCall
    }

    func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        @unknown default:
            return false
        }
    }

    func scrollToBottom(
        animated: Bool = true,
        animation: Animation = .easeOut(duration: 0.25)
    ) {
        shouldKeepBottomPinned = true
        setScrollTarget(bottomScrollTarget, anchor: .bottom, animated: animated, animation: animation)
    }

    func handleScrollToBottomButtonTap() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        shouldRestorePendingJumpOnAppear = false

        let shouldResetHistoryWindow = viewModel.usesManualHistoryLoading || viewModel.usesAutomaticHistoryWindow
        shouldKeepBottomPinned = true
        showScrollToBottom = false

        guard shouldResetHistoryWindow else {
            scrollToBottom(animated: true, animation: scrollToBottomButtonAnimation)
            return
        }

        let workItem = DispatchWorkItem {
            pendingBottomSnapTask?.cancel()
            pendingBottomSnapTask = nil
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

    func loadMoreAutomaticHistoryIfNeeded(
        anchorMessageID: UUID,
        isFirstDisplayedMessage: Bool
    ) {
        guard isFirstDisplayedMessage, viewModel.usesAutomaticHistoryWindow else { return }
        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
        let didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        guard didLoad else { return }
        DispatchQueue.main.async {
            setScrollTarget(.message(anchorMessageID), anchor: .top, animated: false, animation: .linear(duration: 0))
        }
    }

    func scheduleImmediateBottomSnap() {
        pendingBottomSnapTask?.cancel()
        shouldKeepBottomPinned = true
        pendingBottomSnapTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                scrollToBottom(animated: false)
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            needsImmediateBottomSnap = false
            pendingBottomSnapTask = nil
        }
    }

    func scheduleDeferredBottomSnap() {
        pendingBottomSnapTask?.cancel()
        shouldKeepBottomPinned = true
        pendingBottomSnapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                scrollToBottom(animated: false)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            guard !Task.isCancelled else { return }
            pendingBottomSnapTask = nil
        }
    }

    func scrollToMessage(
        _ messageID: UUID,
        animated: Bool = true,
        animation: Animation = .easeInOut(duration: 0.25)
    ) {
        setScrollTarget(.message(messageID), anchor: .center, animated: animated, animation: animation)
    }

    var bottomScrollTarget: ChatScrollTargetID {
        if let lastMessageID = viewModel.displayMessages.last?.id {
            return .message(lastMessageID)
        }
        return .bottom
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat, isUserInteracting: Bool) {
        let normalizedDistance = max(distanceToBottom, 0)
        DispatchQueue.main.async {
            scrollDistanceToBottom = normalizedDistance
            guard !viewModel.displayMessages.isEmpty else {
                shouldKeepBottomPinned = true
                if showScrollToBottom {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showScrollToBottom = false
                    }
                }
                return
            }
            if normalizedDistance < bottomPinnedDistanceThreshold {
                shouldKeepBottomPinned = true
            } else if isUserInteracting, !isChatLayoutSettling {
                shouldKeepBottomPinned = false
            }

            let shouldShow = normalizedDistance > scrollToBottomButtonRevealDistance && !shouldKeepBottomPinned
            if showScrollToBottom != shouldShow {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottom = shouldShow
                }
            }
            if !isChatLayoutSettling,
               normalizedDistance < 24,
               viewModel.resetAutomaticHistoryWindowIfNeeded() {
                scheduleDeferredBottomSnap()
            }
        }
    }

    func handleChatInputBarHeightChange(_ newHeight: CGFloat) {
        let heightDelta = abs(newHeight - chatInputBarHeight)
        guard heightDelta > 0.5 else {
            chatInputBarHeight = newHeight
            return
        }

        let keepBottomPinned = shouldKeepBottomPinned || scrollDistanceToBottom < bottomPinnedDistanceThreshold
        chatInputBarHeight = newHeight
        beginChatLayoutSettling(keepBottomPinned: keepBottomPinned)
    }

    func beginChatLayoutSettling(keepBottomPinned: Bool) {
        chatLayoutSettleTask?.cancel()
        isChatLayoutSettling = true

        if keepBottomPinned {
            shouldKeepBottomPinned = true
            scrollToBottom(animated: false)
        }

        chatLayoutSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isChatLayoutSettling = false
            if keepBottomPinned {
                scrollToBottom(animated: false)
            }
            chatLayoutSettleTask = nil
        }
    }

    private func setScrollTarget(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint,
        animated: Bool,
        animation: Animation
    ) {
        let updateTarget = {
            chatScrollTargetAnchor = anchor
            chatScrollTarget = target
        }

        guard chatScrollTarget == target else {
            if animated {
                withAnimation(animation, updateTarget)
            } else {
                updateTarget()
            }
            return
        }

        chatScrollTarget = nil
        DispatchQueue.main.async {
            if animated {
                withAnimation(animation, updateTarget)
            } else {
                updateTarget()
            }
        }
    }
}
