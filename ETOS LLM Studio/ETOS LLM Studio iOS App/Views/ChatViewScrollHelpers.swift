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
    /// 可见坐标会随每个滚动像素变化；只在导航或静止审计真正需要时上报。
    var shouldReportChatViewportLayoutFrames: Bool {
        guard !scrollCoordinator.isChatScrollUserInteracting else { return false }
        let needsNavigationFrames = scrollCoordinator.showScrollNavigationPanel || accessibilityVoiceOverEnabled
        let canAuditSettledLayout = !scrollCoordinator.isChatScrollUserInteracting
            && !viewModel.isSendingMessage
            && !hasChatProgrammaticScrollOwnership
            && !scrollCoordinator.isHistoryLoadInFlight
        return needsNavigationFrames || canAuditSettledLayout
    }

    var hasChatProgrammaticScrollOwnership: Bool {
        scrollCoordinator.hasRetainedTimelineNavigationTarget
            || isMessageJumpInFlight
            || scrollCoordinator.pendingHistoryResetWorkItem != nil
            || scrollCoordinator.pendingBottomSnapTask != nil
            || scrollCoordinator.pendingScrollTargetTask != nil
            || scrollCoordinator.chatScrollPositionController.hasActiveCommand
    }

    /// 四键游标在用户亲自拖动前持续独占视口；布局自愈不能追越该边界。
    /// 布局自愈自己的定位命令不计入，避免它取消自身恢复闭环。
    var hasExclusiveChatViewportCommand: Bool {
        scrollCoordinator.hasRetainedTimelineNavigationTarget
            || isMessageJumpInFlight
            || scrollCoordinator.pendingHistoryResetWorkItem != nil
            || scrollCoordinator.pendingBottomSnapTask != nil
            || scrollCoordinator.pendingScrollTargetTask != nil
            || scrollCoordinator.chatScrollPositionController.activeCommandOwner == .viewportNavigation
    }

    var hasExplicitChatNavigationCommand: Bool {
        Self.shouldSuspendAutomaticHistoryNavigation(
            hasRetainedTimelineNavigationTarget: scrollCoordinator.hasRetainedTimelineNavigationTarget,
            isMessageJumpInFlight: isMessageJumpInFlight,
            hasPendingHistoryReset: scrollCoordinator.pendingHistoryResetWorkItem != nil,
            hasPendingBottomSnap: scrollCoordinator.pendingBottomSnapTask != nil,
            hasActiveBottomTarget: scrollCoordinator.chatScrollPositionController.activeCommandTarget == bottomScrollTarget,
            hasPendingOrAppliedTarget: scrollCoordinator.pendingScrollTargetTask != nil
                || scrollCoordinator.chatScrollPositionController.hasActiveCommand
        )
    }

    /// 非流式尺寸变化交给 SwiftUI；流式期间由 UIKit 单独动画真实滚动偏移，避免双重吸底。
    nonisolated static func chatSizeChangeScrollAnchor(
        keepsBottomPinned: Bool,
        isStreaming: Bool
    ) -> UnitPoint? {
        keepsBottomPinned && !isStreaming ? .bottom : nil
    }

    /// 用户手势与离底导航永远优先于自动吸底；静止时只有真正回到底部才重新接管。
    nonisolated static func resolvedBottomPinIntent(
        currentIntent: Bool,
        distanceToBottom: CGFloat,
        arrivalTolerance: CGFloat,
        isUserInteracting: Bool,
        isLayoutSettling: Bool,
        isNavigatingAwayFromBottom: Bool = false
    ) -> Bool {
        if isUserInteracting || isNavigatingAwayFromBottom {
            return false
        }
        if currentIntent {
            return true
        }
        return !isLayoutSettling && distanceToBottom <= arrivalTolerance
    }

    /// 相连气泡属于同一视觉组，不能被逐条滚动位移撕开连接处。
    nonisolated static func chatScrollTransitionOffset(
        phaseValue: CGFloat,
        configuredOffset: Double,
        isEnabled: Bool,
        isConnectedToAdjacentBubble: Bool,
        isBottomPinnedStreamingBubble: Bool = false,
        isViewportTransitioning: Bool = false,
        isTimelineNavigationActive: Bool = false
    ) -> CGFloat {
        guard isEnabled,
              !isConnectedToAdjacentBubble,
              !isBottomPinnedStreamingBubble,
              !isViewportTransitioning,
              !isTimelineNavigationActive else {
            return 0
        }
        return phaseValue * CGFloat(configuredOffset)
    }

    /// 相邻导航即使需要先扩展懒加载窗口，也必须沿用同一个短动画节奏。
    nonisolated static func resolvedMessageJumpDuration(
        defaultDuration: TimeInterval,
        usesAdjacentAnimation: Bool,
        isFinalSegment: Bool,
        adjacentDuration: TimeInterval = 0.28
    ) -> TimeInterval {
        usesAdjacentAnimation && isFinalSegment ? adjacentDuration : defaultDuration
    }

    /// 相邻目标扩窗后已经可用时直接提交最终落点，不能先排队旧边界定位。
    nonisolated static func shouldUseSingleFinalAdjacentJump(
        usesAdjacentAnimation: Bool,
        targetIsVisibleAfterWindowShift: Bool
    ) -> Bool {
        usesAdjacentAnimation && targetIsVisibleAfterWindowShift
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
        isUserInteracting: Bool,
        arrivalTolerance: CGFloat,
        hasExceededMaximumLifetime: Bool = false
    ) -> Bool {
        hasActiveTarget
            && (isUserInteracting
                || distanceToBottom <= arrivalTolerance
                || hasExceededMaximumLifetime)
    }

    nonisolated static func shouldSuspendAutomaticHistoryNavigation(
        hasRetainedTimelineNavigationTarget: Bool,
        isMessageJumpInFlight: Bool,
        hasPendingHistoryReset: Bool,
        hasPendingBottomSnap: Bool,
        hasActiveBottomTarget: Bool,
        hasPendingOrAppliedTarget: Bool
    ) -> Bool {
        hasRetainedTimelineNavigationTarget
            || isMessageJumpInFlight
            || hasPendingHistoryReset
            || hasPendingBottomSnap
            || hasActiveBottomTarget
            || hasPendingOrAppliedTarget
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
        scrollCoordinator.awaitsFreshBottomNavigationSnapshot = false
        scrollCoordinator.pendingHistoryResetWorkItem?.cancel()
        scrollCoordinator.pendingHistoryResetWorkItem = nil
        scrollCoordinator.pendingBottomSnapTask?.cancel()
        scrollCoordinator.pendingBottomSnapTask = nil
        cancelPendingScrollTargetCommand()
        scrollCoordinator.prepareForExclusiveViewportNavigation()
        scrollCoordinator.messageNavigationCursorID = nil
        pendingJumpRequest = nil
        isMessageJumpInFlight = true
        scrollCoordinator.needsImmediateBottomSnap = false
        shouldRestorePendingJumpOnAppear = true
        scrollCoordinator.shouldKeepBottomPinned = false
    }

    func handleDisplayedMessageIdentityChange() {
        let visibleMessageIDs = Set(viewModel.displayMessages.map(\.id))
        if let activeTarget = scrollCoordinator.chatScrollPositionController.activeCommandTarget,
           !Self.isChatScrollTargetAvailable(activeTarget, visibleMessageIDs: visibleMessageIDs) {
            cancelPendingScrollTargetCommand()
        }

        if isMessageJumpInFlight {
            resolvePendingSearchJumpIfNeeded()
            return
        }

        guard !viewModel.displayMessages.isEmpty else {
            scrollCoordinator.shouldKeepBottomPinned = true
            scrollCoordinator.showScrollToBottom = false
            resolvePendingSearchJumpIfNeeded()
            return
        }

        if scrollCoordinator.needsImmediateBottomSnap {
            scheduleImmediateBottomSnap()
            resolvePendingSearchJumpIfNeeded()
            return
        }
        if scrollCoordinator.suppressAutoScrollOnce {
            scrollCoordinator.suppressAutoScrollOnce = false
            resolvePendingSearchJumpIfNeeded()
            return
        }
        if scrollCoordinator.shouldKeepBottomPinned {
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
        animation: Animation = .easeOut(duration: 0.25),
        allowsDuringUserInteraction: Bool = false
    ) {
        guard allowsDuringUserInteraction
                || !scrollCoordinator.isChatScrollUserInteracting else {
            return
        }
        scrollCoordinator.prepareForExclusiveViewportNavigation()
        scrollCoordinator.shouldKeepBottomPinned = true
        setScrollTarget(
            bottomScrollTarget,
            anchor: .bottom,
            animated: animated,
            animation: animation,
            allowsDuringUserInteraction: allowsDuringUserInteraction,
            releasesAtBottom: true
        )
    }

    func scheduleImmediateBottomSnap() {
        scrollCoordinator.pendingBottomSnapTask?.cancel()
        guard !scrollCoordinator.isChatScrollUserInteracting else {
            scrollCoordinator.needsImmediateBottomSnap = false
            scrollCoordinator.pendingBottomSnapTask = nil
            return
        }
        scrollCoordinator.shouldKeepBottomPinned = true
        guard !viewModel.displayMessages.isEmpty else {
            scrollCoordinator.needsImmediateBottomSnap = true
            scrollCoordinator.pendingBottomSnapTask = nil
            return
        }
        scrollCoordinator.pendingBottomSnapTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToBottom(animated: false)
            scrollCoordinator.needsImmediateBottomSnap = false
            scrollCoordinator.pendingBottomSnapTask = nil
        }
    }

    func scheduleDeferredBottomSnap(allowsDuringUserInteraction: Bool = false) {
        scrollCoordinator.pendingBottomSnapTask?.cancel()
        guard allowsDuringUserInteraction
                || !scrollCoordinator.isChatScrollUserInteracting else {
            scrollCoordinator.pendingBottomSnapTask = nil
            return
        }
        scrollCoordinator.shouldKeepBottomPinned = true
        scrollCoordinator.pendingBottomSnapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            scrollToBottom(
                animated: false,
                allowsDuringUserInteraction: allowsDuringUserInteraction
            )
            scrollCoordinator.pendingBottomSnapTask = nil
        }
    }

    func restorePendingMessageJumpIfNeeded() {
        guard scrollCoordinator.pendingScrollTargetTask == nil, let request = pendingJumpRequest else { return }
        scheduleMessageJump(to: request.messageID)
    }

    var bottomScrollTarget: ChatScrollTargetID {
        Self.resolvedBottomScrollTarget
    }

    /// ScrollViewReader 只消费一次命令，不把目标长期绑定为视口状态。
    func consumeChatScrollCommand(using proxy: ScrollViewProxy) {
        let controller = scrollCoordinator.chatScrollPositionController
        guard let target = controller.activeCommandTarget else { return }
        let scroll = {
            proxy.scrollTo(target, anchor: controller.targetAnchor)
        }
        if let animation = controller.activeCommandAnimation {
            withAnimation(animation) {
                scroll()
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scroll()
            }
        }
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat, isUserInteracting: Bool) {
        let normalizedDistance = max(distanceToBottom, 0)
        scrollCoordinator.scrollDistanceToBottom = normalizedDistance
        guard !viewModel.displayMessages.isEmpty else {
            scrollCoordinator.shouldKeepBottomPinned = true
            hideScrollNavigationPanel()
            if scrollCoordinator.showScrollToBottom {
                withAnimation(.easeInOut(duration: 0.18)) {
                    scrollCoordinator.showScrollToBottom = false
                }
            }
            return
        }
        scrollCoordinator.shouldKeepBottomPinned = Self.resolvedBottomPinIntent(
            currentIntent: scrollCoordinator.shouldKeepBottomPinned,
            distanceToBottom: normalizedDistance,
            arrivalTolerance: bottomScrollCommandArrivalTolerance,
            isUserInteracting: isUserInteracting,
            isLayoutSettling: scrollCoordinator.isChatLayoutSettling,
            isNavigatingAwayFromBottom: isMessageJumpInFlight
                || scrollCoordinator.hasRetainedTimelineNavigationTarget
        )

        let shouldShow = normalizedDistance > scrollToBottomButtonRevealDistance && !scrollCoordinator.shouldKeepBottomPinned
        if scrollCoordinator.showScrollToBottom != shouldShow {
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollCoordinator.showScrollToBottom = shouldShow
            }
        }
    }

    /// 抵达底部或用户接管后释放一次性命令的所有权，
    /// 后续流式增长统一交给尺寸变化锚点。
    func resolveActiveBottomScrollCommand(
        distanceToBottom: CGFloat,
        isUserInteracting: Bool
    ) {
        guard Self.shouldReleaseActiveBottomScrollCommand(
            hasActiveTarget: scrollCoordinator.chatScrollPositionController.activeCommandTarget == bottomScrollTarget,
            distanceToBottom: distanceToBottom,
            isUserInteracting: isUserInteracting,
            arrivalTolerance: bottomScrollCommandArrivalTolerance
        ) else { return }
        releaseActiveBottomScrollCommand()
    }

    func releaseActiveBottomScrollCommand() {
        scrollCoordinator.bottomScrollCommandReleaseTask?.cancel()
        scrollCoordinator.bottomScrollCommandReleaseTask = nil
        guard let target = scrollCoordinator.chatScrollPositionController.activeCommandTarget else { return }
        scrollCoordinator.chatScrollPositionController.releaseCommand(expectedTarget: target)
        if scrollCoordinator.awaitsFreshBottomNavigationSnapshot {
            scrollCoordinator.bottomNavigationSnapshotBaselineRevision =
                scrollCoordinator.chatLayoutIntegrityMonitor.requestFreshNavigationSnapshot()
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
        scrollCoordinator.bottomScrollCommandReleaseTask?.cancel()
        let maximumLifetimeNanoseconds: UInt64 = animated ? 900_000_000 : 160_000_000
        scrollCoordinator.bottomScrollCommandReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: maximumLifetimeNanoseconds)
            guard !Task.isCancelled,
                  generation == scrollCoordinator.scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id,
                  scrollCoordinator.chatScrollPositionController.activeCommandTarget == target,
                  Self.shouldReleaseActiveBottomScrollCommand(
                    hasActiveTarget: true,
                    distanceToBottom: scrollCoordinator.scrollDistanceToBottom,
                    isUserInteracting: scrollCoordinator.isChatScrollUserInteracting,
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
        scrollCoordinator.shouldKeepBottomPinned = false
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
            currentIntent: scrollCoordinator.shouldKeepBottomPinned,
            distanceToBottom: scrollCoordinator.scrollDistanceToBottom,
            arrivalTolerance: bottomScrollCommandArrivalTolerance,
            isUserInteracting: scrollCoordinator.isChatScrollUserInteracting,
            isLayoutSettling: scrollCoordinator.isChatLayoutSettling,
            isNavigatingAwayFromBottom: isMessageJumpInFlight
                || scrollCoordinator.hasRetainedTimelineNavigationTarget
        )
    }

    func beginChatLayoutSettling(keepBottomPinned: Bool) {
        scrollCoordinator.chatLayoutSettleTask?.cancel()
        scrollCoordinator.isChatLayoutSettling = true
        scrollCoordinator.shouldKeepBottomPinned = keepBottomPinned

        scrollCoordinator.chatLayoutSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            scrollCoordinator.isChatLayoutSettling = false
            scrollCoordinator.chatLayoutSettleTask = nil
        }
    }

    func cancelPendingScrollTargetCommand(preservingMessageJump: Bool = false) {
        scrollCoordinator.scrollTargetGeneration &+= 1
        scrollCoordinator.pendingScrollTargetTask?.cancel()
        scrollCoordinator.pendingScrollTargetTask = nil
        releaseActiveBottomScrollCommand()
        scrollCoordinator.chatScrollPositionController.releaseCommand()
        if !preservingMessageJump {
            pendingJumpRequest = nil
            isMessageJumpInFlight = false
            shouldRestorePendingJumpOnAppear = false
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
        let generation = scrollCoordinator.scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id
        let initialDistance = viewModel.historyWindowDistance(to: messageID) ?? 0
        // 四键是相邻浏览，不能复用编号搜索的十二条分段窗口。
        let windowShiftBatchSize = usesAdjacentAnimation ? 1 : historyJumpBatchSize
        let estimatedSegmentCount = max(
            1,
            (initialDistance + windowShiftBatchSize - 1) / windowShiftBatchSize
        )

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

            // 先让选择器关闭与跳转状态进入当前事务，下一轮再开始移动列表。
            await Task.yield()
            var completedSegmentCount = 0

            while !Task.isCancelled,
                  generation == scrollCoordinator.scrollTargetGeneration,
                  sessionID == viewModel.currentSession?.id,
                  pendingJumpRequest == request,
                  let position = viewModel.historyWindowPosition(of: messageID) {
                if position == .visible {
                    let duration = Self.resolvedMessageJumpDuration(
                        defaultDuration: estimatedSegmentCount == 1 ? 0.9 : 0.52,
                        usesAdjacentAnimation: usesAdjacentAnimation,
                        isFinalSegment: true
                    )
                    await animateMessageJump(
                        to: messageID,
                        anchor: .top,
                        duration: duration,
                        phase: usesAdjacentAnimation
                            ? .adjacent
                            : (estimatedSegmentCount == 1 ? .complete : .decelerating),
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
                        weightedBatchSize: windowShiftBatchSize,
                        preservesCurrentWindowSize: usesAdjacentAnimation
                      ) else {
                    return
                }

                // 先让新窗口进入视图树；相邻导航随后只提交最终落点。
                await Task.yield()
                guard !Task.isCancelled,
                      generation == scrollCoordinator.scrollTargetGeneration,
                      sessionID == viewModel.currentSession?.id else {
                    return
                }
                let positionAfterWindowShift = viewModel.historyWindowPosition(of: messageID)
                if Self.shouldUseSingleFinalAdjacentJump(
                    usesAdjacentAnimation: usesAdjacentAnimation,
                    targetIsVisibleAfterWindowShift: positionAfterWindowShift == .visible
                ) {
                    await animateMessageJump(
                        to: messageID,
                        anchor: .top,
                        duration: Self.resolvedMessageJumpDuration(
                            defaultDuration: historyJumpSegmentDuration(
                                estimatedSegmentCount: estimatedSegmentCount
                            ),
                            usesAdjacentAnimation: true,
                            isFinalSegment: true
                        ),
                        phase: .adjacent,
                        generation: generation,
                        sessionID: sessionID
                    )
                    return
                }
                guard viewModel.displayMessages.contains(where: { $0.id == preservedAnchorID }) else {
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
                if isFinalSegment,
                   !usesAdjacentAnimation,
                   viewModel.centerHistoryWindow(on: messageID) {
                    await Task.yield()
                    guard !Task.isCancelled,
                          generation == scrollCoordinator.scrollTargetGeneration,
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
                if usesAdjacentAnimation, isFinalSegment {
                    phase = .adjacent
                } else if estimatedSegmentCount == 1 {
                    phase = .complete
                } else if completedSegmentCount == 1 {
                    phase = .accelerating
                } else if isFinalSegment {
                    phase = .decelerating
                } else {
                    phase = .cruising
                }
                let duration = Self.resolvedMessageJumpDuration(
                    defaultDuration: historyJumpSegmentDuration(
                        estimatedSegmentCount: estimatedSegmentCount
                    ),
                    usesAdjacentAnimation: usesAdjacentAnimation,
                    isFinalSegment: isFinalSegment
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
              generation == scrollCoordinator.scrollTargetGeneration,
              sessionID == viewModel.currentSession?.id else {
            return
        }

        let animation: Animation
        if accessibilityReduceMotion {
            animation = .linear(duration: 0)
        } else {
            switch phase {
            case .adjacent:
                animation = .smooth(duration: duration)
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
            animation: animation,
            allowsDuringUserInteraction: true
        )
        guard !accessibilityReduceMotion else {
            // 无动画仍需跨过 SwiftUI 的布局消费边沿，不能在同一更新周期清空目标。
            try? await Task.sleep(nanoseconds: 80_000_000)
            return
        }
        let settleDuration = phase == .adjacent ? duration + 0.05 : duration
        try? await Task.sleep(nanoseconds: UInt64(settleDuration * 1_000_000_000))
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
        scrollCoordinator.chatScrollPositionController.issueCommand(
            to: target,
            anchor: anchor,
            allowsDuringUserInteraction: true
        )
    }

    func releaseMessageJumpScrollTarget() {
        scrollCoordinator.chatScrollPositionController.releaseCommand(
            expectedOwner: .viewportNavigation
        )
    }

    func canApplyScrollTarget(
        _ target: ChatScrollTargetID,
        generation: UInt,
        sessionID: UUID?
    ) -> Bool {
        guard generation == scrollCoordinator.scrollTargetGeneration,
              sessionID == viewModel.currentSession?.id else {
            return false
        }
        return Self.isChatScrollTargetAvailable(
            target,
            visibleMessageIDs: Set(viewModel.displayMessages.map(\.id))
        )
    }

    @discardableResult
    private func applyScrollTarget(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint,
        animated: Bool,
        animation: Animation,
        allowsDuringUserInteraction: Bool = false
    ) -> Bool {
        scrollCoordinator.chatScrollPositionController.issueCommand(
            to: target,
            anchor: anchor,
            animation: animated ? animation : nil,
            allowsDuringUserInteraction: allowsDuringUserInteraction
        )
    }

    private func setScrollTarget(
        _ target: ChatScrollTargetID,
        anchor: UnitPoint,
        animated: Bool,
        animation: Animation,
        deferred: Bool = false,
        allowsDuringUserInteraction: Bool = false,
        releasesAtBottom: Bool = false
    ) {
        let shouldDefer = deferred
            || scrollCoordinator.chatScrollPositionController.activeCommandTarget == target
        cancelPendingScrollTargetCommand()
        let generation = scrollCoordinator.scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id

        guard shouldDefer else {
            guard canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else { return }
            let didIssueCommand = applyScrollTarget(
                target,
                anchor: anchor,
                animated: animated,
                animation: animation,
                allowsDuringUserInteraction: allowsDuringUserInteraction
            )
            if releasesAtBottom, didIssueCommand {
                scrollCoordinator.bottomScrollCommandGeneration &+= 1
                scheduleBottomScrollCommandRelease(
                    target: target,
                    generation: generation,
                    sessionID: sessionID,
                    animated: animated
                )
            }
            return
        }

        scrollCoordinator.chatScrollPositionController.releaseCommand(expectedTarget: target)
        scrollCoordinator.pendingScrollTargetTask = Task { @MainActor in
            defer {
                if generation == scrollCoordinator.scrollTargetGeneration {
                    scrollCoordinator.pendingScrollTargetTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else {
                return
            }
            let didIssueCommand = applyScrollTarget(
                target,
                anchor: anchor,
                animated: animated,
                animation: animation,
                allowsDuringUserInteraction: allowsDuringUserInteraction
            )
            if releasesAtBottom, didIssueCommand {
                scrollCoordinator.bottomScrollCommandGeneration &+= 1
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
