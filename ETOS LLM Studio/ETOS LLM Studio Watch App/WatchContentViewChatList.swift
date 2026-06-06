// ============================================================================
// WatchContentViewChatList.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 主聊天列表、滚动锚点、时间线连接与搜索跳转辅助。
// ============================================================================

import SwiftUI
import Foundation
import Shared

extension ContentView {
    func chatList(proxy: ScrollViewProxy) -> some View {
        let displayedMessages = viewModel.displayMessages
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: viewModel.allMessagesForSession,
            isSending: viewModel.isSendingMessage
        )
        return List {
            if viewModel.messages.isEmpty {
                Spacer().frame(height: emptyStateSpacerHeight).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }

            let remainingCount = viewModel.remainingHistoryCount
            if viewModel.usesManualHistoryLoading && !viewModel.isHistoryFullyLoaded && remainingCount > 0 {
                let chunk = viewModel.historyLoadChunkCount
                Button(action: {
                    suppressAutoScrollOnce = true
                    withAnimation {
                        viewModel.loadMoreHistoryChunk()
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle")
                            .etFont(.system(size: 13, weight: .semibold))
                        Text(String(format: NSLocalizedString("向上加载 %d 条记录", comment: ""), chunk))
                            .etFont(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        historyLoadButtonBackground
                    }
                    .overlay(
                        Capsule()
                            .stroke(inputStrokeColor, lineWidth: 0.6)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            }

            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, state in
                let message = state.message
                let previousMessage = index > 0 ? displayedMessages[index - 1].message : nil
                let nextMessage = index + 1 < displayedMessages.count ? displayedMessages[index + 1].message : nil
                let mergeWithPrevious = shouldMergeTurnMessages(previousMessage, with: message)
                let mergeWithNext = shouldMergeTurnMessages(message, with: nextMessage)
                let messageActionBarContinuesToNext = shouldContinueMessageActionBar(message, with: nextMessage)
                let connectsTimelineFromPrevious = shouldConnectTimeline(previousMessage, with: message)
                let connectsTimelineToNext = shouldConnectTimeline(message, with: nextMessage)
                WatchMessageRowView(
                    viewModel: viewModel,
                    toolPermissionCenter: toolPermissionCenter,
                    state: state,
                    mergeWithPrevious: mergeWithPrevious,
                    mergeWithNext: mergeWithNext,
                    messageActionBarContinuesToNext: messageActionBarContinuesToNext,
                    connectsTimelineFromPrevious: connectsTimelineFromPrevious,
                    connectsTimelineToNext: connectsTimelineToNext,
                    isLiquidGlassEnabled: isLiquidGlassEnabled,
                    canRetry: retryableMessageIDs.contains(message.id),
                    onOpenMore: {
                        messageActionsTarget = WatchMessageActionsNavigationTarget(id: message.id)
                    }
                )
                .onAppear {
                    loadMoreAutomaticHistoryIfNeeded(
                        proxy: proxy,
                        anchorMessageID: state.id,
                        isFirstDisplayedMessage: index == 0
                    )
                }
            }

            if viewModel.activeAskUserInputRequest == nil {
                WatchInputBubbleView(
                    viewModel: viewModel,
                    isLiquidGlassEnabled: isLiquidGlassEnabled,
                    inputControlHeight: inputControlHeight,
                    inputFillColor: inputFillColor,
                    inputStrokeColor: inputStrokeColor,
                    inputPlaceholderText: NSLocalizedString("输入...", comment: "Default input placeholder on watch"),
                    inputBubbleVerticalPadding: inputBubbleVerticalPadding,
                    onOpenSessionHistory: {
                        viewModel.activeSheet = nil
                        isSettingsPresented = false
                        settingsDestination = nil
                        isSessionListPresented = true
                    },
                    onHandleInputAction: { state in
                        switch state {
                        case .stop:
                            viewModel.cancelSending()
                        case .send:
                            shouldForceScrollToBottom = true
                            shouldKeepBottomPinned = true
                            viewModel.sendMessage()
                        case .quickRetry:
                            shouldForceScrollToBottom = true
                            shouldKeepBottomPinned = true
                            viewModel.quickRetryLatestMessage()
                        case .speechInput:
                            viewModel.beginSpeechInputFlow()
                        case .inactive:
                            break
                        }
                    },
                    onRememberAttachmentSource: { source in
                        let updatedHistory = WatchImportSourceHistory.appending(
                            source,
                            to: importSourceHistory
                        )
                        appConfig.watchAttachmentSourceHistory = WatchImportSourceHistory.rawValue(for: updatedHistory)
                        appConfig.watchAttachmentLastSource = updatedHistory.first ?? ""
                        importSourceHistory = updatedHistory
                    },
                    importSourceHistory: importSourceHistory,
                    lastAttachmentSource: appConfig.watchAttachmentLastSource,
                    isRequestControlsPresented: $isRequestControlsPresented,
                    isAttachmentImportPresented: $isAttachmentImportPresented,
                    attachmentSourceText: $attachmentSourceText
                )
                    .id(bottomAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .onAppear {
                        bottomAnchorVisibilityWorkItem?.cancel()
                        bottomAnchorVisibilityWorkItem = nil
                        isAtBottom = true
                        shouldKeepBottomPinned = true
                        showScrollToBottomButton = false
                        if viewModel.resetAutomaticHistoryWindowIfNeeded() {
                            scheduleDeferredBottomSnap(proxy: proxy)
                        }
                    }
                    .onDisappear {
                        bottomAnchorVisibilityWorkItem?.cancel()
                        let workItem = DispatchWorkItem {
                            isAtBottom = false
                            shouldKeepBottomPinned = false
                            showScrollToBottomButton = true
                            bottomAnchorVisibilityWorkItem = nil
                        }
                        bottomAnchorVisibilityWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
                    }
            } else {
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.activeSheet = nil
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .onChange(of: viewModel.messages.count) {
            if needsImmediateBottomSnap {
                scheduleImmediateBottomSnap(proxy: proxy)
                return
            }
            if suppressAutoScrollOnce {
                suppressAutoScrollOnce = false
                return
            }
            let shouldScroll = isAtBottom || shouldForceScrollToBottom || (viewModel.isSendingMessage && shouldKeepBottomPinned)
            shouldForceScrollToBottom = false
            guard shouldScroll else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: viewModel.streamingScrollAnchorVersion) { _, _ in
            guard viewModel.isSendingMessage, shouldKeepBottomPinned else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
            guard newValue != nil, isAtBottom else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: pendingJumpRequest) { _, request in
            guard let request else { return }
            withAnimation {
                proxy.scrollTo(request.messageID, anchor: .center)
            }
        }
        .onChange(of: viewModel.pendingSearchJumpTarget) { _, _ in
            resolvePendingSearchJumpIfNeeded()
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            pendingHistoryResetWorkItem?.cancel()
            pendingHistoryResetWorkItem = nil
            shouldRestorePendingJumpOnAppear = false
            shouldKeepBottomPinned = true
            needsImmediateBottomSnap = true
            showScrollToBottomButton = false
            scheduleImmediateBottomSnap(proxy: proxy)
            resolvePendingSearchJumpIfNeeded()
        }
        .onChange(of: viewModel.displayMessageIdentityVersion) { _, _ in
            if needsImmediateBottomSnap, !viewModel.displayMessages.isEmpty {
                scheduleImmediateBottomSnap(proxy: proxy)
            }
            resolvePendingSearchJumpIfNeeded()
        }
        .onAppear {
            if shouldRestorePendingJumpOnAppear {
                shouldRestorePendingJumpOnAppear = false
                resolvePendingSearchJumpIfNeeded()
                DispatchQueue.main.async {
                    if let request = pendingJumpRequest {
                        withAnimation {
                            proxy.scrollTo(request.messageID, anchor: .center)
                        }
                    }
                }
                return
            }
            resolvePendingSearchJumpIfNeeded()
            if needsImmediateBottomSnap {
                shouldKeepBottomPinned = true
                scheduleImmediateBottomSnap(proxy: proxy)
            }
        }
    }

    func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        let scrollAction = {
            pendingHistoryResetWorkItem?.cancel()
            pendingHistoryResetWorkItem = nil
            shouldRestorePendingJumpOnAppear = false
            shouldKeepBottomPinned = true
            showScrollToBottomButton = false

            let shouldResetHistoryWindow = viewModel.usesManualHistoryLoading || viewModel.usesAutomaticHistoryWindow
            guard shouldResetHistoryWindow else {
                scrollToBottom(proxy: proxy, animated: true)
                return
            }

            let workItem = DispatchWorkItem {
                pendingBottomSnapTask?.cancel()
                pendingBottomSnapTask = nil
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    viewModel.resetLazyLoadState()
                }
                pendingHistoryResetWorkItem = nil
                scheduleDeferredBottomSnap(proxy: proxy)
            }
            pendingHistoryResetWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        return Button(action: scrollAction) {
            let icon = Image(systemName: "arrow.down.circle")
                .etFont(.system(size: 22, weight: .semibold))
                .frame(width: 60, height: 60)
                .opacity(0.4)
                .contentShape(Circle())

            if isLiquidGlassEnabled {
                if #available(watchOS 26.0, *) {
                    icon
                } else {
                    icon
                }
            } else {
                icon
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .transition(.scale.combined(with: .opacity))
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

    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation {
                action()
            }
        } else {
            action()
        }
    }

    func loadMoreAutomaticHistoryIfNeeded(
        proxy: ScrollViewProxy,
        anchorMessageID: UUID,
        isFirstDisplayedMessage: Bool
    ) {
        guard isFirstDisplayedMessage, viewModel.usesAutomaticHistoryWindow else { return }
        suppressAutoScrollOnce = true
        let didLoad = viewModel.loadMoreAutomaticHistoryIfNeeded()
        guard didLoad else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(anchorMessageID, anchor: .top)
        }
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
        shouldForceScrollToBottom = false
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

    var inputFillColor: Color {
        viewModel.enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    @ViewBuilder
    var historyLoadButtonBackground: some View {
        let shape = Capsule()
        if isLiquidGlassEnabled {
            if #available(watchOS 26.0, *) {
                shape
                    .fill(inputFillColor)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape.fill(inputFillColor)
            }
        } else {
            shape.fill(inputFillColor)
        }
    }

    func scheduleImmediateBottomSnap(proxy: ScrollViewProxy) {
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = Task { @MainActor in
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy, animated: false)
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            needsImmediateBottomSnap = false
            pendingBottomSnapTask = nil
        }
    }

    func scheduleDeferredBottomSnap(proxy: ScrollViewProxy) {
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy, animated: false)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            guard !Task.isCancelled else { return }
            pendingBottomSnapTask = nil
        }
    }

    var inputStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }
}
