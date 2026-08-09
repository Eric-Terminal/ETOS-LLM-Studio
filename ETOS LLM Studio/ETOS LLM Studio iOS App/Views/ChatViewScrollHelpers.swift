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
    /// 非流式尺寸变化交给 SwiftUI；流式期间由 UIKit 单独动画真实滚动偏移，避免双重吸底。
    nonisolated static func chatSizeChangeScrollAnchor(
        keepsBottomPinned: Bool,
        isStreaming: Bool
    ) -> UnitPoint? {
        keepsBottomPinned && !isStreaming ? .bottom : nil
    }

    /// 用户手势永远优先于自动吸底；非交互状态下只有真正回到底部才重新接管。
    nonisolated static func resolvedBottomPinIntent(
        currentIntent: Bool,
        distanceToBottom: CGFloat,
        threshold: CGFloat,
        isUserInteracting: Bool,
        isLayoutSettling: Bool
    ) -> Bool {
        if isUserInteracting {
            return false
        }
        if currentIntent {
            return true
        }
        return !isLayoutSettling && distanceToBottom < threshold
    }

    /// 相连气泡属于同一视觉组，不能被逐条滚动位移撕开连接处。
    nonisolated static func chatScrollTransitionOffset(
        phaseValue: CGFloat,
        configuredOffset: Double,
        isEnabled: Bool,
        isConnectedToAdjacentBubble: Bool,
        isBottomPinnedStreamingBubble: Bool = false
    ) -> CGFloat {
        guard isEnabled,
              !isConnectedToAdjacentBubble,
              !isBottomPinnedStreamingBubble else {
            return 0
        }
        return phaseValue * CGFloat(configuredOffset)
    }

    /// 消息版本切换可能让当前滚动目标退出可见集合，必须先释放失效目标。
    nonisolated static func retainedChatScrollTarget(
        _ target: ChatScrollTargetID?,
        visibleMessageIDs: Set<UUID>
    ) -> ChatScrollTargetID? {
        guard let target else { return nil }
        guard case .message(let messageID) = target else { return target }
        return visibleMessageIDs.contains(messageID) ? target : nil
    }

    nonisolated static func isChatScrollTargetAvailable(
        _ target: ChatScrollTargetID,
        visibleMessageIDs: Set<UUID>
    ) -> Bool {
        switch target {
        case .bottom:
            return true
        case .message(let messageID):
            return visibleMessageIDs.contains(messageID)
        }
    }

    /// 完整消息栈不能再用 View 生命周期判断是否抵达顶部，只响应真实滚动手势。
    nonisolated static func shouldLoadAutomaticHistory(
        usesAutomaticHistoryWindow: Bool,
        isUserInteracting: Bool,
        distanceToTop: CGFloat,
        triggerDistance: CGFloat,
        firstMessageID: UUID?,
        lastLoadAnchorID: UUID?
    ) -> Bool {
        guard usesAutomaticHistoryWindow,
              isUserInteracting,
              distanceToTop < triggerDistance,
              let firstMessageID else {
            return false
        }
        return firstMessageID != lastLoadAnchorID
    }

    nonisolated static func shouldReleaseAutomaticHistoryLoad(
        isLoadInFlight: Bool,
        awaitsAnchorMetrics: Bool,
        distanceToTop: CGFloat,
        triggerDistance: CGFloat
    ) -> Bool {
        isLoadInFlight
            && awaitsAnchorMetrics
            && distanceToTop >= triggerDistance
    }

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

        scheduleMessageJump(to: targetMessageID)
        return true
    }

    func prepareForMessageJump() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        cancelPendingScrollTargetCommand()
        pendingJumpRequest = nil
        needsImmediateBottomSnap = false
        shouldRestorePendingJumpOnAppear = true
        #if DEBUG
        NSLog("[BottomPinTrace] release source=message-jump")
        #endif
        shouldKeepBottomPinned = false
    }

    func handleDisplayedMessageIdentityChange() {
        let visibleMessageIDs = Set(viewModel.displayMessages.map(\.id))
        let retainedTarget = Self.retainedChatScrollTarget(
            chatScrollTarget,
            visibleMessageIDs: visibleMessageIDs
        )
        if retainedTarget != chatScrollTarget {
            chatScrollTarget = retainedTarget
        }

        guard !viewModel.displayMessages.isEmpty else {
            shouldKeepBottomPinned = true
            showScrollToBottom = false
            resolvePendingSearchJumpIfNeeded()
            return
        }

        if needsImmediateBottomSnap {
            scheduleImmediateBottomSnap()
            resolvePendingSearchJumpIfNeeded()
            return
        }
        if suppressAutoScrollOnce {
            suppressAutoScrollOnce = false
            resolvePendingSearchJumpIfNeeded()
            return
        }
        if shouldKeepBottomPinned || scrollDistanceToBottom < bottomPinnedDistanceThreshold {
            scrollToBottom()
        }
        resolvePendingSearchJumpIfNeeded()
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
        return message.role == .user
            && nextMessage.role == .user
            && message.authorKind == nextMessage.authorKind
            && message.sourceSessionID == nextMessage.sourceSessionID
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
        setScrollTarget(
            bottomScrollTarget,
            anchor: .bottom,
            animated: animated,
            animation: animation,
            releasesAtBottom: true
        )
    }

    func handleScrollToBottomButtonTap() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        shouldRestorePendingJumpOnAppear = false
        lastAutomaticHistoryLoadAnchorID = nil

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

    func loadMoreAutomaticHistoryIfNeeded(anchorMessageID: UUID) {
        guard viewModel.usesAutomaticHistoryWindow,
              !isAutomaticHistoryLoadInFlight,
              lastAutomaticHistoryLoadAnchorID != anchorMessageID else {
            return
        }
        lastAutomaticHistoryLoadAnchorID = anchorMessageID
        suppressAutoScrollOnce = true
        #if DEBUG
        NSLog("[BottomPinTrace] release source=automatic-history")
        #endif
        shouldKeepBottomPinned = false
        isAutomaticHistoryLoadInFlight = true
        awaitsAutomaticHistoryAnchorMetrics = false
        let didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        guard didLoad else {
            suppressAutoScrollOnce = false
            isAutomaticHistoryLoadInFlight = false
            return
        }
        scheduleAutomaticHistoryAnchorRestore(anchorMessageID)
    }

    func handleChatScrollMetrics(
        distanceToBottom: CGFloat,
        distanceToTop: CGFloat,
        isUserInteracting: Bool
    ) {
        updateScrollToBottomVisibility(
            distanceToBottom: distanceToBottom,
            isUserInteracting: isUserInteracting
        )
        resolveActiveBottomScrollCommand(
            distanceToBottom: distanceToBottom,
            isUserInteracting: isUserInteracting
        )
        // 只有底层滚动视图确认已经离开顶部，才算旧首条消息真正完成锚定。
        if Self.shouldReleaseAutomaticHistoryLoad(
            isLoadInFlight: isAutomaticHistoryLoadInFlight,
            awaitsAnchorMetrics: awaitsAutomaticHistoryAnchorMetrics,
            distanceToTop: distanceToTop,
            triggerDistance: automaticHistoryLoadTriggerDistance
        ) {
            isAutomaticHistoryLoadInFlight = false
            awaitsAutomaticHistoryAnchorMetrics = false
        }
        let firstMessageID = viewModel.displayMessages.first?.id
        guard !isAutomaticHistoryLoadInFlight,
              Self.shouldLoadAutomaticHistory(
            usesAutomaticHistoryWindow: viewModel.usesAutomaticHistoryWindow,
            isUserInteracting: isUserInteracting,
            distanceToTop: distanceToTop,
            triggerDistance: automaticHistoryLoadTriggerDistance,
            firstMessageID: firstMessageID,
            lastLoadAnchorID: lastAutomaticHistoryLoadAnchorID
        ), let firstMessageID else {
            return
        }
        loadMoreAutomaticHistoryIfNeeded(anchorMessageID: firstMessageID)
    }

    func scheduleImmediateBottomSnap() {
        pendingBottomSnapTask?.cancel()
        shouldKeepBottomPinned = true
        guard !viewModel.displayMessages.isEmpty else {
            needsImmediateBottomSnap = true
            pendingBottomSnapTask = nil
            return
        }
        pendingBottomSnapTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToBottom(animated: false)
            needsImmediateBottomSnap = false
            pendingBottomSnapTask = nil
        }
    }

    func scheduleDeferredBottomSnap() {
        pendingBottomSnapTask?.cancel()
        shouldKeepBottomPinned = true
        pendingBottomSnapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            scrollToBottom(animated: false)
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

    func restorePendingMessageJumpIfNeeded() {
        guard let request = pendingJumpRequest else { return }
        setScrollTarget(
            .message(request.messageID),
            anchor: .center,
            animated: true,
            animation: .easeInOut(duration: 0.25),
            deferred: true
        )
    }

    var bottomScrollTarget: ChatScrollTargetID {
        if let lastMessageID = viewModel.displayMessages.last?.id {
            return .message(lastMessageID)
        }
        return .bottom
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat, isUserInteracting: Bool) {
        let normalizedDistance = max(distanceToBottom, 0)
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
        let resolvedBottomPinIntent = Self.resolvedBottomPinIntent(
            currentIntent: shouldKeepBottomPinned,
            distanceToBottom: normalizedDistance,
            threshold: bottomPinnedDistanceThreshold,
            isUserInteracting: isUserInteracting,
            isLayoutSettling: isChatLayoutSettling
        )
        #if DEBUG
        if resolvedBottomPinIntent != shouldKeepBottomPinned {
            NSLog(
                "[BottomPinTrace] pin=%d->%d source=metrics distance=%.1f user=%d settling=%d streaming=%d",
                shouldKeepBottomPinned ? 1 : 0,
                resolvedBottomPinIntent ? 1 : 0,
                normalizedDistance,
                isUserInteracting ? 1 : 0,
                isChatLayoutSettling ? 1 : 0,
                viewModel.isSendingMessage ? 1 : 0
            )
        }
        #endif
        shouldKeepBottomPinned = resolvedBottomPinIntent

        let shouldShow = normalizedDistance > scrollToBottomButtonRevealDistance && !shouldKeepBottomPinned
        if showScrollToBottom != shouldShow {
            withAnimation(.easeInOut(duration: 0.18)) {
                showScrollToBottom = shouldShow
            }
        }
        if !isChatLayoutSettling,
           normalizedDistance < bottomPinnedDistanceThreshold,
           viewModel.resetAutomaticHistoryWindowIfNeeded() {
            lastAutomaticHistoryLoadAnchorID = nil
            scheduleDeferredBottomSnap()
        }
    }

    /// scrollPosition 只承担一次性跳转；抵达底部或用户接管后立即释放绑定，
    /// 后续流式增长统一交给尺寸变化锚点，避免两个目标长期互相校正。
    func resolveActiveBottomScrollCommand(
        distanceToBottom: CGFloat,
        isUserInteracting: Bool
    ) {
        guard activeBottomScrollCommandTarget != nil else { return }
        guard isUserInteracting || distanceToBottom <= bottomScrollCommandArrivalTolerance else { return }
        releaseActiveBottomScrollCommand()
    }

    func releaseActiveBottomScrollCommand() {
        guard let target = activeBottomScrollCommandTarget else { return }
        activeBottomScrollCommandTarget = nil
        guard chatScrollTarget == target else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chatScrollTarget = nil
        }
    }

    func handleContinuationExpansionStateChange(_ state: ConversationContinuationExpansionState) {
        guard state.isExpanded else { return }
        // 主动展开会改变滚动内容高度，不应继续把当前位置视为“锁定底部”。
        #if DEBUG
        NSLog("[BottomPinTrace] release source=continuation-expansion")
        #endif
        shouldKeepBottomPinned = false
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
            // 等待期间用户可能已经拖动列表；此时不能用旧的贴底意图把阅读位置抢回来。
            if keepBottomPinned, shouldKeepBottomPinned {
                scrollToBottom(animated: false)
            }
            chatLayoutSettleTask = nil
        }
    }

    func cancelPendingScrollTargetCommand() {
        scrollTargetGeneration &+= 1
        pendingScrollTargetTask?.cancel()
        pendingScrollTargetTask = nil
        releaseActiveBottomScrollCommand()
        isAutomaticHistoryLoadInFlight = false
        awaitsAutomaticHistoryAnchorMetrics = false
    }

    private func scheduleAutomaticHistoryAnchorRestore(_ messageID: UUID) {
        cancelPendingScrollTargetCommand()
        isAutomaticHistoryLoadInFlight = true
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        let target = ChatScrollTargetID.message(messageID)
        pendingScrollTargetTask = Task { @MainActor in
            var didApplyTarget = false
            defer {
                if generation == scrollTargetGeneration {
                    pendingScrollTargetTask = nil
                    if !didApplyTarget {
                        isAutomaticHistoryLoadInFlight = false
                        awaitsAutomaticHistoryAnchorMetrics = false
                    }
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else {
                return
            }
            applyScrollTarget(
                target,
                anchor: .top,
                animated: false,
                animation: .linear(duration: 0)
            )
            didApplyTarget = true
            awaitsAutomaticHistoryAnchorMetrics = true
        }
    }

    private func scheduleMessageJump(to messageID: UUID) {
        cancelPendingScrollTargetCommand()
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        pendingScrollTargetTask = Task { @MainActor in
            defer {
                if generation == scrollTargetGeneration {
                    pendingScrollTargetTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  generation == scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id,
                  viewModel.displayMessages.contains(where: { $0.id == messageID }) else {
                return
            }
            pendingJumpRequest = MessageJumpRequest(messageID: messageID)
        }
    }

    private func canApplyScrollTarget(
        _ target: ChatScrollTargetID,
        generation: UInt,
        sessionID: UUID?
    ) -> Bool {
        guard generation == scrollTargetGeneration,
              sessionID == viewModel.currentSession?.id else {
            return false
        }
        return Self.isChatScrollTargetAvailable(
            target,
            visibleMessageIDs: Set(viewModel.displayMessages.map(\.id))
        )
    }

    private func applyScrollTarget(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint,
        animated: Bool,
        animation: Animation
    ) {
        let updateTarget = {
            chatScrollTargetAnchor = anchor
            chatScrollTarget = target
        }
        if animated {
            withAnimation(animation, updateTarget)
        } else {
            updateTarget()
        }
    }

    private func setScrollTarget(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint,
        animated: Bool,
        animation: Animation,
        deferred: Bool = false,
        releasesAtBottom: Bool = false
    ) {
        let shouldDefer = deferred || chatScrollTarget == target
        cancelPendingScrollTargetCommand()
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id

        guard shouldDefer else {
            guard canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else { return }
            if releasesAtBottom {
                activeBottomScrollCommandTarget = target
            }
            applyScrollTarget(target, anchor: anchor, animated: animated, animation: animation)
            return
        }

        if chatScrollTarget == target {
            chatScrollTarget = nil
        }
        pendingScrollTargetTask = Task { @MainActor in
            defer {
                if generation == scrollTargetGeneration {
                    pendingScrollTargetTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else {
                return
            }
            if releasesAtBottom {
                activeBottomScrollCommandTarget = target
            }
            applyScrollTarget(target, anchor: anchor, animated: animated, animation: animation)
        }
    }
}
