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
    var hasChatProgrammaticScrollOwnership: Bool {
        isMessageJumpInFlight
            || pendingHistoryResetWorkItem != nil
            || pendingBottomSnapTask != nil
            || pendingScrollTargetTask != nil
            || chatScrollTarget != nil
            || activeBottomScrollCommandTarget != nil
    }

    var hasExplicitChatNavigationCommand: Bool {
        Self.shouldSuspendAutomaticHistoryNavigation(
            isMessageJumpInFlight: isMessageJumpInFlight,
            hasPendingHistoryReset: pendingHistoryResetWorkItem != nil,
            hasPendingBottomSnap: pendingBottomSnapTask != nil,
            hasActiveBottomTarget: activeBottomScrollCommandTarget != nil,
            hasPendingOrAppliedTarget: pendingScrollTargetTask != nil || chatScrollTarget != nil,
            isAutomaticHistoryLoadInFlight: isAutomaticHistoryLoadInFlight
        )
    }

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
        isBottomPinnedStreamingBubble: Bool = false,
        isViewportTransitioning: Bool = false
    ) -> CGFloat {
        guard isEnabled,
              !isConnectedToAdjacentBubble,
              !isBottomPinnedStreamingBubble,
              !isViewportTransitioning else {
            return 0
        }
        return phaseValue * CGFloat(configuredOffset)
    }

    /// 只有贴底内容随视口变化时才暂停气泡波浪，历史阅读与用户手势始终保留直接反馈。
    nonisolated static func shouldSuppressScrollTransitionForViewportChange(
        isLayoutSettling: Bool,
        keepsBottomPinned: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        isLayoutSettling && keepsBottomPinned && !isUserInteracting
    }

    nonisolated static func shouldReleaseActiveBottomScrollCommand(
        hasActiveTarget: Bool,
        distanceToBottom: CGFloat,
        arrivalTolerance: CGFloat,
        hasExceededMaximumLifetime: Bool = false
    ) -> Bool {
        hasActiveTarget
            && (distanceToBottom <= arrivalTolerance || hasExceededMaximumLifetime)
    }

    nonisolated static func shouldCancelProgrammaticScrollOnPanBegan(
        hasPendingHistoryReset: Bool,
        hasPendingBottomSnap: Bool,
        hasPendingTargetTask: Bool,
        hasScrollTarget: Bool,
        hasActiveBottomTarget: Bool,
        isMessageJumpInFlight: Bool
    ) -> Bool {
        hasPendingHistoryReset
            || hasPendingBottomSnap
            || hasPendingTargetTask
            || hasScrollTarget
            || hasActiveBottomTarget
            || isMessageJumpInFlight
    }

    nonisolated static func shouldSuspendAutomaticHistoryNavigation(
        isMessageJumpInFlight: Bool,
        hasPendingHistoryReset: Bool,
        hasPendingBottomSnap: Bool,
        hasActiveBottomTarget: Bool,
        hasPendingOrAppliedTarget: Bool,
        isAutomaticHistoryLoadInFlight: Bool
    ) -> Bool {
        isMessageJumpInFlight
            || hasPendingHistoryReset
            || hasPendingBottomSnap
            || hasActiveBottomTarget
            || (hasPendingOrAppliedTarget && !isAutomaticHistoryLoadInFlight)
    }

    /// 最后一条消息之后仍可能存在续聊链接与尾部留白，吸底必须定位消息栈的真实末端。
    static var resolvedBottomScrollTarget: ChatScrollTargetID {
        .bottom
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
        case .top, .bottom:
            return true
        case .message(let messageID):
            return visibleMessageIDs.contains(messageID)
        }
    }

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

    nonisolated static func shouldReleaseAutomaticHistoryLoad(
        isLoadInFlight: Bool,
        awaitsAnchorMetrics: Bool,
        distanceToEdge: CGFloat,
        triggerDistance: CGFloat
    ) -> Bool {
        isLoadInFlight
            && awaitsAnchorMetrics
            && distanceToEdge >= triggerDistance
    }

    nonisolated static func isPendingMessageJumpReady(
        targetSessionID: UUID,
        currentSessionID: UUID?,
        loadedHistorySessionID: UUID?,
        hasMessages: Bool,
        isChatVisible: Bool,
        awaitsPickerDismissal: Bool
    ) -> Bool {
        currentSessionID == targetSessionID
            && loadedHistorySessionID == targetSessionID
            && hasMessages
            && isChatVisible
            && !awaitsPickerDismissal
    }

    func resolvePendingSearchJumpIfNeeded() {
        guard let target = viewModel.pendingSearchJumpTarget,
              Self.isPendingMessageJumpReady(
                targetSessionID: target.sessionID,
                currentSessionID: viewModel.currentSession?.id,
                loadedHistorySessionID: viewModel.historyWindowSessionID,
                hasMessages: !viewModel.allMessagesForSession.isEmpty,
                isChatVisible: isChatVisible,
                awaitsPickerDismissal: awaitsChatPickerDismissalForMessageJump
              ) else {
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

        guard let targetMessageID = ChatJumpTargetSupport.messageID(
            at: targetZeroBasedIndex,
            in: viewModel.allMessagesForSession,
            hiddenToolCallResultIDs: viewModel.toolCallResultIDs
        ) else {
            return false
        }

        prepareForMessageJump()
        guard viewModel.historyWindowPosition(of: targetMessageID) != nil else {
            isMessageJumpInFlight = false
            return false
        }

        scheduleMessageJump(to: targetMessageID)
        return true
    }

    func queueMessageActionJumpAfterDismiss(displayIndex: Int) -> Bool {
        let targetZeroBasedIndex = displayIndex - 1
        guard targetZeroBasedIndex >= 0,
              targetZeroBasedIndex < viewModel.allMessagesForSession.count,
              ChatJumpTargetSupport.messageID(
                at: targetZeroBasedIndex,
                in: viewModel.allMessagesForSession,
                hiddenToolCallResultIDs: viewModel.toolCallResultIDs
              ) != nil else {
            return false
        }
        pendingMessageActionJumpIndex = displayIndex
        return true
    }

    func performPendingMessageActionJumpIfNeeded() {
        guard let displayIndex = pendingMessageActionJumpIndex else { return }
        pendingMessageActionJumpIndex = nil
        _ = jumpToMessage(displayIndex: displayIndex)
    }

    func prepareForMessageJump() {
        awaitsFreshBottomNavigationSnapshot = false
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        cancelPendingScrollTargetCommand()
        messageNavigationCursorID = nil
        pendingJumpRequest = nil
        isMessageJumpInFlight = true
        needsImmediateBottomSnap = false
        shouldRestorePendingJumpOnAppear = true
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

        if isMessageJumpInFlight {
            resolvePendingSearchJumpIfNeeded()
            return
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

    func performAutomaticHistoryLoad(_ request: ChatAutomaticHistoryLoadRequest) {
        guard viewModel.usesAutomaticHistoryWindow,
              !isAutomaticHistoryLoadInFlight,
              lastAutomaticHistoryLoadAnchorID != request.anchorMessageID else {
            return
        }
        lastAutomaticHistoryLoadAnchorID = request.anchorMessageID
        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
        isAutomaticHistoryLoadInFlight = true
        awaitsAutomaticHistoryAnchorMetrics = false
        automaticHistoryLoadDirection = request.direction
        let didLoad: Bool
        switch request.direction {
        case .earlier:
            didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        case .later:
            didLoad = viewModel.loadMoreAutomaticLaterHistoryIfNeeded()
        }
        guard didLoad else {
            suppressAutoScrollOnce = false
            isAutomaticHistoryLoadInFlight = false
            automaticHistoryLoadDirection = nil
            return
        }
        scheduleAutomaticHistoryAnchorRestore(
            request.anchorMessageID,
            anchor: request.direction == .earlier ? .top : .bottom
        )
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
        let activeEdgeDistance = automaticHistoryLoadDirection == .later
            ? distanceToBottom
            : distanceToTop
        // 只有底层滚动视图确认旧边界消息已经进入新窗口内部，才释放窗口切换状态。
        if Self.shouldReleaseAutomaticHistoryLoad(
            isLoadInFlight: isAutomaticHistoryLoadInFlight,
            awaitsAnchorMetrics: awaitsAutomaticHistoryAnchorMetrics,
            distanceToEdge: activeEdgeDistance,
            triggerDistance: automaticHistoryLoadTriggerDistance
        ) {
            isAutomaticHistoryLoadInFlight = false
            awaitsAutomaticHistoryAnchorMetrics = false
            automaticHistoryLoadDirection = nil
        }

        guard !hasExplicitChatNavigationCommand else {
            pendingAutomaticHistoryLoadRequest = nil
            return
        }

        let firstMessageID = viewModel.displayMessages.first?.id
        let lastMessageID = viewModel.displayMessages.last?.id
        if !isAutomaticHistoryLoadInFlight,
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
        } else if !isAutomaticHistoryLoadInFlight,
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
              !isAutomaticHistoryLoadInFlight,
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

    func restorePendingMessageJumpIfNeeded() {
        guard pendingScrollTargetTask == nil, let request = pendingJumpRequest else { return }
        scheduleMessageJump(to: request.messageID)
    }

    var bottomScrollTarget: ChatScrollTargetID {
        Self.resolvedBottomScrollTarget
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat, isUserInteracting: Bool) {
        let normalizedDistance = max(distanceToBottom, 0)
        scrollDistanceToBottom = normalizedDistance
        guard !viewModel.displayMessages.isEmpty else {
            shouldKeepBottomPinned = true
            hideScrollNavigationPanel()
            if showScrollToBottom {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottom = false
                }
            }
            return
        }
        shouldKeepBottomPinned = Self.resolvedBottomPinIntent(
            currentIntent: shouldKeepBottomPinned,
            distanceToBottom: normalizedDistance,
            threshold: bottomPinnedDistanceThreshold,
            isUserInteracting: isUserInteracting,
            isLayoutSettling: isChatLayoutSettling
        )

        let shouldShow = normalizedDistance > scrollToBottomButtonRevealDistance && !shouldKeepBottomPinned
        if showScrollToBottom != shouldShow {
            withAnimation(.easeInOut(duration: 0.18)) {
                showScrollToBottom = shouldShow
            }
        }
    }

    /// scrollPosition 只承担一次性跳转；抵达底部或用户接管后立即释放绑定，
    /// 后续流式增长统一交给尺寸变化锚点，避免两个目标长期互相校正。
    func resolveActiveBottomScrollCommand(distanceToBottom: CGFloat) {
        guard Self.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: activeBottomScrollCommandTarget != nil,
            distanceToBottom: distanceToBottom,
            arrivalTolerance: bottomScrollCommandArrivalTolerance
        ) else { return }
        releaseActiveBottomScrollCommand()
    }

    func releaseActiveBottomScrollCommand() {
        bottomScrollCommandReleaseTask?.cancel()
        bottomScrollCommandReleaseTask = nil
        guard let target = activeBottomScrollCommandTarget else { return }
        activeBottomScrollCommandTarget = nil
        if chatScrollTarget == target {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                chatScrollTarget = nil
            }
        }
        if awaitsFreshBottomNavigationSnapshot {
            bottomNavigationSnapshotBaselineRevision =
                chatLayoutIntegrityMonitor.requestFreshNavigationSnapshot()
            refreshMessageNavigationTargets()
        }
    }

    /// 首次打开长消息时 Markdown 可能分多轮完成布局，滚动目标不能在这期间持续拉扯视口。
    /// 到期后由尺寸变化锚点继续保持底部；真实抵达或用户手势仍会提前释放命令。
    private func scheduleBottomScrollCommandRelease(
        target: ChatScrollTargetID,
        generation: UInt,
        sessionID: UUID?,
        animated: Bool
    ) {
        bottomScrollCommandReleaseTask?.cancel()
        let maximumLifetimeNanoseconds: UInt64 = animated ? 900_000_000 : 160_000_000
        bottomScrollCommandReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: maximumLifetimeNanoseconds)
            guard !Task.isCancelled,
                  generation == scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id,
                  activeBottomScrollCommandTarget == target,
                  Self.shouldReleaseActiveBottomScrollCommand(
                    hasActiveTarget: true,
                    distanceToBottom: scrollDistanceToBottom,
                    arrivalTolerance: bottomScrollCommandArrivalTolerance,
                    hasExceededMaximumLifetime: true
                  ) else {
                return
            }
            releaseActiveBottomScrollCommand()
        }
    }

    func handleContinuationExpansionStateChange(_ state: ConversationContinuationExpansionState) {
        guard state.isExpanded else { return }
        // 主动展开会改变滚动内容高度，不应继续把当前位置视为“锁定底部”。
        shouldKeepBottomPinned = false
    }

    func handleChatInputBarHeightChange(_ newHeight: CGFloat) {
        let heightDelta = abs(newHeight - chatInputBarHeight)
        guard heightDelta > 0.5 else {
            chatInputBarHeight = newHeight
            return
        }

        let keepBottomPinned = resolvedBottomPinIntentForViewportChange()
        chatInputBarHeight = newHeight
        beginChatLayoutSettling(keepBottomPinned: keepBottomPinned)
    }

    func resolvedBottomPinIntentForViewportChange() -> Bool {
        Self.resolvedBottomPinIntent(
            currentIntent: shouldKeepBottomPinned,
            distanceToBottom: scrollDistanceToBottom,
            threshold: bottomPinnedDistanceThreshold,
            isUserInteracting: isChatScrollUserInteracting,
            isLayoutSettling: isChatLayoutSettling
        )
    }

    func beginChatLayoutSettling(keepBottomPinned: Bool) {
        chatLayoutSettleTask?.cancel()
        isChatLayoutSettling = true
        shouldKeepBottomPinned = keepBottomPinned

        chatLayoutSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isChatLayoutSettling = false
            chatLayoutSettleTask = nil
        }
    }

    func cancelPendingScrollTargetCommand(preservingMessageJump: Bool = false) {
        scrollTargetGeneration &+= 1
        pendingScrollTargetTask?.cancel()
        pendingScrollTargetTask = nil
        releaseActiveBottomScrollCommand()
        if chatScrollTarget != nil {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                chatScrollTarget = nil
            }
        }
        if !preservingMessageJump {
            pendingJumpRequest = nil
            isMessageJumpInFlight = false
            shouldRestorePendingJumpOnAppear = false
        }
        isAutomaticHistoryLoadInFlight = false
        awaitsAutomaticHistoryAnchorMetrics = false
        automaticHistoryLoadDirection = nil
        pendingAutomaticHistoryLoadRequest = nil
    }

    func cancelAutomaticHistoryNavigation() {
        if isAutomaticHistoryLoadInFlight || automaticHistoryLoadDirection != nil {
            cancelPendingScrollTargetCommand()
        } else {
            awaitsAutomaticHistoryAnchorMetrics = false
            pendingAutomaticHistoryLoadRequest = nil
        }
        lastAutomaticHistoryLoadAnchorID = nil
    }

    private func scheduleAutomaticHistoryAnchorRestore(_ messageID: UUID, anchor: UnitPoint) {
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
                anchor: anchor,
                animated: false,
                animation: .linear(duration: 0)
            )
            didApplyTarget = true
            awaitsAutomaticHistoryAnchorMetrics = true
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled,
                  generation == scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id else {
                return
            }
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if chatScrollTarget == target {
                    chatScrollTarget = nil
                }
            }
            isAutomaticHistoryLoadInFlight = false
            awaitsAutomaticHistoryAnchorMetrics = false
            automaticHistoryLoadDirection = nil
        }
    }

    func scheduleMessageJump(
        to messageID: UUID,
        usesAdjacentAnimation: Bool = false
    ) {
        cancelPendingScrollTargetCommand()
        isMessageJumpInFlight = true
        shouldRestorePendingJumpOnAppear = true
        let request = MessageJumpRequest(messageID: messageID)
        pendingJumpRequest = request
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        let initialDistance = viewModel.historyWindowDistance(to: messageID) ?? 0
        let estimatedSegmentCount = max(
            1,
            (initialDistance + historyJumpBatchSize - 1) / historyJumpBatchSize
        )

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

            // 先让选择器关闭与跳转状态进入当前事务，下一轮再开始移动列表。
            await Task.yield()
            var completedSegmentCount = 0

            while !Task.isCancelled,
                  generation == scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id,
                  pendingJumpRequest == request,
                  let position = viewModel.historyWindowPosition(of: messageID) {
                if position == .visible {
                    let duration = usesAdjacentAnimation
                        ? 0.36
                        : (estimatedSegmentCount == 1 ? 0.9 : 0.52)
                    await animateMessageJump(
                        to: messageID,
                        anchor: .top,
                        duration: duration,
                        phase: estimatedSegmentCount == 1 ? .complete : .decelerating,
                        generation: generation,
                        sessionID: sessionID
                    )
                    return
                }

                let preservedAnchorID: UUID?
                let preservedAnchor: UnitPoint
                switch position {
                case .earlier:
                    preservedAnchorID = viewModel.displayMessages.first?.id
                    preservedAnchor = .top
                case .later:
                    preservedAnchorID = viewModel.displayMessages.last?.id
                    preservedAnchor = .bottom
                case .visible:
                    return
                }

                guard let preservedAnchorID,
                      viewModel.shiftHistoryWindow(
                        toward: messageID,
                        weightedBatchSize: historyJumpBatchSize
                      ) else {
                    return
                }

                // 数据窗口移动后先把原边界钉回原位；这一帧不动画，避免窗口裁切形成瞬移。
                await Task.yield()
                guard !Task.isCancelled,
                      generation == scrollTargetGeneration,
                      sessionID == viewModel.currentSession?.id,
                      viewModel.displayMessages.contains(where: { $0.id == preservedAnchorID }) else {
                    return
                }
                applyScrollTargetWithoutAnimation(
                    .message(preservedAnchorID),
                    anchor: preservedAnchor
                )
                await Task.yield()

                completedSegmentCount += 1
                let updatedPosition = viewModel.historyWindowPosition(of: messageID)
                let isFinalSegment = updatedPosition == .visible
                if isFinalSegment, viewModel.centerHistoryWindow(on: messageID) {
                    await Task.yield()
                    guard !Task.isCancelled,
                          generation == scrollTargetGeneration,
                          sessionID == viewModel.currentSession?.id,
                          viewModel.displayMessages.contains(where: { $0.id == preservedAnchorID }) else {
                        return
                    }
                }
                let destinationID: UUID?
                let destinationAnchor: UnitPoint
                if isFinalSegment {
                    destinationID = messageID
                    destinationAnchor = .top
                } else if position == .earlier {
                    destinationID = viewModel.displayMessages.first?.id
                    destinationAnchor = .top
                } else {
                    destinationID = viewModel.displayMessages.last?.id
                    destinationAnchor = .bottom
                }
                guard let destinationID else { return }

                let phase: ChatMessageJumpAnimationPhase
                if estimatedSegmentCount == 1 {
                    phase = .complete
                } else if completedSegmentCount == 1 {
                    phase = .accelerating
                } else if isFinalSegment {
                    phase = .decelerating
                } else {
                    phase = .cruising
                }
                let duration = historyJumpSegmentDuration(
                    estimatedSegmentCount: estimatedSegmentCount
                )
                await animateMessageJump(
                    to: destinationID,
                    anchor: destinationAnchor,
                    duration: duration,
                    phase: phase,
                    generation: generation,
                    sessionID: sessionID
                )
                if isFinalSegment { return }
            }
        }
    }

    private func animateMessageJump(
        to messageID: UUID,
        anchor: UnitPoint,
        duration: TimeInterval,
        phase: ChatMessageJumpAnimationPhase,
        generation: UInt,
        sessionID: UUID?
    ) async {
        guard canApplyScrollTarget(
            .message(messageID),
            generation: generation,
            sessionID: sessionID
        ) else {
            return
        }
        releaseMessageJumpScrollTarget()
        await Task.yield()
        guard !Task.isCancelled,
              generation == scrollTargetGeneration,
              sessionID == viewModel.currentSession?.id else {
            return
        }

        let animation: Animation
        if accessibilityReduceMotion {
            animation = .linear(duration: 0)
        } else {
            switch phase {
            case .accelerating:
                animation = .timingCurve(0.55, 0, 0.82, 0.32, duration: duration)
            case .cruising:
                animation = .linear(duration: duration)
            case .decelerating:
                animation = .timingCurve(0.18, 0.68, 0.35, 1, duration: duration)
            case .complete:
                animation = .timingCurve(0.65, 0, 0.35, 1, duration: duration)
            }
        }
        applyScrollTarget(
            .message(messageID),
            anchor: anchor,
            animated: !accessibilityReduceMotion,
            animation: animation
        )
        guard !accessibilityReduceMotion else {
            // 无动画仍需跨过 SwiftUI 的布局消费边沿，不能在同一更新周期清空目标。
            try? await Task.sleep(nanoseconds: 80_000_000)
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    private func historyJumpSegmentDuration(estimatedSegmentCount: Int) -> TimeInterval {
        switch estimatedSegmentCount {
        case ...1: return 0.9
        case 2: return 0.68
        case 3: return 0.56
        default: return max(0.3, min(0.5, 2.4 / Double(estimatedSegmentCount)))
        }
    }

    private func applyScrollTargetWithoutAnimation(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint
    ) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chatScrollTargetAnchor = anchor
            chatScrollTarget = target
        }
    }

    func releaseMessageJumpScrollTarget() {
        guard chatScrollTarget != nil else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chatScrollTarget = nil
        }
    }

    func canApplyScrollTarget(
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
                bottomScrollCommandGeneration &+= 1
            }
            applyScrollTarget(
                target,
                anchor: anchor,
                animated: animated,
                animation: animation
            )
            if releasesAtBottom {
                scheduleBottomScrollCommandRelease(
                    target: target,
                    generation: generation,
                    sessionID: sessionID,
                    animated: animated
                )
            }
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
                bottomScrollCommandGeneration &+= 1
            }
            applyScrollTarget(
                target,
                anchor: anchor,
                animated: animated,
                animation: animation
            )
            if releasesAtBottom {
                scheduleBottomScrollCommandRelease(
                    target: target,
                    generation: generation,
                    sessionID: sessionID,
                    animated: animated
                )
            }
        }
    }
}
