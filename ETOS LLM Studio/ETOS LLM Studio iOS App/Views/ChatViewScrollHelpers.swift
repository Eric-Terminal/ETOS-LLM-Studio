// ============================================================================
// ChatViewScrollHelpers.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的消息跳转、滚动到底部和消息时间线合并判断。
// ============================================================================

import SwiftUI
import UIKit
import Shared

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

    func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, nextMessage)
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
        setScrollTarget(bottomScrollTarget, anchor: .bottom, animated: animated, animation: animation)
    }

    func handleScrollToBottomButtonTap() {
        pendingHistoryResetWorkItem?.cancel()

        let shouldResetHistoryWindow = viewModel.lazyLoadMessageCount > 0
        showScrollToBottom = false
        scrollToBottom(animated: true, animation: scrollToBottomButtonAnimation)

        guard shouldResetHistoryWindow else {
            pendingHistoryResetWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                viewModel.resetLazyLoadState()
            }
            scrollToBottom(animated: false)
            pendingHistoryResetWorkItem = nil
        }
        pendingHistoryResetWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56, execute: workItem)
    }

    func scheduleImmediateBottomSnap() {
        pendingBottomSnapTask?.cancel()
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

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat) {
        let normalizedDistance = max(distanceToBottom, 0)
        DispatchQueue.main.async {
            scrollDistanceToBottom = normalizedDistance
            guard !viewModel.displayMessages.isEmpty else {
                if showScrollToBottom {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showScrollToBottom = false
                    }
                }
                return
            }
            let shouldShow = normalizedDistance > 48
            if showScrollToBottom != shouldShow {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottom = shouldShow
                }
            }
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
