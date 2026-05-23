// ============================================================================
// ChatView.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天主界面 (iOS) - Telegram 风格
// - Telegram 风格的顶部导航栏（标题 + 副标题）
// - Telegram 风格的底部输入栏（圆角输入框 + 附件 + 发送按钮）
// - 支持壁纸背景、消息气泡
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var appConfig = AppConfigStore.shared
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject var ttsManager = TTSManager.shared
    @State var showScrollToBottom = false
    @State var suppressAutoScrollOnce = false
    @State var navigationDestination: ChatNavigationDestination?
    @State var editingMessage: ChatMessage?
    @State var messageInfo: MessageInfoPayload?
    @State var showBranchOptions = false
    @State var messageToBranch: ChatMessage?
    @State var messageToDelete: ChatMessage?
    @State var messageVersionToDelete: MessageVersionDeletePayload?
    @State var messageActionSheetPayload: MessageActionSheetPayload?
    @State var fullErrorContent: FullErrorContentPayload?
    @State var showModelPickerPanel = false
    @State var showSessionPickerPanel = false
    @State var editingSessionID: UUID?
    @State var sessionDraftName: String = ""
    @State var sessionToDelete: ChatSession?
    @State var sessionInfo: SessionPickerInfoPayload?
    @State var showGhostSessionAlert = false
    @State var ghostSession: ChatSession?
    @State var sessionPickerSearchText: String = ""
    @State var sessionPickerSearchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var isSessionPickerSearching: Bool = false
    @State var sessionPickerLatestSearchToken: Int = 0
    @State var sessionPickerPendingSearchWorkItem: DispatchWorkItem?
    @State var showSessionPickerSearchInput: Bool = false
    @State var loadedSessionPickerSessions: [ChatSession] = []
    @State var loadedSessionPickerSearchResults: [SessionHistorySearchResult] = []
    @State var isLoadingMoreSessionPickerSessions: Bool = false
    @State var isLoadingMoreSessionPickerSearchResults: Bool = false
    @State var pendingLoadMoreSessionPickerSessionsTask: Task<Void, Never>?
    @State var pendingLoadMoreSessionPickerSearchResultsTask: Task<Void, Never>?
    @State var imageDownloadAlertMessage: String?
    @State var exportSharePayload: ChatExportSharePayload?
    @State var exportErrorMessage: String?
    @State var activeChatPickerSheet: ChatPickerSheet?
    @State var isChatLayoutLandscape = false
    @State var isLandscapeSessionSidebarPresented = true
    @State var modelPickerRequestControl: ModelRequestBodyControl?
    @State var showAllModelsInPicker = false
    @State var bottomSafeAreaInset: CGFloat = 0
    @State var isKeyboardVisible = false
    @State var chatInputBarHeight: CGFloat = 0
    @State var scrollDistanceToBottom: CGFloat = 0
    @State var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var chatScrollTarget: ChatScrollTargetID?
    @State var chatScrollTargetAnchor: UnitPoint = .bottom
    @State var needsImmediateBottomSnap: Bool = true
    @State var shouldRestorePendingJumpOnAppear: Bool = false
    @State var pendingJumpRequest: MessageJumpRequest?
    @FocusState var composerFocused: Bool
    @FocusState var sessionPickerSearchFocused: Bool
    @Namespace var modelPickerNamespace
    @Namespace var sessionPickerNamespace

    var draftText: String {
        get { appConfig.chatComposerDraft }
        nonmutating set { appConfig.chatComposerDraft = newValue }
    }

    var chatPickerPresentationStyleRawValue: String {
        get { appConfig.chatPickerPresentationStyle }
        nonmutating set { appConfig.chatPickerPresentationStyle = newValue }
    }

    let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    let navBarVerticalPadding: CGFloat = 8
    let navBarPillVerticalPadding: CGFloat = 6
    let navBarPillSpacing: CGFloat = 1
    let navBarBlurFadeMinHeight: CGFloat = 44
    let navBarBlurFadeMaxHeight: CGFloat = 96
    let navBarBlurFadeHeightRatio: CGFloat = 0.06
    let modelPickerHeightRatio: CGFloat = 0.4
    let modelPickerCornerRadius: CGFloat = 24
    let modelPickerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    let scrollToBottomButtonAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.52)
    let modelPickerMorphID = "modelPickerMorph"
    let sessionPickerMorphID = "sessionPickerMorph"
    let sessionPickerHeightRatio: CGFloat = 0.6
    let sessionPickerCornerRadius: CGFloat = 26
    let landscapeSessionSidebarMinWidth: CGFloat = 220
    let landscapeSessionSidebarMaxWidth: CGFloat = 300
    let landscapeSessionSidebarWidthRatio: CGFloat = 0.32
    let sessionPickerMaxSessionsPerPage = 100
    let sessionPickerInfiniteScrollTriggerRemainingCount = 5
    let transcriptExportService = ChatTranscriptExportService()
    var scrollToBottomButtonBottomPadding: CGFloat {
        max(chatInputBarHeight + 16, 92)
    }
    var tabBarCompensation: CGFloat {
        guard !isKeyboardVisible else { return 0 }
        let measuredTabBarHeight = UITabBarController().tabBar.frame.height
        let tabBarHeight = measuredTabBarHeight > 0 ? measuredTabBarHeight : 49
        guard bottomSafeAreaInset > tabBarHeight + 8, bottomSafeAreaInset < 160 else {
            return 0
        }
        return tabBarHeight
    }
    var navBarPillHeight: CGFloat {
        navBarTitleFont.lineHeight
            + navBarSubtitleFont.lineHeight
            + navBarPillSpacing
            + navBarPillVerticalPadding * 2
    }
    var navBarHeight: CGFloat {
        navBarPillHeight + navBarVerticalPadding * 2
    }
    var navBarIconSize: CGFloat {
        navBarPillHeight
    }
    var usesLandscapeSessionSidebar: Bool {
        isChatLayoutLandscape
    }
    var isOverlayPanelPresented: Bool {
        !usesLandscapeSessionSidebar && !usesBottomSheetPickerStyle && (showModelPickerPanel || showSessionPickerPanel)
    }
    var chatPickerPresentationStyle: ChatPickerPresentationStyle {
        ChatPickerPresentationStyle.resolvedStyle(rawValue: chatPickerPresentationStyleRawValue)
    }
    var usesBottomSheetPickerStyle: Bool {
        chatPickerPresentationStyle == .bottomSheet
    }
    var isModelPickerPresented: Bool {
        usesBottomSheetPickerStyle ? activeChatPickerSheet == .model : showModelPickerPanel
    }
    var isSessionPickerPresented: Bool {
        if usesLandscapeSessionSidebar {
            return isLandscapeSessionSidebarPresented
        }
        return usesBottomSheetPickerStyle ? activeChatPickerSheet == .session : showSessionPickerPanel
    }
    var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    var messageDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { messageToDelete != nil },
            set: { if !$0 { messageToDelete = nil } }
        )
    }
    var messageVersionDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { messageVersionToDelete != nil },
            set: { if !$0 { messageVersionToDelete = nil } }
        )
    }
    var sessionDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    sessionToDelete = nil
                }
            }
        )
    }
    var exportErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportErrorMessage = nil
                }
            }
        )
    }
    var imageDownloadAlertPresented: Binding<Bool> {
        Binding(
            get: { imageDownloadAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    imageDownloadAlertMessage = nil
                }
            }
        )
    }
    var navBarGlassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }
    var modelPickerPanelBaseTint: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.78)
    }
    var scrollToBottomButtonFillColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : .white
    }
    var scrollToBottomButtonIconColor: Color {
        colorScheme == .dark ? .white : TelegramColors.sendButtonColor
    }
    var scrollToBottomButtonBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    var scrollToBottomButtonGlassTintColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.12)
    }
    var scrollToBottomButtonGlassStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.white.opacity(0.36)
    }
    var scrollToBottomButtonShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.3) : TelegramColors.scrollButtonShadow
    }
    var totalSessionPickerCount: Int {
        viewModel.chatSessions.count
    }
    var sessionPickerSearchResults: [SessionHistorySearchResult] {
        SessionHistorySearchSupport.flattenedResults(
            sessions: viewModel.chatSessions,
            hits: sessionPickerSearchHits
        )
    }
    var totalSessionPickerSearchResultCount: Int {
        sessionPickerSearchResults.count
    }
    var hasMoreSessionPickerSessions: Bool {
        loadedSessionPickerSessions.count < totalSessionPickerCount
    }
    var hasMoreSessionPickerSearchResults: Bool {
        loadedSessionPickerSearchResults.count < totalSessionPickerSearchResultCount
    }
    func isLoadingMoreSessionPickerItems(queryActive: Bool) -> Bool {
        queryActive ? isLoadingMoreSessionPickerSearchResults : isLoadingMoreSessionPickerSessions
    }
    func hasMoreSessionPickerItems(queryActive: Bool) -> Bool {
        queryActive ? hasMoreSessionPickerSearchResults : hasMoreSessionPickerSessions
    }
    var pagedSessionPickerSessions: [ChatSession] {
        loadedSessionPickerSessions
    }
    var pagedSessionPickerSearchResults: [SessionHistorySearchResult] {
        loadedSessionPickerSearchResults
    }
    var body: some View {
        applyPresentationModifiers(to: adaptiveChatLayout)
    }

    @ViewBuilder
    var adaptiveChatLayout: some View {
        GeometryReader { proxy in
            let measuredIsLandscape = proxy.size.width > proxy.size.height
            let shouldFreezeLayout = isKeyboardVisible || composerFocused || sessionPickerSearchFocused
            let isLandscape = shouldFreezeLayout ? isChatLayoutLandscape : measuredIsLandscape
            let chatViewportWidth = max(1, proxy.size.width)

            Group {
                if isLandscape {
                    landscapeChatLayout(chatViewportWidth: chatViewportWidth)
                } else {
                    chatConversationContent(chatViewportWidth: chatViewportWidth)
                }
            }
            .onAppear {
                handleChatLayoutChange(isLandscape: isLandscape)
            }
            .onChange(of: isLandscape) { _, newValue in
                handleChatLayoutChange(isLandscape: newValue)
            }
        }
    }

    func landscapeChatLayout(chatViewportWidth: CGFloat) -> some View {
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
        showsBackground: Bool = true
    ) -> some View {
        let displayedMessages = viewModel.displayMessages
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: viewModel.allMessagesForSession,
            isSending: viewModel.isSendingMessage
        )
        let messageLayoutWidth = max(1, chatViewportWidth - 16)
        ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                if showsBackground {
                    telegramBackgroundLayer
                        .ignoresSafeArea()
                }

                // Z-Index 1: 消息列表
                ScrollView {
                    VStack(spacing: 0) {
                        ScrollDistanceToBottomObserver { distanceToBottom in
                            updateScrollToBottomVisibility(distanceToBottom: distanceToBottom)
                        }
                        .frame(width: 0, height: 0)

                        VStack(spacing: 0) {
                            // 顶部留白（为导航栏留出空间）
                            Color.clear.frame(height: 8)

                            // 历史加载提示
                            historyBanner

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
                                ChatBubble(
                                    messageState: state,
                                    layoutWidth: messageLayoutWidth,
                                    preparedMarkdownPayload: viewModel.preparedMarkdownByMessageID[message.id],
                                    preparedReasoningMarkdownPayload: viewModel.preparedReasoningMarkdownByMessageID[message.id],
                                    isReasoningExpanded: Binding(
                                        get: { viewModel.reasoningExpandedState[message.id, default: false] },
                                        set: { viewModel.setReasoningExpanded($0, for: message.id) }
                                    ),
                                    isReasoningAutoPreview: viewModel.isAutoReasoningPreview(for: message.id),
                                    isToolCallsExpanded: Binding(
                                        get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                                        set: { viewModel.toolCallsExpandedState[message.id] = $0 }
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
                                        UIPasteboard.general.string = message.content
                                    },
                                    onSwitchToPreviousVersion: {
                                        viewModel.switchToPreviousVersion(of: message)
                                    },
                                    onSwitchToNextVersion: {
                                        viewModel.switchToNextVersion(of: message)
                                    },
                                    onOpenMore: {
                                        messageActionSheetPayload = MessageActionSheetPayload(message: message)
                                    },
                                    providers: viewModel.providers
                                )
                                .id(ChatScrollTargetID.message(state.id))
                            }

                            Color.clear
                                .frame(height: 8)
                                .id(ChatScrollTargetID.bottom)
                        }
                        .scrollTargetLayout()
                    }
                    .padding(.horizontal, 8)
                    .frame(width: chatViewportWidth, alignment: .top)
                }
                .frame(width: chatViewportWidth)
                .scrollPosition(id: $chatScrollTarget, anchor: chatScrollTargetAnchor)
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        composerFocused = false
                    }
                )
                .onChange(of: viewModel.messages.count) { _, _ in
                    guard !viewModel.messages.isEmpty else {
                        showScrollToBottom = false
                        return
                    }
                    if needsImmediateBottomSnap {
                        scheduleImmediateBottomSnap()
                        return
                    }
                    if suppressAutoScrollOnce {
                        suppressAutoScrollOnce = false
                        return
                    }
                    scrollToBottom()
                }
                .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
                    guard newValue != nil, !showScrollToBottom else { return }
                    scrollToBottom()
                }
                .onChange(of: pendingJumpRequest) { _, request in
                    guard let request else { return }
                    scrollToMessage(request.messageID)
                }
                .onChange(of: viewModel.pendingSearchJumpTarget) { _, _ in
                    resolvePendingSearchJumpIfNeeded()
                }
                .onChange(of: viewModel.currentSession?.id) { _, _ in
                    pendingHistoryResetWorkItem?.cancel()
                    pendingHistoryResetWorkItem = nil
                    shouldRestorePendingJumpOnAppear = false
                    showScrollToBottom = false
                    needsImmediateBottomSnap = true
                    scheduleImmediateBottomSnap()
                    resolvePendingSearchJumpIfNeeded()
                }
                .onChange(of: viewModel.displayMessageIdentityVersion) { _, _ in
                    if needsImmediateBottomSnap, !viewModel.displayMessages.isEmpty {
                        scheduleImmediateBottomSnap()
                    }
                    resolvePendingSearchJumpIfNeeded()
                }
                .onAppear {
                    if shouldRestorePendingJumpOnAppear {
                        shouldRestorePendingJumpOnAppear = false
                        resolvePendingSearchJumpIfNeeded()
                        DispatchQueue.main.async {
                            if let request = pendingJumpRequest {
                                scrollToMessage(request.messageID)
                            }
                        }
                        return
                    }
                    resolvePendingSearchJumpIfNeeded()
                    if needsImmediateBottomSnap {
                        scheduleImmediateBottomSnap()
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
                    telegramInputBar
                        .frame(width: chatViewportWidth)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChatInputBarHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                }
                .onPreferenceChange(ChatInputBarHeightPreferenceKey.self) { newHeight in
                    chatInputBarHeight = newHeight
                }
                .overlay(alignment: .bottomTrailing) {
                    // Telegram 风格的滚动到底部按钮
                    if showScrollToBottom {
                        telegramScrollToBottomButton {
                            handleScrollToBottomButtonTap()
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, scrollToBottomButtonBottomPadding)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .allowsHitTesting(!isOverlayPanelPresented)

                VStack {
                    Spacer()
                    TTSFloatingController()
                }
                .animation(.easeInOut(duration: 0.2), value: ttsManager.isSpeaking)

                if !usesBottomSheetPickerStyle && showModelPickerPanel {
                    modelPickerOverlay
                }

                if !usesLandscapeSessionSidebar && !usesBottomSheetPickerStyle && showSessionPickerPanel {
                    sessionPickerOverlay
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
                if !isKeyboardVisible {
                    isKeyboardVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                if isKeyboardVisible {
                    isKeyboardVisible = false
                }
            }
            .onDisappear {
                pendingHistoryResetWorkItem?.cancel()
                pendingHistoryResetWorkItem = nil
                pendingBottomSnapTask?.cancel()
                pendingBottomSnapTask = nil
            }
            .onChange(of: chatPickerPresentationStyleRawValue) { _, _ in
                showModelPickerPanel = false
                showSessionPickerPanel = false
                activeChatPickerSheet = nil
                resetSessionPickerSearchState()
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
        }
    }
