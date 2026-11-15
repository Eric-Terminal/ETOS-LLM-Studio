// ============================================================================
// ChatViewConversation.swift
// ============================================================================
// iOS 聊天会话主体、消息列表与界面生命周期。
// ============================================================================

import SwiftUI
import Foundation
import Combine
import MarkdownUI
import ETOSCore
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

private struct ChatMessageStackIdentity: Hashable {
    let viewportRevision: UInt
    let recoveryRevision: UInt
}

extension ChatView {
    func adaptiveConversationLayout(layout: ChatAdaptiveLayout) -> some View {
        ZStack {
            telegramBackgroundLayer
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if layout.sidebarWidth > 0 {
                    landscapeSessionSidebar
                        .frame(width: layout.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .trailing) {
                            Color(uiColor: .separator)
                                .frame(width: 0.5)
                                .frame(maxHeight: .infinity)
                        }
                    Color.clear.frame(width: layout.sidebarGap)
                }

                chatConversationContent(
                    chatViewportWidth: layout.detailWidth,
                    chatViewportSize: CGSize(width: layout.detailWidth, height: layout.size.height),
                    composerWidth: layout.composerWidth,
                    composerOnLeadingSide: layout.composerOnLeadingSide,
                    composerHeightLimit: layout.composerHeightLimit,
                    composerBottomInset: layout.composerBottomInset
                )
                .frame(width: layout.detailWidth)
                .frame(maxHeight: .infinity)
            }
            .frame(width: layout.size.width, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func chatConversationContent(
        chatViewportWidth: CGFloat,
        chatViewportSize: CGSize,
        composerWidth: CGFloat,
        composerOnLeadingSide: Bool,
        composerHeightLimit: CGFloat,
        composerBottomInset: CGFloat
    ) -> some View {
        let displayedMessages = viewModel.displayMessages
        let sessionMessages = viewModel.allMessagesForSession
        let retryableMessageIDs = viewModel.retryableMessageIDs
        let messageLayoutWidth = max(1, chatViewportWidth - 16)
        let reasoningPreviewMaxHeight = responsiveReasoningPreviewMaxHeight(for: chatViewportSize.height)
        let composerAvailableHeight = max(0, min(composerHeightLimit, chatViewportSize.height
            - (usesSystemChatToolbar ? 0 : navBarHeight)) - 8)
        ZStack {
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
                            viewportPageRequest: scrollCoordinator.pendingViewportPageRequest,
                            onViewportPageRequestCompleted: { requestID in
                                scrollCoordinator.completeViewportPageRequest(id: requestID)
                            },
                            onUserPanBegan: {
                                cancelSendFlight()
                                handleChatScrollPanBegan()
                            },
                            isViewportActive: isChatVisible && scenePhase == .active,
                            layoutTransitionRevision: scrollCoordinator.layoutTransitionRevision,
                            onViewportLayoutSettled: { revision in
                                scrollCoordinator.completeLayoutTransition(revision: revision)
                            },
                            onStreamingFollowActivityChange: { isActive in
                                if scrollCoordinator.isStreamingViewportFollowing != isActive {
                                    scrollCoordinator.isStreamingViewportFollowing = isActive
                                }
                            },
                            timelineEdgeNavigationEnabled: appConfig.chatTimelineNavigationEnabled,
                            onTimelineEdgeReveal: {
                                guard !scrollCoordinator.showScrollNavigationPanel else { return }
                                revealScrollNavigationPanel()
                            },
                            onTimelineEdgeGestureEnded: {
                                guard scrollCoordinator.showScrollNavigationPanel else { return }
                                scheduleScrollNavigationPanelHide()
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

                            // 较早消息保留懒布局；最后一行在下方独立立即布局。
                            ForEach(Array(displayedMessages.dropLast().enumerated()), id: \.element.id) { index, _ in
                                chatMessageRow(
                                    index: index,
                                    displayedMessages: displayedMessages,
                                    sessionMessages: sessionMessages,
                                    retryableMessageIDs: retryableMessageIDs,
                                    layoutWidth: messageLayoutWidth,
                                    reasoningPreviewMaxHeight: reasoningPreviewMaxHeight
                                )
                            }
                        }
                        .id(ChatMessageStackIdentity(
                            viewportRevision: scrollCoordinator.messageStackRevision,
                            recoveryRevision: scrollCoordinator.chatLayoutIntegrityMonitor.stackRecoveryRevision
                        ))
                        .scrollTargetLayout()

                        // 新回复和真正底部始终实例化，原生贴底不会落入懒布局的空白估算区。
                        VStack(spacing: 0) {
                            if let lastIndex = displayedMessages.indices.last {
                                chatMessageRow(
                                    index: lastIndex,
                                    displayedMessages: displayedMessages,
                                    sessionMessages: sessionMessages,
                                    retryableMessageIDs: retryableMessageIDs,
                                    layoutWidth: messageLayoutWidth,
                                    reasoningPreviewMaxHeight: reasoningPreviewMaxHeight
                                )
                            }

                            ForEach(unanchoredOutgoingContinuationContexts) { context in
                                outgoingContinuationLinkBubble(context)
                            }

                            Color.clear
                                .frame(height: 8)
                                .id(ChatScrollTargetID.bottom)
                        }
                        .scrollTargetLayout()
                    }
                    .coordinateSpace(.named(ChatHistoryAnchorLayout.coordinateSpaceName))
                    .padding(.horizontal, 8)
                    // 短列表必须占满滚动视口，避免流式增长时底部锚点搬动整段内容。
                    .frame(minHeight: scrollCoordinator.chatScrollViewportHeight, alignment: .top)
                    .frame(width: chatViewportWidth, alignment: .top)
                }
                .frame(width: chatViewportWidth)
                .background(ChatSendFlightLayoutAnchor(controller: sendFlightController, region: .viewport))
                .coordinateSpace(.named(ChatMessageLayoutAudit.coordinateSpaceName))
                .onPreferenceChange(ChatHistoryAnchorFramePreferenceKey.self) { frames in
                    let controller = scrollCoordinator.chatHistoryViewportAnchorController
                    let displayedMessageIDs = viewModel.displayMessages.map(\.id)
                    controller.updateFrames(
                        frames,
                        displayedMessageIDs: displayedMessageIDs
                    )
                    if let anchorID = controller.takeAnchorRealizationRequest(displayedMessageIDs: displayedMessageIDs) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            chatScrollProxy.scrollTo(ChatScrollTargetID.message(anchorID), anchor: .top)
                        }
                    }
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
                        isStreaming: viewModel.isSendingMessage,
                        isStreamingViewportFollowing: scrollCoordinator.isStreamingViewportFollowing
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
                .accessibilityActions {
                    if appConfig.chatTimelineNavigationEnabled {
                        if canNavigateToTimelineTop {
                            Button(NSLocalizedString("滚动到顶部", comment: "")) {
                                handleScrollToTopButtonTap()
                            }
                        }
                        if canNavigateOnePageUp {
                            Button(NSLocalizedString("上一页", comment: "")) {
                                handleViewportPageNavigation(.upward)
                            }
                        }
                        if canNavigateOnePageDown {
                            Button(NSLocalizedString("下一页", comment: "")) {
                                handleViewportPageNavigation(.downward)
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
                    cancelSendFlight()
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
                    if viewModel.enableChatTopBlurFade && !usesSystemChatToolbar {
                        navBarFadeBlurOverlay
                    }
                }
                // Telegram 风格：顶部导航栏
                .safeAreaInset(edge: .top) {
                    if !usesSystemChatToolbar {
                        telegramNavBar
                            .frame(width: chatViewportWidth)
                    }
                }
                // Telegram 风格：底部输入栏
                .safeAreaInset(edge: .bottom) {
                    ChatInputDock(maximumHeight: composerAvailableHeight) {
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

                            telegramInputBar(
                                availableSize: CGSize(width: composerWidth, height: composerAvailableHeight)
                            )
                            RoleplayScriptButtonBar(sessionID: viewModel.currentSession?.id)
                        }
                    }
                        .animation(
                            accessibilityReduceMotion
                                ? nil
                                : .spring(response: 0.32, dampingFraction: 1),
                            value: appConfig.localLinuxChatPreviewPlacement
                        )
                        .frame(width: composerWidth)
                        .frame(width: chatViewportWidth, alignment: composerOnLeadingSide ? .leading : .trailing)
                        .padding(.bottom, composerBottomInset)
                        .background(ChatSendFlightLayoutAnchor(controller: sendFlightController, region: .composer))
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

                if !usesSystemChatToolbar && selectedChatQuickActions.count > 1 {
                    chatQuickActionFolderOverlay(viewportWidth: chatViewportWidth)
                        .zIndex(40)
                }

                if shouldShowLocalResourceUsageFloatingPanel {
                    LocalResourceUsageFloatingPanel(
                        containerSize: chatViewportSize,
                        topPadding: (usesSystemChatToolbar ? 0 : navBarHeight) + 12,
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
                        topPadding: (usesSystemChatToolbar ? 0 : navBarHeight) + 12,
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
            .environment(\.chatSendFlightSources, sendFlightSources)
            .environment(\.chatSendFlightController, sendFlightController)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelSendFlight() }
            }
            .onChange(of: accessibilityReduceMotion) { _, isEnabled in
                if isEnabled { cancelSendFlight() }
            }
            .onPreferenceChange(FlightTargetRectKey.self) { rect in
                handleFlightTargetRect(rect)
            }
            .background(ChatTranscriptSourceWindowReader(source: transcriptSourceWindow))
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                beginChatLayoutSettling(
                    keepBottomPinned: resolvedBottomPinIntentForViewportChange(),
                    awaitsKeyboardCompletion: true
                )
                if !isKeyboardVisible {
                    isKeyboardVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                beginChatLayoutSettling(
                    keepBottomPinned: resolvedBottomPinIntentForViewportChange(),
                    awaitsKeyboardCompletion: true
                )
                if isKeyboardVisible {
                    isKeyboardVisible = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
                beginChatLayoutSettling(
                    keepBottomPinned: resolvedBottomPinIntentForViewportChange(),
                    awaitsKeyboardCompletion: true
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)
                    .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification))
                    .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification))
            ) { _ in
                scrollCoordinator.keyboardLayoutTransitionDidEnd()
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
                cancelSendFlight()
                chatTransientNoticeDismissTask?.cancel()
                chatTransientNoticeDismissTask = nil
                chatTransientNotice = nil
            }
            .toolbar(usesSystemChatToolbar ? .visible : .hidden, for: .navigationBar)
            .navigationTitle(viewModel.currentSession?.name ?? NSLocalizedString("新的对话", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ChatNavigationSubtitle(modelName: modelSubtitle, isEnabled: usesSystemChatToolbar))
            .toolbar {
                if #available(iOS 27.1, *), usesSystemChatToolbar {
                    adaptiveChatToolbar
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
        }
    }
