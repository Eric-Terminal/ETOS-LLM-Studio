// ============================================================================
// ChatViewConversation.swift
// ============================================================================
// iOS 聊天会话主体、消息列表与界面生命周期。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import ETOSCore
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

extension ChatView {
    func landscapeChatLayout(chatViewportSize: CGSize) -> some View {
        let chatViewportWidth = max(1, chatViewportSize.width)
        let expandedSidebarWidth = landscapeSessionSidebarWidth(for: chatViewportWidth)
        let sidebarWidth = isLandscapeSessionSidebarPresented ? expandedSidebarWidth : 0
        let detailWidth = max(1, chatViewportWidth - sidebarWidth)

        return ZStack {
            telegramBackgroundLayer
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if isLandscapeSessionSidebarPresented {
                    landscapeSessionSidebar
                        .frame(width: expandedSidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .trailing) {
                            Color(uiColor: .separator)
                                .frame(width: 0.5)
                                .frame(maxHeight: .infinity)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                chatConversationContent(
                    chatViewportWidth: detailWidth,
                    chatViewportSize: CGSize(width: detailWidth, height: chatViewportSize.height),
                    showsBackground: false
                )
                .frame(width: detailWidth)
                .frame(maxHeight: .infinity)
            }
            .frame(width: chatViewportWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
    }

    func landscapeSessionSidebarWidth(for viewportWidth: CGFloat) -> CGFloat {
        min(
            landscapeSessionSidebarMaxWidth,
            max(landscapeSessionSidebarMinWidth, viewportWidth * landscapeSessionSidebarWidthRatio)
        )
    }

    @ViewBuilder
    func chatConversationContent(
        chatViewportWidth: CGFloat,
        chatViewportSize: CGSize,
        showsBackground: Bool = true
    ) -> some View {
        let displayedMessages = viewModel.displayMessages
        let sessionMessages = viewModel.allMessagesForSession
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: sessionMessages,
            isSending: viewModel.isSendingMessage
        )
        let messageLayoutWidth = max(1, chatViewportWidth - 16)
        let reasoningPreviewMaxHeight = responsiveReasoningPreviewMaxHeight(for: chatViewportSize.height)
        ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                if showsBackground {
                    telegramBackgroundLayer
                        .ignoresSafeArea()
                }

                // Z-Index 1: 消息列表
                ScrollViewReader { chatScrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChatScrollMetricsObserver(
                            keepsBottomPinned: scrollCoordinator.keepsBottomPinnedBinding,
                            isStreaming: viewModel.isSendingMessage,
                            streamingDisplayMode: ChatStreamingDisplayMode.normalized(
                                appConfig.chatStreamingDisplayMode
                            ),
                            reduceMotion: accessibilityReduceMotion,
                            metricsRefreshGeneration: scrollCoordinator.bottomScrollCommandGeneration,
                            metricThresholds: ChatScrollMetricThresholds(
                                arrival: bottomScrollCommandArrivalTolerance,
                                bottomPinned: bottomPinnedDistanceThreshold,
                                bottomButton: scrollToBottomButtonRevealDistance,
                                historyLoading: automaticHistoryLoadTriggerDistance
                            ),
                            isViewportTransitioning: scrollCoordinator.isChatLayoutSettling,
                            hasProgrammaticScrollCommand: hasChatProgrammaticScrollOwnership,
                            anchorAdjustment: pendingChatAnchorAdjustment,
                            onAnchorAdjustmentApplied: { adjustmentID in
                                completeChatAnchorAdjustment(id: adjustmentID)
                            },
                            onUserPanBegan: {
                                handleChatScrollPanBegan()
                            }
                        ) { distanceToBottom, distanceToTop, isUserInteracting in
                            handleChatScrollMetrics(
                                distanceToBottom: distanceToBottom,
                                distanceToTop: distanceToTop,
                                isUserInteracting: isUserInteracting
                            )
                        }
                        .frame(width: 0, height: 0)

                        LazyVStack(spacing: 0) {
                            // 顶部留白（为导航栏留出空间）
                            Color.clear
                                .frame(height: 8)
                                .id(ChatScrollTargetID.top)

                            // 历史加载提示
                            historyBanner

                            if let continuationContext,
                               !continuationContext.isSourceSessionLinkHidden {
                                ConversationContinuationLinkBubble(
                                    kind: .sourceSession,
                                    linkedSessionName: continuationSourceSessionName(
                                        for: continuationContext
                                    ),
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
                                .id(continuationContext.id)
                            }

                            if let continuationContext {
                                ConversationContinuationBubble(
                                    context: continuationContext,
                                    expansionState: $continuationExpansionState,
                                    enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
                                    enableBackground: viewModel.enableBackground,
                                    enableLiquidGlass: isLiquidGlassEnabled,
                                    enableNoBubbleUI: viewModel.enableNoBubbleUI,
                                    onExpansionStateChange: handleContinuationExpansionStateChange
                                )
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                            }

                            // 消息列表
                            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, state in
                                let message = state.message
                                let previousMessage = index > 0 ? displayedMessages[index - 1].message : nil
                                let nextMessage = index + 1 < displayedMessages.count ? displayedMessages[index + 1].message : nil
                                let mergeWithPrevious = shouldMergeTurnMessages(previousMessage, with: message)
                                let mergeWithNext = shouldMergeTurnMessages(message, with: nextMessage)
                                let messageActionBarContinuesToNext = shouldContinueMessageActionBar(message, with: nextMessage)
                                let connectsTimelineFromPrevious = shouldConnectTimeline(previousMessage, with: message)
                                let connectsTimelineToNext = shouldConnectTimeline(message, with: nextMessage)
                                let showsStreamingIndicators = viewModel.isSendingMessage && viewModel.latestAssistantMessageID == message.id
                                // 贴底流式气泡只跟随真实滚动偏移，避免相位弹簧与吸底校正互相拉扯。
                                let isBottomPinnedStreamingBubble = showsStreamingIndicators && scrollCoordinator.shouldKeepBottomPinned
                                let reportsSendFlightTarget = isSendFlightTarget(message.id)
                                let sendFlightOpacity = sendFlightMessageOpacity(for: message)
                                let preparedMarkdownPayload = viewModel.preparedMarkdownByMessageID[message.id]
                                let preparedReasoningMarkdownPayload = viewModel.preparedReasoningMarkdownByMessageID[message.id]
                                let layoutIntegrityMetadata: ChatMessageLayoutMetadata? = if
                                    shouldReportChatViewportLayoutFrames
                                {
                                    ChatMessageLayoutMetadata(
                                        role: message.role.rawValue,
                                        contentUTF8Length: preparedMarkdownPayload?.sourceUTF8Length ?? 0,
                                        reasoningUTF8Length:
                                            preparedReasoningMarkdownPayload?.sourceUTF8Length ?? 0,
                                        isAwaitingStaticHandoff: state.streamingMarkdownState
                                            .isAwaitingStaticHandoff(channel: .content)
                                            || state.streamingMarkdownState
                                                .isAwaitingStaticHandoff(channel: .reasoning),
                                        hasPreparedMarkdown: preparedMarkdownPayload != nil,
                                        hasPreparedReasoningMarkdown: preparedReasoningMarkdownPayload != nil,
                                        layoutRevision: state.layoutRevision,
                                        recoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.recoveryRevision(for: message.id),
                                        rendererHandoffRevision: state.rendererHandoffRevision,
                                        rendererHandoffAt: state.lastRendererHandoffAt,
                                        usesNoBubbleStyle: viewModel.enableNoBubbleUI
                                            && message.role != .error
                                            && !(message.role == .user && message.authorKind == .user),
                                        contentRenderer: ChatBubbleRendererIdentity.resolved(
                                            hasContent: !message.content.isEmpty,
                                            enableMarkdown: viewModel.enableMarkdown,
                                            isStreaming: showsStreamingIndicators,
                                            isAwaitingStaticHandoff: state.streamingMarkdownState
                                                .isAwaitingStaticHandoff(channel: .content),
                                            hasPreparedMarkdown: preparedMarkdownPayload != nil,
                                            usesWebRenderer: viewModel.enableAdvancedRenderer
                                                && preparedMarkdownPayload?.containsMermaidContent == true,
                                            hasRoleplayHTML: state.roleplayHTML?.containsHTML == true
                                        ),
                                        reasoningRenderer: ChatBubbleRendererIdentity.resolved(
                                            hasContent: !(message.reasoningContent?.isEmpty ?? true),
                                            enableMarkdown: viewModel.enableMarkdown,
                                            isStreaming: showsStreamingIndicators,
                                            isAwaitingStaticHandoff: state.streamingMarkdownState
                                                .isAwaitingStaticHandoff(channel: .reasoning),
                                            hasPreparedMarkdown: preparedReasoningMarkdownPayload != nil,
                                            usesWebRenderer: viewModel.enableAdvancedRenderer
                                                && preparedReasoningMarkdownPayload?.containsMermaidContent == true
                                        ),
                                        layoutWidthBucket: ChatBubbleLayoutIdentity.widthBucket(
                                            for: messageLayoutWidth
                                        )
                                    )
                                } else {
                                    nil
                                }
                                ChatBubble(
                                    messageState: state,
                                    roleplaySessionID: viewModel.currentSession?.id,
                                    roleplayMessages: sessionMessages,
                                    layoutWidth: messageLayoutWidth,
                                    reasoningPreviewMaxHeight: reasoningPreviewMaxHeight,
                                    preparedMarkdownPayload: preparedMarkdownPayload,
                                    preparedReasoningMarkdownPayload: preparedReasoningMarkdownPayload,
                                    reasoningThinkingTitle: viewModel.reasoningThinkingTitleByMessageID[message.id],
                                    isReasoningExpanded: Binding(
                                        get: { viewModel.reasoningExpandedState[message.id, default: false] },
                                        set: { isExpanded in
                                            viewModel.setReasoningExpanded(isExpanded, for: message.id)
                                            if isExpanded {
                                                scrollCoordinator.shouldKeepBottomPinned = false
                                            }
                                        }
                                    ),
                                    isReasoningAutoPreview: viewModel.isAutoReasoningPreview(for: message.id),
                                    isToolCallsExpanded: Binding(
                                        get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                                        set: { isExpanded in
                                            viewModel.toolCallsExpandedState[message.id] = isExpanded
                                            if isExpanded {
                                                scrollCoordinator.shouldKeepBottomPinned = false
                                            }
                                        }
                                    ),
                                    enableMarkdown: viewModel.enableMarkdown,
                                    enableBackground: viewModel.enableBackground,
                                    enableLiquidGlass: isLiquidGlassEnabled,
                                    enableNoBubbleUI: viewModel.enableNoBubbleUI,
                                    enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
                                    enableExperimentalToolResultDisplay: true,
                                    enableMathRendering: viewModel.enableAdvancedRenderer,
                                    showsStreamingIndicators: showsStreamingIndicators,
                                    mergeWithPrevious: mergeWithPrevious,
                                    mergeWithNext: mergeWithNext,
                                    messageActionBarContinuesToNext: messageActionBarContinuesToNext,
                                    connectsTimelineFromPrevious: connectsTimelineFromPrevious,
                                    connectsTimelineToNext: connectsTimelineToNext,
                                    responseAttemptVersionInfo: viewModel.responseAttemptVersionInfo(for: message),
                                    hasAutoOpenedPendingToolCall: { toolCallID in
                                        viewModel.hasAutoOpenedPendingToolCall(toolCallID)
                                    },
                                    markPendingToolCallAutoOpened: { toolCallID in
                                        viewModel.markPendingToolCallAutoOpened(toolCallID)
                                    },
                                    canRetry: retryableMessageIDs.contains(message.id),
                                    onRetry: {
                                        performDeferredRetry(message)
                                    },
                                    onCopy: {
                                        UIPasteboard.general.string = state.message.content
                                    },
                                    onSwitchToPreviousVersion: {
                                        viewModel.switchToPreviousVersion(of: message)
                                    },
                                    onSwitchToNextVersion: {
                                        viewModel.switchToNextVersion(of: message)
                                    },
                                    isSelectionMode: isMessageSelectionMode,
                                    isSelected: selectedMessageIDs.contains(message.id),
                                    onToggleSelection: {
                                        toggleMessageSelection(message.id)
                                    },
                                    onOpenMore: { latestMessage in
                                        messageActionSheetPayload = MessageActionSheetPayload(message: latestMessage)
                                    },
                                    onDownloadImageAttachment: { fileName in
                                        Task {
                                            await downloadImagesToPhotoLibrary(fileNames: [fileName])
                                        }
                                    },
                                    onDeleteImageAttachment: { fileName in
                                        viewModel.removeImageAttachment(
                                            fileName: fileName,
                                            fromMessageID: message.id
                                        )
                                    },
                                    sourceConversationName: message.sourceSessionID.flatMap { sourceSessionID in
                                        viewModel.chatSessions.first(where: { $0.id == sourceSessionID })?.name
                                    },
                                    onOpenSourceConversation: message.sourceSessionID.map { sourceSessionID in
                                        { _ = viewModel.setCurrentSessionIfExists(sessionID: sourceSessionID) }
                                    },
                                    onOpenConversation: { sessionID in
                                        _ = viewModel.setCurrentSessionIfExists(sessionID: sessionID)
                                    },
                                    reportsSendFlightTarget: reportsSendFlightTarget,
                                    reportsLayoutIntegrityFrame: scrollCoordinator.chatLayoutIntegrityMonitor
                                        .isContentFrameProbeActive,
                                    layoutRecoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.recoveryRevision(
                                        for: message.id
                                    ),
                                    providers: viewModel.providers
                                )
                                .background {
                                    ZStack {
                                        ChatHistoryAnchorFrameReporter(messageID: message.id)
                                        if let layoutIntegrityMetadata {
                                            ChatMessageLayoutFrameReporter(
                                                messageID: message.id,
                                                metadata: layoutIntegrityMetadata,
                                                probeRevision: scrollCoordinator.chatLayoutIntegrityMonitor.layoutProbeRevision,
                                                stackRecoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.stackRecoveryRevision
                                            )
                                        }
                                    }
                                }
                                // 发送入场动画：用户气泡走 Overlay 飞行（见 flightOverlayLayer），
                                // 真实气泡在飞行期间无动画隐身，避免两份白字文本叠加。
                                .transition(
                                    message.role == .user && flightState != nil
                                    ? .identity
                                    : .asymmetric(
                                        insertion: .move(edge: .bottom)
                                            .combined(with: .scale(scale: 0.92, anchor: .bottomLeading))
                                            .combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                                // 用户气泡落位前压住同轮回复，维持“发送完成后才得到响应”的视觉因果。
                                .opacity(sendFlightOpacity)
                                .allowsHitTesting(sendFlightOpacity > 0)
                                .accessibilityHidden(sendFlightOpacity == 0)
                                .id(ChatScrollTargetID.message(state.id))
                                // iMessage 风格滚动波浪：纯位置偏移驱动弹性交错
                                .scrollTransition(
                                    topLeading: .animated(.smooth(duration: 0.4)),
                                    bottomTrailing: .animated(.spring(
                                        response: appConfig.chatScrollAnimationSpringResponse,
                                        dampingFraction: appConfig.chatScrollAnimationSpringDamping
                                    ))
                                ) { [scrollAnimEnabled = appConfig.chatScrollAnimationEnabled,
                                     scrollAnimOffset = appConfig.chatScrollAnimationOffset,
                                     layoutSettling = scrollCoordinator.isChatLayoutSettling,
                                     keepsBottomPinned = scrollCoordinator.shouldKeepBottomPinned,
                                     scrollUserInteracting = scrollCoordinator.isChatScrollUserInteracting,
                                     timelineNavigationActive = appConfig.chatTimelineNavigationEnabled
                                        && (hasChatProgrammaticScrollOwnership
                                            || scrollCoordinator.messageNavigationCursorID != nil)] content, phase in
                                    content
                                        .offset(
                                            y: Self.chatScrollTransitionOffset(
                                                phaseValue: phase.value,
                                                configuredOffset: scrollAnimOffset,
                                                isEnabled: scrollAnimEnabled,
                                                isConnectedToAdjacentBubble: mergeWithPrevious || mergeWithNext,
                                                isBottomPinnedStreamingBubble: isBottomPinnedStreamingBubble,
                                                isViewportTransitioning: Self
                                                    .shouldSuppressScrollTransitionForViewportChange(
                                                        isLayoutSettling: layoutSettling,
                                                        keepsBottomPinned: keepsBottomPinned,
                                                        isUserInteracting: scrollUserInteracting
                                                    ),
                                                isTimelineNavigationActive: timelineNavigationActive
                                            )
                                        )
                                }

                                if let contexts = outgoingContinuationContextsByMessageID[message.id] {
                                    ForEach(contexts) { context in
                                        outgoingContinuationLinkBubble(context)
                                    }
                                }
                            }

                            ForEach(unanchoredOutgoingContinuationContexts) { context in
                                outgoingContinuationLinkBubble(context)
                            }

                            Color.clear
                                .frame(height: 8)
                                .id(ChatScrollTargetID.bottom)
                        }
                        .id(scrollCoordinator.chatLayoutIntegrityMonitor.stackRecoveryRevision)
                        .scrollTargetLayout()
                        .coordinateSpace(.named(ChatHistoryAnchorLayout.coordinateSpaceName))
                    }
                    .padding(.horizontal, 8)
                    // 短列表必须占满滚动视口，避免流式增长时底部锚点搬动整段内容。
                    .frame(minHeight: scrollCoordinator.chatScrollViewportHeight, alignment: .top)
                    .frame(width: chatViewportWidth, alignment: .top)
                }
                .frame(width: chatViewportWidth)
                .coordinateSpace(.named(ChatMessageLayoutAudit.coordinateSpaceName))
                .onPreferenceChange(ChatHistoryAnchorFramePreferenceKey.self) { frames in
                    scrollCoordinator.chatHistoryViewportAnchorController.updateFrames(
                        frames,
                        displayedMessageIDs: viewModel.displayMessages.map(\.id)
                    )
                }
                .onPreferenceChange(ChatMessageLayoutFramePreferenceKey.self) { frames in
                    let displayedMessageIDs = viewModel.displayMessages.map(\.id)
                    scrollCoordinator.chatLayoutIntegrityMonitor.updateSnapshot(
                        frames,
                        orderedMessageIDs: displayedMessageIDs
                    )
                    refreshMessageNavigationTargets()
                }
                .onChange(of: chatLayoutAuditContext) { _, context in
                    scrollCoordinator.chatLayoutIntegrityMonitor.updateContext(context)
                }
                .onChange(of: accessibilityVoiceOverEnabled) { _, isEnabled in
                    if isEnabled {
                        revealScrollNavigationPanel()
                    } else {
                        scheduleScrollNavigationPanelHide()
                    }
                }
                .onChange(of: scrollCoordinator.chatLayoutIntegrityMonitor.anchorScrollTargetMessageID) { oldValue, newValue in
                    if let newValue {
                        guard !scrollCoordinator.isChatScrollUserInteracting,
                              !hasExclusiveChatViewportCommand else { return }
                        scrollCoordinator.chatScrollPositionController.issueCommand(
                            to: .message(newValue),
                            anchor: .center,
                            owner: .layoutRecovery
                        )
                    } else if let oldValue {
                        scrollCoordinator.chatScrollPositionController.releaseCommand(
                            expectedTarget: .message(oldValue),
                            expectedOwner: .layoutRecovery
                        )
                    }
                }
                // 静态尺寸变化由 SwiftUI 锚定；流式增长改由 UIKit 只动画 contentOffset。
                // 两套机制不会同时接管，用户主动离底后也不会抢回阅读位置。
                .chatDefaultSizeChangeScrollAnchor(
                    Self.chatSizeChangeScrollAnchor(
                        keepsBottomPinned: scrollCoordinator.shouldKeepBottomPinned
                            && !isMessageJumpInFlight
                            && !scrollCoordinator.hasRetainedTimelineNavigationTarget,
                        isStreaming: viewModel.isSendingMessage
                    )
                )
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { newSize in
                    scrollCoordinator.chatScrollViewportWidth = newSize.width
                    scrollCoordinator.chatScrollViewportHeight = newSize.height
                    refreshMessageNavigationTargets()
                }
                .onChange(of: scrollCoordinator.chatScrollPositionController.activeCommandRevision) { _, _ in
                    consumeChatScrollCommand(using: chatScrollProxy)
                }
                .chatOnScrollIdle {
                    updateChatScrollInteractionState(false)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                .simultaneousGesture(scrollNavigationEdgeRevealGesture)
                .accessibilityActions {
                    if appConfig.chatTimelineNavigationEnabled {
                        if canNavigateToTimelineTop {
                            Button(NSLocalizedString("滚动到顶部", comment: "")) {
                                handleScrollToTopButtonTap()
                            }
                        }
                        if scrollCoordinator.previousMessageNavigationTargetID != nil {
                            Button(NSLocalizedString("滚动到上一条消息", comment: "")) {
                                handleAdjacentMessageNavigation(.previous)
                            }
                        }
                        if scrollCoordinator.nextMessageNavigationTargetID != nil {
                            Button(NSLocalizedString("滚动到下一条消息", comment: "")) {
                                handleAdjacentMessageNavigation(.next)
                            }
                        }
                        if canNavigateToTimelineBottom {
                            Button(NSLocalizedString("滚动到底部", comment: "")) {
                                handleScrollToBottomButtonTap()
                            }
                        }
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissComposerInput()
                    }
                )
                .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
                    guard newValue != nil,
                          scrollCoordinator.shouldKeepBottomPinned else { return }
                    scrollToBottom()
                }
                .onChange(of: viewModel.pendingSearchJumpTarget) { _, _ in
                    resolvePendingSearchJumpIfNeeded()
                }
                .onChange(of: viewModel.automaticHistoryLoadingEnabled) { _, _ in
                    cancelAutomaticHistoryNavigation()
                }
                .onChange(of: viewModel.lazyLoadMessageCount) { _, _ in
                    cancelAutomaticHistoryNavigation()
                }
                .onChange(of: viewModel.currentSession?.id) { _, _ in
                    cancelPendingScrollTargetCommand()
                    scrollCoordinator.resetForSessionChange()
                    shouldRestorePendingJumpOnAppear = false
                    pendingJumpRequest = nil
                    isMessageJumpInFlight = false
                    scrollCoordinator.chatLayoutIntegrityMonitor.updateContext(chatLayoutAuditContext)
                    resolvePendingSearchJumpIfNeeded()
                }
                .onChange(of: viewModel.displayMessageIdentityVersion) { _, _ in
                    handleDisplayedMessageIdentityChange()
                    refreshMessageNavigationIndex()
                    if accessibilityVoiceOverEnabled {
                        revealScrollNavigationPanel()
                    }
                }
                .onChange(of: appConfig.chatTimelineNavigationEnabled) { _, isEnabled in
                    if isEnabled {
                        refreshMessageNavigationIndex()
                        if accessibilityVoiceOverEnabled {
                            revealScrollNavigationPanel()
                        }
                    } else {
                        hideScrollNavigationPanel()
                    }
                }
                .onAppear {
                    scrollCoordinator.chatLayoutIntegrityMonitor.updateContext(chatLayoutAuditContext)
                    refreshMessageNavigationIndex()
                    if accessibilityVoiceOverEnabled {
                        revealScrollNavigationPanel()
                    }
                    if shouldRestorePendingJumpOnAppear {
                        shouldRestorePendingJumpOnAppear = false
                        resolvePendingSearchJumpIfNeeded()
                        restorePendingMessageJumpIfNeeded()
                        return
                    }
                    resolvePendingSearchJumpIfNeeded()
                    if scrollCoordinator.needsImmediateBottomSnap {
                        scrollCoordinator.shouldKeepBottomPinned = true
                        scheduleImmediateBottomSnap()
                    }
                }
                .overlay {
                    if isComposerRequestControlsExpanded {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismissComposerInput)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .top) {
                    if viewModel.enableChatTopBlurFade {
                        navBarFadeBlurOverlay
                    }
                }
                // Telegram 风格：顶部导航栏
                .safeAreaInset(edge: .top) {
                    telegramNavBar
                        .frame(width: chatViewportWidth)
                }
                // Telegram 风格：底部输入栏
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        if LocalLinuxChatPreviewPlacement.normalized(appConfig.localLinuxChatPreviewPlacement) == .aboveInput {
                            LocalLinuxChatDockedPreview(
                                mode: LocalLinuxChatPreviewMode
                                    .normalized(appConfig.localLinuxChatPreviewMode)
                                    .resolved(for: currentLocalAgentMode),
                                isLocalLinuxEnabled: appConfig.localLinuxEnabled,
                                agentToolPreview: viewModel.latestAgentToolExecutionPreview,
                                isLiquidGlassEnabled: isLiquidGlassEnabled,
                                onOpenTerminal: { jobID in
                                    localTerminalInitialJobID = jobID
                                    navigationDestination = .localTerminal
                                },
                                onOpenBrowser: {
                                    navigationDestination = .browser
                                }
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                        }

                        telegramInputBar
                        RoleplayScriptButtonBar(sessionID: viewModel.currentSession?.id)
                    }
                        .animation(
                            accessibilityReduceMotion
                                ? nil
                                : .spring(response: 0.32, dampingFraction: 1),
                            value: appConfig.localLinuxChatPreviewPlacement
                        )
                        .frame(width: chatViewportWidth)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChatInputBarHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                        // 按钮锚定整个底部输入区顶部，角色脚本栏出现时与输入框同步上移。
                        .overlay(alignment: .topTrailing) {
                            if appConfig.chatTimelineNavigationEnabled
                                && scrollCoordinator.showScrollNavigationPanel
                                && canPresentExpandedScrollNavigationPanel {
                                telegramScrollNavigationButtons
                                .padding(.trailing, 16)
                                .offset(y: -(scrollNavigationPanelHeight + scrollToBottomButtonInputSpacing))
                                .transition(scrollNavigationPanelTransition)
                            } else if scrollCoordinator.showScrollToBottom || (
                                appConfig.chatTimelineNavigationEnabled
                                    && scrollCoordinator.showScrollNavigationPanel
                                    && canNavigateToTimelineBottom
                            ) {
                                telegramScrollToBottomButton(isEnabled: canNavigateToTimelineBottom) {
                                    handleScrollToBottomButtonTap()
                                }
                                .padding(.trailing, 16)
                                .offset(y: -(scrollNavigationButtonHitSize + scrollToBottomButtonInputSpacing))
                                .transition(scrollNavigationPanelTransition)
                            }
                        }
                }
                .onPreferenceChange(ChatInputBarHeightPreferenceKey.self) { newHeight in
                    handleChatInputBarHeightChange(newHeight)
                }
                }

                if selectedChatQuickActions.count > 1 {
                    chatQuickActionFolderOverlay(viewportWidth: chatViewportWidth)
                        .zIndex(40)
                }

                if shouldShowLocalResourceUsageFloatingPanel {
                    LocalResourceUsageFloatingPanel(
                        containerSize: chatViewportSize,
                        topPadding: navBarHeight + 12,
                        leadingPadding: 16,
                        offset: $localResourceUsagePanelOffset,
                        isLiquidGlassEnabled: isLiquidGlassEnabled
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(24)
                }

                if LocalLinuxChatPreviewPlacement.normalized(appConfig.localLinuxChatPreviewPlacement) == .floating {
                    LocalLinuxChatFloatingPreview(
                        mode: LocalLinuxChatPreviewMode
                            .normalized(appConfig.localLinuxChatPreviewMode)
                            .resolved(for: currentLocalAgentMode),
                        isLocalLinuxEnabled: appConfig.localLinuxEnabled,
                        agentToolPreview: viewModel.latestAgentToolExecutionPreview,
                        sessionID: viewModel.currentSession?.id,
                        containerSize: chatViewportSize,
                        topPadding: navBarHeight + 12,
                        bottomPadding: max(16, chatInputBarHeight + 16),
                        offset: $localTerminalPreviewOffset,
                        isLiquidGlassEnabled: isLiquidGlassEnabled,
                        onOpenTerminal: { jobID in
                            localTerminalInitialJobID = jobID
                            navigationDestination = .localTerminal
                        },
                        onOpenBrowser: {
                            navigationDestination = .browser
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(25)
                }

                VStack {
                    Spacer()
                    TTSFloatingController()
                }
                .animation(.easeInOut(duration: 0.2), value: ttsManager.isSpeaking)

                if let notice = viewModel.memoryRetryStoppedNoticeMessage {
                    VStack {
                        memoryRetryStoppedNoticeBanner(text: notice)
                            .padding(.top, 12)
                            .padding(.horizontal, 12)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
                }

                if let notice = chatTransientNotice {
                    VStack {
                        Spacer()
                        chatTransientNoticeBanner(notice)
                            .padding(.horizontal, 16)
                            .padding(.bottom, chatInputBarHeight + 12)
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(35)
                }

                // 发送飞行气泡覆盖层：从输入框变形飞入落点气泡（置于最顶层）
                flightOverlayLayer

                RoleplaySessionScriptHost(
                    sessionID: viewModel.currentSession?.id,
                    messageID: displayedMessages.last?.message.id,
                    versionIndex: displayedMessages.last?.message.getCurrentVersionIndex() ?? 0,
                    chatMessages: sessionMessages
                )
            }
            .coordinateSpace(.named(ChatView.flightCoordinateSpace))
            .onPreferenceChange(InputBarRectKey.self) { rect in
                handleInputBarRect(rect)
            }
            .onPreferenceChange(FlightTargetRectKey.self) { rect in
                handleFlightTargetRect(rect)
            }
            .onChange(of: viewModel.displayMessageIdentityVersion) { _, _ in
                // 自动历史窗口可能保持消息数量不变，只替换可见消息身份；用身份版本避免漏锁飞行目标。
                lockFlightTargetIfNeeded()
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SafeAreaBottomKey.self, value: proxy.safeAreaInsets.bottom)
                }
            )
            .onPreferenceChange(SafeAreaBottomKey.self) { newValue in
                bottomSafeAreaInset = newValue
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                beginChatLayoutSettling(
                    keepBottomPinned: resolvedBottomPinIntentForViewportChange()
                )
                if !isKeyboardVisible {
                    isKeyboardVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                beginChatLayoutSettling(
                    keepBottomPinned: resolvedBottomPinIntentForViewportChange()
                )
                if isKeyboardVisible {
                    isKeyboardVisible = false
                }
            }
            .onDisappear {
                scrollCoordinator.prepareForDisappearance()
                if isMessageJumpInFlight,
                   case .message(let messageID)? = scrollCoordinator.chatScrollPositionController.activeCommandTarget {
                    pendingJumpRequest = MessageJumpRequest(messageID: messageID)
                    shouldRestorePendingJumpOnAppear = true
                } else if isMessageJumpInFlight {
                    pendingJumpRequest = nil
                    shouldRestorePendingJumpOnAppear = false
                    isMessageJumpInFlight = false
                }
                cancelPendingScrollTargetCommand(preservingMessageJump: true)
                pendingFlightCleanupTask?.cancel()
                pendingFlightCleanupTask = nil
                chatTransientNoticeDismissTask?.cancel()
                chatTransientNoticeDismissTask = nil
                chatTransientNotice = nil
                flightState = nil
                flightPresentationX = 0
                flightPresentationY = 0
                flightPresentationWidth = 0
                flightPresentationHeight = 0
                flightVisualProgress = 0
                flightHandoffProgress = 0
                flightReplyRevealProgress = 0
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
        }
    }
