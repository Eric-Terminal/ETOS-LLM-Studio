// ============================================================================
// WatchContentViewChatList.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 主聊天列表、滚动锚点、时间线连接与搜索跳转辅助。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

extension ContentView {
    func chatList(proxy: ScrollViewProxy) -> some View {
        let displayedMessages = viewModel.displayMessages
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: viewModel.allMessagesForSession,
            isSending: viewModel.isSendingMessage
        )
        return List {
            if viewModel.messages.isEmpty && continuationContext == nil {
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

            if let continuationContext,
               !continuationContext.isSourceSessionLinkHidden {
                WatchConversationContinuationLinkRow(
                    kind: .sourceSession,
                    linkedSessionName: continuationSourceSessionName(for: continuationContext),
                    linkedSessionAvailable: continuationSessionNamesByID[
                        continuationContext.sourceSessionID
                    ] != nil,
                    onOpen: {
                        _ = viewModel.setCurrentSessionIfExists(
                            sessionID: continuationContext.sourceSessionID
                        )
                    },
                    onDelete: {
                        hideConversationContinuationLink(
                            in: continuationContext,
                            kind: .sourceSession
                        )
                    }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }

            if let continuationContext {
                NavigationLink {
                    WatchConversationContinuationDetailView(
                        context: continuationContext,
                        enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
                        onInsertText: { text in
                            viewModel.applyToolInputDraftRequest(
                                AppToolInputDraftRequest(text: text, mode: .append)
                            )
                        }
                    )
                } label: {
                    WatchConversationContinuationCard(
                        context: continuationContext,
                        enableBackground: viewModel.enableBackground,
                        enableLiquidGlass: isLiquidGlassEnabled,
                        enableNoBubbleUI: viewModel.enableNoBubbleUI
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
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
                    isSelectionMode: isMessageSelectionMode,
                    isSelected: selectedMessageIDs.contains(message.id),
                    onToggleSelection: {
                        toggleMessageSelection(message.id)
                    },
                    onOpenMore: {
                        messageActionsTarget = WatchMessageActionsNavigationTarget(id: message.id)
                    }
                )

                if let contexts = outgoingContinuationContextsByMessageID[message.id] {
                    ForEach(contexts) { context in
                        outgoingContinuationLinkRow(context)
                    }
                }
            }

            ForEach(unanchoredOutgoingContinuationContexts) { context in
                outgoingContinuationLinkRow(context)
            }

            if let progress = viewModel.attachmentImportProgress {
                WatchAttachmentImportProgressRowView(progress: progress)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
            }

            ForEach(viewModel.pendingImageAttachments) { attachment in
                WatchPendingAttachmentRowView(
                    systemImage: "photo",
                    title: NSLocalizedString("图片文件", comment: ""),
                    fileName: attachment.fileName,
                    tint: .green
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel.removePendingImageAttachment(attachment)
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete pending attachment action"), systemImage: "trash")
                    }
                }
            }

            if let audio = viewModel.pendingAudioAttachment {
                WatchPendingAttachmentRowView(
                    systemImage: "waveform",
                    title: NSLocalizedString("语音文件", comment: ""),
                    fileName: audio.fileName,
                    tint: .blue
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel.clearPendingAudioAttachment()
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete pending attachment action"), systemImage: "trash")
                    }
                }
            }

            ForEach(viewModel.pendingFileAttachments) { attachment in
                let isVideo = VideoAttachmentSupport.isVideo(attachment)
                WatchPendingAttachmentRowView(
                    systemImage: isVideo ? "video" : "doc",
                    title: NSLocalizedString(isVideo ? "视频" : "文件", comment: ""),
                    fileName: attachment.fileName,
                    tint: .cyan
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel.removePendingFileAttachment(attachment)
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete pending attachment action"), systemImage: "trash")
                    }
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
                    isContextCompressionAvailable: viewModel.currentSession?.isTemporary == false
                        && (!viewModel.allMessagesForSession.isEmpty || continuationContext != nil),
                    isTemporaryChatActivationAvailable: viewModel.allMessagesForSession.isEmpty
                        && continuationContext == nil,
                    onPerformQuickAction: { action in
                        performWatchInputQuickAction(action)
                    },
                    onPerformSlashCommand: performWatchSlashCommand,
                    onShowTransientNotice: { notice in
                        showChatTransientNotice(notice)
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
                            beginWatchInputLayoutSettling(proxy: proxy)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                viewModel.beginSpeechInputFlow()
                            }
                        case .inactive:
                            break
                        }
                    },
                    onSpeechInputLayoutWillChange: {
                        beginWatchInputLayoutSettling(proxy: proxy)
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
        .modifier(WatchChatScrollStateObserverModifier { distanceToTop, distanceToBottom, isUserInteracting in
            updateWatchScrollState(
                distanceToTop: distanceToTop,
                distanceToBottom: distanceToBottom,
                isUserInteracting: isUserInteracting,
                proxy: proxy
            )
        })
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isMessageSelectionMode {
                    Button {
                        showMessageSelectionActions = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString("批量操作，已选择 %d 条消息", comment: "Selected messages batch menu accessibility label"),
                                    selectedMessageIDs.count
                                )
                            )
                    }
                } else {
                    Button {
                        viewModel.activeSheet = nil
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
        .confirmationDialog(
            String(
                format: NSLocalizedString("批量操作，已选择 %d 条消息", comment: "Selected messages batch menu accessibility label"),
                selectedMessageIDs.count
            ),
            isPresented: $showMessageSelectionActions,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("退出多选", comment: "Exit message selection mode")) {
                exitMessageSelection()
            }

            Button(NSLocalizedString("反选", comment: "Invert message selection")) {
                invertMessageSelection()
            }

            if !selectedMessageIDs.isEmpty {
                Button(NSLocalizedString("导出所选", comment: "Export selected messages")) {
                    selectedMessagesExportTarget = WatchSelectedMessagesExportNavigationTarget(
                        messageIDs: selectedMessageIDs
                    )
                }

                Button(NSLocalizedString("删除所选", comment: "Delete selected messages"), role: .destructive) {
                    showSelectedMessagesDeleteConfirm = true
                }
            }

            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            if isMessageSelectionMode {
                exitMessageSelection()
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
            let shouldScroll = shouldForceScrollToBottom || (shouldKeepBottomPinned && (isAtBottom || viewModel.isSendingMessage))
            shouldForceScrollToBottom = false
            guard shouldScroll else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: viewModel.streamingScrollAnchorVersion) { _, _ in
            guard viewModel.isSendingMessage, shouldKeepBottomPinned else { return }
            let mode = ChatStreamingDisplayMode.normalized(appConfig.chatStreamingDisplayMode)
            scrollToBottom(
                proxy: proxy,
                animated: !accessibilityReduceMotion,
                animation: .easeOut(duration: mode.viewportFollowDuration)
            )
        }
        .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
            guard newValue != nil, isAtBottom, shouldKeepBottomPinned else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: pendingJumpRequest) { _, request in
            guard let request else { return }
            scheduleWatchMessageJump(request, proxy: proxy)
        }
        .onChange(of: viewModel.pendingSearchJumpTarget) { _, _ in
            resolvePendingSearchJumpIfNeeded()
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            pendingHistoryResetWorkItem?.cancel()
            pendingHistoryResetWorkItem = nil
            automaticHistoryAnchorTask?.cancel()
            automaticHistoryAnchorTask = nil
            pendingAutomaticHistoryLoadRequest = nil
            isAutomaticHistoryLoadInFlight = false
            lastAutomaticHistoryLoadAnchorID = nil
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
                if let request = pendingJumpRequest {
                    scheduleWatchMessageJump(request, proxy: proxy)
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
            isAtBottom = true

            let shouldResetHistoryWindow = viewModel.usesManualHistoryLoading || viewModel.usesAutomaticHistoryWindow
            guard shouldResetHistoryWindow else {
                scrollToBottom(proxy: proxy, animated: true)
                return
            }

            let workItem = DispatchWorkItem {
                pendingBottomSnapTask?.cancel()
                pendingBottomSnapTask = nil
                watchInputLayoutSettleTask?.cancel()
                watchInputLayoutSettleTask = nil
                isWatchInputLayoutSettling = false
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
        proxy: ScrollViewProxy,
        animated: Bool,
        animation: Animation? = nil
    ) {
        shouldKeepBottomPinned = true
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        if animated {
            if let animation {
                withAnimation(animation) {
                    action()
                }
            } else {
                withAnimation {
                    action()
                }
            }
        } else {
            action()
        }
    }

    func performAutomaticHistoryLoad(
        proxy: ScrollViewProxy,
        request: WatchAutomaticHistoryLoadRequest
    ) {
        guard viewModel.usesAutomaticHistoryWindow,
              !isAutomaticHistoryLoadInFlight,
              lastAutomaticHistoryLoadAnchorID != request.anchorMessageID else {
            return
        }
        lastAutomaticHistoryLoadAnchorID = request.anchorMessageID
        isAutomaticHistoryLoadInFlight = true
        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
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
            return
        }

        automaticHistoryAnchorTask?.cancel()
        automaticHistoryAnchorTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(
                request.anchorMessageID,
                anchor: request.direction == .earlier ? .top : .bottom
            )
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            isAutomaticHistoryLoadInFlight = false
            automaticHistoryAnchorTask = nil
        }
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
        guard viewModel.prepareHistoryWindow(containing: targetMessageID) else { return false }
        DispatchQueue.main.async {
            pendingJumpRequest = MessageJumpRequest(messageID: targetMessageID)
        }
        return true
    }

    func scheduleWatchMessageJump(_ request: MessageJumpRequest, proxy: ScrollViewProxy) {
        Task { @MainActor in
            // List 需要先把新窗口提交到布局树，再接收 scrollTo。
            await Task.yield()
            await Task.yield()
            guard pendingJumpRequest == request else { return }
            withAnimation {
                proxy.scrollTo(request.messageID, anchor: .center)
            }
            pendingJumpRequest = nil
            shouldRestorePendingJumpOnAppear = false
        }
    }

    func prepareForMessageJump() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        watchInputLayoutSettleTask?.cancel()
        watchInputLayoutSettleTask = nil
        automaticHistoryAnchorTask?.cancel()
        automaticHistoryAnchorTask = nil
        pendingAutomaticHistoryLoadRequest = nil
        isAutomaticHistoryLoadInFlight = false
        isWatchInputLayoutSettling = false
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
        shouldKeepBottomPinned = true
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
        shouldKeepBottomPinned = true
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

    func beginWatchInputLayoutSettling(proxy: ScrollViewProxy) {
        watchInputLayoutSettleTask?.cancel()
        isWatchInputLayoutSettling = true
        shouldKeepBottomPinned = true
        showScrollToBottomButton = false
        scrollToBottom(proxy: proxy, animated: false)

        watchInputLayoutSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isWatchInputLayoutSettling = false
            if shouldKeepBottomPinned {
                scrollToBottom(proxy: proxy, animated: false)
            }
            watchInputLayoutSettleTask = nil
        }
    }

    var inputStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }

    func updateWatchScrollState(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        isUserInteracting: Bool,
        proxy: ScrollViewProxy
    ) {
        let normalizedDistance = max(distanceToBottom, 0)
        let isNearBottom = normalizedDistance < watchBottomPinnedDistanceThreshold

        if viewModel.usesAutomaticHistoryWindow, !isAutomaticHistoryLoadInFlight {
            let firstMessageID = viewModel.displayMessages.first?.id
            let lastMessageID = viewModel.displayMessages.last?.id
            if isUserInteracting,
               distanceToTop < watchAutomaticHistoryLoadTriggerDistance,
               !viewModel.isHistoryFullyLoaded,
               let firstMessageID,
               firstMessageID != lastAutomaticHistoryLoadAnchorID {
                pendingAutomaticHistoryLoadRequest = WatchAutomaticHistoryLoadRequest(
                    direction: .earlier,
                    anchorMessageID: firstMessageID
                )
            } else if isUserInteracting,
                      distanceToBottom < watchAutomaticHistoryLoadTriggerDistance,
                      !viewModel.isLaterHistoryFullyLoaded,
                      let lastMessageID,
                      lastMessageID != lastAutomaticHistoryLoadAnchorID {
                pendingAutomaticHistoryLoadRequest = WatchAutomaticHistoryLoadRequest(
                    direction: .later,
                    anchorMessageID: lastMessageID
                )
            } else if !isUserInteracting, let request = pendingAutomaticHistoryLoadRequest {
                pendingAutomaticHistoryLoadRequest = nil
                let remainsNearRequestedEdge = request.direction == .earlier
                    ? distanceToTop < watchAutomaticHistoryLoadTriggerDistance
                    : distanceToBottom < watchAutomaticHistoryLoadTriggerDistance
                if remainsNearRequestedEdge {
                    performAutomaticHistoryLoad(proxy: proxy, request: request)
                }
            }
        }

        if isNearBottom {
            bottomAnchorVisibilityWorkItem?.cancel()
            bottomAnchorVisibilityWorkItem = nil
            isAtBottom = true
            shouldKeepBottomPinned = true
            if showScrollToBottomButton {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottomButton = false
                }
            }
            return
        }

        isAtBottom = false
        if isUserInteracting, !isWatchInputLayoutSettling {
            shouldKeepBottomPinned = false
            shouldForceScrollToBottom = false
        }

        let shouldShow = normalizedDistance > watchScrollToBottomButtonRevealDistance && !shouldKeepBottomPinned
        if showScrollToBottomButton != shouldShow {
            withAnimation(.easeInOut(duration: 0.18)) {
                showScrollToBottomButton = shouldShow
            }
        }
    }
}

private struct WatchChatScrollStateObserverModifier: ViewModifier {
    let onDistanceChange: (CGFloat, CGFloat, Bool) -> Void
    @State private var isUserInteracting = false

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content
                .onScrollPhaseChange { _, newPhase, context in
                    let newIsUserInteracting = Self.isUserInitiatedScrollPhase(newPhase)
                    isUserInteracting = newIsUserInteracting
                    onDistanceChange(
                        Self.distanceToTop(from: context.geometry),
                        Self.distanceToBottom(from: context.geometry),
                        newIsUserInteracting
                    )
                }
                .onScrollGeometryChange(for: WatchChatScrollDistances.self) { geometry in
                    WatchChatScrollDistances(
                        top: Self.distanceToTop(from: geometry),
                        bottom: Self.distanceToBottom(from: geometry)
                    )
                } action: { _, newDistances in
                    onDistanceChange(newDistances.top, newDistances.bottom, isUserInteracting)
                }
        } else {
            content
        }
    }

    @available(watchOS 11.0, *)
    private static func distanceToBottom(from geometry: ScrollGeometry) -> CGFloat {
        max(geometry.contentSize.height - geometry.visibleRect.maxY, 0)
    }

    @available(watchOS 11.0, *)
    private static func distanceToTop(from geometry: ScrollGeometry) -> CGFloat {
        max(geometry.visibleRect.minY, 0)
    }

    @available(watchOS 11.0, *)
    private static func isUserInitiatedScrollPhase(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }
}

private struct WatchChatScrollDistances: Equatable {
    let top: CGFloat
    let bottom: CGFloat
}
