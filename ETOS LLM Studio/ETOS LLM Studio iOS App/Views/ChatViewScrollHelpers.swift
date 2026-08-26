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
        let needsNavigationFrames = showScrollNavigationPanel || accessibilityVoiceOverEnabled
        let canAuditSettledLayout = !isChatScrollUserInteracting
            && !viewModel.isSendingMessage
            && !hasChatProgrammaticScrollOwnership
            && !isHistoryLoadInFlight
        return needsNavigationFrames || canAuditSettledLayout
    }

    var hasChatProgrammaticScrollOwnership: Bool {
        isMessageJumpInFlight
            || pendingHistoryResetWorkItem != nil
            || pendingBottomSnapTask != nil
            || pendingScrollTargetTask != nil
            || chatScrollPositionController.hasActiveCommand
    }

    var hasExplicitChatNavigationCommand: Bool {
        Self.shouldSuspendAutomaticHistoryNavigation(
            isMessageJumpInFlight: isMessageJumpInFlight,
            hasPendingHistoryReset: pendingHistoryResetWorkItem != nil,
            hasPendingBottomSnap: pendingBottomSnapTask != nil,
            hasActiveBottomTarget: chatScrollPositionController.activeCommandTarget == bottomScrollTarget,
            hasPendingOrAppliedTarget: pendingScrollTargetTask != nil
                || chatScrollPositionController.hasActiveCommand
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
        hasPendingOrAppliedTarget: Bool
    ) -> Bool {
        isMessageJumpInFlight
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
        if let activeTarget = chatScrollPositionController.activeCommandTarget,
           !Self.isChatScrollTargetAvailable(activeTarget, visibleMessageIDs: visibleMessageIDs) {
            cancelPendingScrollTargetCommand()
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
            hasActiveTarget: chatScrollPositionController.activeCommandTarget == bottomScrollTarget,
            distanceToBottom: distanceToBottom,
            arrivalTolerance: bottomScrollCommandArrivalTolerance
        ) else { return }
        releaseActiveBottomScrollCommand()
    }

    func releaseActiveBottomScrollCommand() {
        bottomScrollCommandReleaseTask?.cancel()
        bottomScrollCommandReleaseTask = nil
        guard let target = chatScrollPositionController.activeCommandTarget else { return }
        chatScrollPositionController.releaseCommand(expectedTarget: target)
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
                  chatScrollPositionController.activeCommandTarget == target,
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
        chatScrollPositionController.releaseCommand()
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
        chatScrollPositionController.issueCommand(to: target, anchor: anchor)
    }

    func releaseMessageJumpScrollTarget() {
        chatScrollPositionController.releaseCommand()
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
            chatScrollPositionController.issueCommand(to: target, anchor: anchor)
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
        let shouldDefer = deferred
            || chatScrollPositionController.activeCommandTarget == target
        cancelPendingScrollTargetCommand()
        let generation = scrollTargetGeneration
        let sessionID = viewModel.currentSession?.id

        guard shouldDefer else {
            guard canApplyScrollTarget(target, generation: generation, sessionID: sessionID) else { return }
            if releasesAtBottom {
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

        chatScrollPositionController.releaseCommand(expectedTarget: target)
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
