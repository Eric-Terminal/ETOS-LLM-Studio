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
    @State var sessionPickerPageIndex: Int = 0
    @State var sessionPickerSearchResultPageIndex: Int = 0
    @State var imageDownloadAlertMessage: String?
    @State var exportSharePayload: ChatExportSharePayload?
    @State var exportErrorMessage: String?
    @State var activeChatPickerSheet: ChatPickerSheet?
    @State var modelPickerRequestControl: ModelRequestBodyControl?
    @State var showAllModelsInPicker = false
    @State var bottomSafeAreaInset: CGFloat = 0
    @State var keyboardHeight: CGFloat = 0
    @State var chatInputBarHeight: CGFloat = 0
    @State var scrollDistanceToBottom: CGFloat = 0
    @State var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var needsImmediateBottomSnap: Bool = true
    @State var pendingJumpRequest: MessageJumpRequest?
    @FocusState var composerFocused: Bool
    @FocusState var sessionPickerSearchFocused: Bool
    @AppStorage("chat.composer.draft") var draftText: String = ""
    @AppStorage(ChatPickerPresentationStyle.storageKey) var chatPickerPresentationStyleRawValue: String = ChatPickerPresentationStyle.defaultStyle.rawValue
    @Namespace var modelPickerNamespace
    @Namespace var sessionPickerNamespace

    let scrollBottomAnchorID = "chat-scroll-bottom"
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
    let longDistanceScrollAnimationThresholdScreens: CGFloat = 25
    let modelPickerMorphID = "modelPickerMorph"
    let sessionPickerMorphID = "sessionPickerMorph"
    let sessionPickerHeightRatio: CGFloat = 0.6
    let sessionPickerCornerRadius: CGFloat = 26
    let sessionPickerMaxSessionsPerPage = 100
    let transcriptExportService = ChatTranscriptExportService()
    var scrollToBottomButtonBottomPadding: CGFloat {
        max(chatInputBarHeight + 16, 92)
    }
    var tabBarCompensation: CGFloat {
        guard keyboardHeight == 0 else { return 0 }
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
    var isOverlayPanelPresented: Bool {
        !usesBottomSheetPickerStyle && (showModelPickerPanel || showSessionPickerPanel)
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
        usesBottomSheetPickerStyle ? activeChatPickerSheet == .session : showSessionPickerPanel
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
    var scrollToBottomButtonShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.3) : TelegramColors.scrollButtonShadow
    }
    var totalSessionPickerCount: Int {
        viewModel.chatSessions.count
    }
    var totalSessionPickerPages: Int {
        guard totalSessionPickerCount > 0 else { return 1 }
        return ((totalSessionPickerCount - 1) / sessionPickerMaxSessionsPerPage) + 1
    }
    var shouldShowSessionPickerPagination: Bool {
        totalSessionPickerCount > sessionPickerMaxSessionsPerPage
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
    var totalSessionPickerSearchResultPages: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 1 }
        return ((totalSessionPickerSearchResultCount - 1) / sessionPickerMaxSessionsPerPage) + 1
    }
    var shouldShowSessionPickerSearchPagination: Bool {
        totalSessionPickerSearchResultCount > sessionPickerMaxSessionsPerPage
    }
    var canGoToPreviousSessionPickerPage: Bool {
        sessionPickerPageIndex > 0
    }
    var canGoToNextSessionPickerPage: Bool {
        sessionPickerPageIndex + 1 < totalSessionPickerPages
    }
    var canGoToPreviousSessionPickerSearchResultPage: Bool {
        sessionPickerSearchResultPageIndex > 0
    }
    var canGoToNextSessionPickerSearchResultPage: Bool {
        sessionPickerSearchResultPageIndex + 1 < totalSessionPickerSearchResultPages
    }
    var currentSessionPickerPageStartOrdinal: Int {
        guard totalSessionPickerCount > 0 else { return 0 }
        return sessionPickerPageIndex * sessionPickerMaxSessionsPerPage + 1
    }
    var currentSessionPickerPageEndOrdinal: Int {
        guard totalSessionPickerCount > 0 else { return 0 }
        return min((sessionPickerPageIndex + 1) * sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
    }
    var currentSessionPickerSearchResultPageStartOrdinal: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 0 }
        return sessionPickerSearchResultPageIndex * sessionPickerMaxSessionsPerPage + 1
    }
    var currentSessionPickerSearchResultPageEndOrdinal: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 0 }
        return min(
            (sessionPickerSearchResultPageIndex + 1) * sessionPickerMaxSessionsPerPage,
            totalSessionPickerSearchResultCount
        )
    }
    var sessionPickerPaginationSummaryText: String {
        String(
            format: NSLocalizedString(
                "当前显示 %1$d-%2$d 个对话（总共 %3$d）",
                comment: "Session picker pagination summary"
            ),
            currentSessionPickerPageStartOrdinal,
            currentSessionPickerPageEndOrdinal,
            totalSessionPickerCount
        )
    }
    var sessionPickerSearchPaginationSummaryText: String {
        String(
            format: NSLocalizedString("当前显示 %1$d-%2$d 条结果（总共 %3$d）", comment: "Session picker search pagination summary"),
            currentSessionPickerSearchResultPageStartOrdinal,
            currentSessionPickerSearchResultPageEndOrdinal,
            totalSessionPickerSearchResultCount
        )
    }
    var pagedSessionPickerSessions: [ChatSession] {
        guard totalSessionPickerCount > 0 else { return [] }
        let start = min(sessionPickerPageIndex * sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
        let end = min(start + sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
        guard start < end else { return [] }
        return Array(viewModel.chatSessions[start..<end])
    }
    var pagedSessionPickerSearchResults: [SessionHistorySearchResult] {
        guard totalSessionPickerSearchResultCount > 0 else { return [] }
        let start = min(
            sessionPickerSearchResultPageIndex * sessionPickerMaxSessionsPerPage,
            totalSessionPickerSearchResultCount
        )
        let end = min(start + sessionPickerMaxSessionsPerPage, totalSessionPickerSearchResultCount)
        guard start < end else { return [] }
        return Array(sessionPickerSearchResults[start..<end])
    }
    var body: some View {
        let displayedMessages = viewModel.displayMessages
        Group {
            ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                telegramBackgroundLayer
                    .ignoresSafeArea()
                
                // Z-Index 1: 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ScrollDistanceToBottomObserver { distanceToBottom in
                                updateScrollToBottomVisibility(distanceToBottom: distanceToBottom)
                            }
                            .frame(width: 0, height: 0)

                            LazyVStack(spacing: 0, pinnedViews: []) {
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
                                    let connectsTimelineFromPrevious = shouldConnectTimeline(previousMessage, with: message)
                                    let connectsTimelineToNext = shouldConnectTimeline(message, with: nextMessage)
                                    let showsStreamingIndicators = viewModel.isSendingMessage && viewModel.latestAssistantMessageID == message.id
                                    ChatBubble(
                                        messageState: state,
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
                                        connectsTimelineFromPrevious: connectsTimelineFromPrevious,
                                        connectsTimelineToNext: connectsTimelineToNext,
                                        responseAttemptVersionInfo: viewModel.responseAttemptVersionInfo(for: message),
                                        hasAutoOpenedPendingToolCall: { toolCallID in
                                            viewModel.hasAutoOpenedPendingToolCall(toolCallID)
                                        },
                                        markPendingToolCallAutoOpened: { toolCallID in
                                            viewModel.markPendingToolCallAutoOpened(toolCallID)
                                        },
                                        onSwitchToPreviousVersion: {
                                            viewModel.switchToPreviousVersion(of: message)
                                        },
                                        onSwitchToNextVersion: {
                                            viewModel.switchToNextVersion(of: message)
                                        },
                                        onOpenMore: {
                                            messageActionSheetPayload = MessageActionSheetPayload(message: message)
                                        }
                                    )
                                    .id(state.id)
                                }
                            }

                            // 底部锚点单独放在懒栈之外，避免被虚拟化后丢失回底按钮的可见性判断。
                            Color.clear
                                .frame(height: 8)
                                .id(scrollBottomAnchorID)
                        }
                        .padding(.horizontal, 8)
                    }
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
                            scheduleImmediateBottomSnap(proxy: proxy)
                            return
                        }
                        if suppressAutoScrollOnce {
                            suppressAutoScrollOnce = false
                            return
                        }
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
                        guard newValue != nil, !showScrollToBottom else { return }
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: pendingJumpRequest) { _, request in
                        guard let request else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(request.messageID, anchor: .center)
                        }
                    }
                    .onChange(of: viewModel.pendingSearchJumpTarget) { _, _ in
                        resolvePendingSearchJumpIfNeeded()
                    }
                    .onChange(of: viewModel.currentSession?.id) { _, _ in
                        pendingHistoryResetWorkItem?.cancel()
                        pendingHistoryResetWorkItem = nil
                        showScrollToBottom = false
                        needsImmediateBottomSnap = true
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
                        needsImmediateBottomSnap = true
                        scheduleImmediateBottomSnap(proxy: proxy)
                        resolvePendingSearchJumpIfNeeded()
                    }
                    .overlay(alignment: .top) {
                        if viewModel.enableChatTopBlurFade {
                            navBarFadeBlurOverlay
                        }
                    }
                    // Telegram 风格：顶部导航栏
                    .safeAreaInset(edge: .top) {
                        telegramNavBar
                    }
                    // Telegram 风格：底部输入栏
                    .safeAreaInset(edge: .bottom) {
                        telegramInputBar
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
                                handleScrollToBottomButtonTap(proxy: proxy)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, scrollToBottomButtonBottomPadding)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .allowsHitTesting(!isOverlayPanelPresented)
                }

                VStack {
                    Spacer()
                    TTSFloatingController()
                }
                .animation(.easeInOut(duration: 0.2), value: ttsManager.isSpeaking)

                if !usesBottomSheetPickerStyle && showModelPickerPanel {
                    modelPickerOverlay
                }

                if !usesBottomSheetPickerStyle && showSessionPickerPanel {
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                keyboardHeight = frame.height
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
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
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .settings:
                    SettingsView()
                }
            }
            .sheet(item: $editingMessage) { message in
                NavigationStack {
                    EditMessageView(message: message) { updatedMessage in
                        viewModel.commitEditedMessage(updatedMessage)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $messageInfo) { info in
                MessageInfoSheet(
                    payload: info,
                    onJumpToMessage: { displayIndex in
                        jumpToMessage(displayIndex: displayIndex)
                    }
                )
            }
            .sheet(item: $messageActionSheetPayload) { payload in
                MessageActionSheet(
                    payload: payload,
                    hasDisplayVersions: viewModel.hasDisplayVersions(for: payload.message),
                    displayVersionCount: viewModel.displayVersionCount(for: payload.message),
                    displayCurrentVersionIndex: viewModel.displayCurrentVersionIndex(for: payload.message),
                    canRetry: viewModel.canRetry(message: payload.message),
                    allMessages: viewModel.allMessagesForSession,
                    ttsManager: ttsManager,
                    onEdit: { message in
                        dismissMessageActionSheet {
                            editingMessage = message
                        }
                    },
                    onRetry: { message in
                        messageActionSheetPayload = nil
                        performDeferredRetry(message)
                    },
                    onShowFullError: { content in
                        dismissMessageActionSheet {
                            fullErrorContent = FullErrorContentPayload(content: content)
                        }
                    },
                    onBranch: { message in
                        dismissMessageActionSheet {
                            messageToBranch = message
                            showBranchOptions = true
                        }
                    },
                    onExport: { format, includeReasoning, upToMessage in
                        dismissMessageActionSheet {
                            exportConversation(format: format, includeReasoning: includeReasoning, upToMessage: upToMessage)
                        }
                    },
                    onSpeak: { message in
                        messageActionSheetPayload = nil
                        toggleSpeaking(message)
                    },
                    onSwitchVersion: { index, message in
                        viewModel.switchToVersion(index, of: message)
                        messageActionSheetPayload = nil
                    },
                    onDeleteVersion: { message, index in
                        dismissMessageActionSheet {
                            messageVersionToDelete = MessageVersionDeletePayload(message: message, index: index)
                        }
                    },
                    onDelete: { message in
                        dismissMessageActionSheet {
                            messageToDelete = message
                        }
                    },
                    onDownloadImages: { fileNames in
                        dismissMessageActionSheet {
                            Task {
                                await downloadImagesToPhotoLibrary(fileNames: fileNames)
                            }
                        }
                    },
                    onCopy: { message in
                        UIPasteboard.general.string = message.content
                        messageActionSheetPayload = nil
                    },
                    onInfo: { message, index in
                        dismissMessageActionSheet {
                            messageInfo = MessageInfoPayload(
                                message: message,
                                displayIndex: index + 1,
                                totalCount: viewModel.allMessagesForSession.count
                            )
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $fullErrorContent) { payload in
                FullErrorContentSheet(payload: payload)
            }
            .sheet(item: $sessionInfo) { info in
                SessionPickerInfoSheet(payload: info)
            }
            .sheet(item: $exportSharePayload) { payload in
                ActivityShareSheet(activityItems: [payload.fileURL])
            }
            .sheet(item: $activeChatPickerSheet, onDismiss: handleChatPickerSheetDismissed) { sheet in
                chatPickerSheet(for: sheet)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(NSLocalizedString("创建分支选项", comment: ""), isPresented: $showBranchOptions, titleVisibility: .visible) {
                Button(NSLocalizedString("仅复制消息历史", comment: "")) {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: false)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button(NSLocalizedString("复制消息历史和提示词", comment: "")) {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: true)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageToBranch = nil
                }
            } message: {
                if let message = messageToBranch, let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                    Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
                }
            }
            .alert(NSLocalizedString("确认删除消息", comment: ""), isPresented: messageDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let message = messageToDelete {
                        viewModel.deleteAllVersions(of: message)
                    }
                    messageToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageToDelete = nil
                }
            } message: {
                Text(messageToDelete.map { viewModel.hasDisplayVersions(for: $0) } == true
                     ? NSLocalizedString("删除后将无法恢复这条消息的所有版本。", comment: "")
                     : NSLocalizedString("删除后无法恢复这条消息。", comment: ""))
            }
            .alert(NSLocalizedString("确认删除", comment: ""), isPresented: messageVersionDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let payload = messageVersionToDelete {
                        viewModel.deleteVersion(at: payload.index, of: payload.message)
                    }
                    messageVersionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    messageVersionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后将无法恢复此版本的内容。", comment: ""))
            }
            .alert(NSLocalizedString("确认删除会话", comment: ""), isPresented: sessionDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let session = sessionToDelete {
                        viewModel.deleteSessions([session])
                    }
                    sessionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后所有消息也将被移除，操作不可恢复。", comment: ""))
            }
            .alert(NSLocalizedString("发现幽灵会话", comment: ""), isPresented: $showGhostSessionAlert) {
                Button(NSLocalizedString("删除幽灵", comment: ""), role: .destructive) {
                    if let session = ghostSession {
                        viewModel.deleteSessions([session])
                    }
                    ghostSession = nil
                }
                Button(NSLocalizedString("稍后处理", comment: ""), role: .cancel) {
                    ghostSession = nil
                }
            } message: {
                Text(NSLocalizedString("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？", comment: ""))
            }
            .alert(NSLocalizedString("导出失败", comment: ""), isPresented: exportErrorAlertPresented) {
                Button(NSLocalizedString("确定", comment: ""), role: .cancel) {
                    exportErrorMessage = nil
                }
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .alert(
                Text(NSLocalizedString("提示", comment: "Notice")),
                isPresented: imageDownloadAlertPresented
            ) {
                Button(NSLocalizedString("确定", comment: "OK"), role: .cancel) {}
            } message: {
                Text(imageDownloadAlertMessage ?? "")
            }
            .alert(
                Text(NSLocalizedString("记忆嵌入失败", comment: "Memory embedding failure alert title")),
                isPresented: $viewModel.showMemoryEmbeddingErrorAlert
            ) {
                Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) {}
            } message: {
                Text(viewModel.memoryEmbeddingErrorMessage)
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
        }
    }
    
// MARK: - Telegram Style Components

    /// Telegram 风格导航栏
    @ViewBuilder
    private var telegramNavBar: some View {
        HStack(spacing: 12) {
            navBarSessionButton

            Spacer(minLength: 12)

            Button {
                toggleModelPickerPanel()
            } label: {
                navBarCenterPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Button {
                navigationDestination = .settings
            } label: {
                navBarIconLabel(systemName: "gearshape", accessibilityLabel: "设置")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, navBarVerticalPadding)
    }

    private var navBarSessionButton: some View {
        Button {
            toggleSessionPickerPanel()
        } label: {
            navBarSessionLabel
        }
        .buttonStyle(.plain)
    }

    private var navBarSessionLabel: some View {
        Image(systemName: "list.bullet")
            .etFont(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                sessionPickerButtonBackground
            )
            .overlay(
                Circle()
                    .stroke(isSessionPickerPresented ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
            )
            .contentShape(Circle())
            .accessibilityLabel(NSLocalizedString("会话列表", comment: ""))
    }

    private func navBarIconLabel(systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .etFont(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                navBarIconBackground
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Circle())
            .accessibilityLabel(NSLocalizedString(accessibilityLabel, comment: "导航栏图标无障碍标签"))
    }

    private var navBarCenterPill: some View {
        VStack(spacing: navBarPillSpacing) {
            MarqueeText(
                content: viewModel.currentSession?.name ?? NSLocalizedString("新的对话", comment: ""),
                uiFont: navBarTitleFont
            )
            .foregroundColor(TelegramColors.navBarText)
            .allowsHitTesting(false)

            if viewModel.activatedModels.isEmpty {
                MarqueeText(content: NSLocalizedString("选择模型以开始", comment: ""), uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            } else {
                MarqueeText(content: modelSubtitle, uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, navBarPillVerticalPadding)
        .frame(height: navBarPillHeight)
        .background(
            navBarPillBackground
        )
        .overlay(
            Capsule()
                .stroke(isModelPickerPresented ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
        )
        .overlay(alignment: .trailing) {
            Image(systemName: isModelPickerPresented ? "chevron.up" : "chevron.down")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundColor(TelegramColors.navBarSubtitle)
                .padding(.trailing, 10)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private var navBarIconBackground: some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            }
        } else {
            Circle()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var navBarPillBackground: some View {
        modelPickerMorphBackground(isExpanded: false, isSource: !showModelPickerPanel)
    }

    private var sessionPickerButtonBackground: some View {
        sessionPickerMorphBackground(isExpanded: false, isSource: !showSessionPickerPanel)
    }

    @ViewBuilder
    private var sessionPickerPanelBackground: some View {
        sessionPickerMorphBackground(isExpanded: true, isSource: showSessionPickerPanel)
    }

    private var modelSubtitle: String {
        if let selectedModel = viewModel.selectedModel {
            return "\(selectedModel.model.displayName) · \(selectedModel.provider.name)"
        }
        return NSLocalizedString("选择模型", comment: "")
    }

    private func toggleModelPickerPanel() {
        guard !usesBottomSheetPickerStyle else {
            showSessionPickerPanel = false
            showModelPickerPanel = false
            activeChatPickerSheet = .model
            return
        }
        withAnimation(modelPickerAnimation) {
            if showSessionPickerPanel {
                showSessionPickerPanel = false
            }
            showModelPickerPanel.toggle()
        }
    }

    private func dismissModelPickerPanel() {
        modelPickerRequestControl = nil
        showAllModelsInPicker = false
        if usesBottomSheetPickerStyle {
            activeChatPickerSheet = nil
            return
        }
        withAnimation(modelPickerAnimation) {
            showModelPickerPanel = false
        }
    }

    private func toggleSessionPickerPanel() {
        guard !usesBottomSheetPickerStyle else {
            showModelPickerPanel = false
            showSessionPickerPanel = false
            activeChatPickerSheet = .session
            return
        }
        withAnimation(modelPickerAnimation) {
            if showModelPickerPanel {
                showModelPickerPanel = false
            }
            if showSessionPickerPanel {
                resetSessionPickerSearchState()
            }
            showSessionPickerPanel.toggle()
        }
    }

    private func dismissSessionPickerPanel() {
        if usesBottomSheetPickerStyle {
            activeChatPickerSheet = nil
            resetSessionPickerSearchState()
            return
        }
        withAnimation(modelPickerAnimation) {
            showSessionPickerPanel = false
            resetSessionPickerSearchState()
        }
    }

    private func resetSessionPickerSearchState() {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil
        sessionPickerSearchText = ""
        sessionPickerSearchHits = [:]
        isSessionPickerSearching = false
        showSessionPickerSearchInput = false
        sessionPickerSearchFocused = false
        sessionPickerSearchResultPageIndex = 0
    }

    private func handleChatPickerSheetDismissed() {
        resetSessionPickerSearchState()
    }

    @ViewBuilder
    private func chatPickerSheet(for sheet: ChatPickerSheet) -> some View {
        switch sheet {
        case .session:
            nativeSessionPickerSheet
        case .model:
            nativeModelPickerSheet
        }
    }

    private var nativeModelPickerSheet: some View {
        NavigationStack {
            nativeModelPickerContent
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissModelPickerPanel()
                    }
                }
            }
        }
    }

    private var nativeModelPickerContent: some View {
        List {
            if viewModel.activatedModels.isEmpty {
                VStack(spacing: 6) {
                    Text(NSLocalizedString("暂无可用模型", comment: ""))
                        .etFont(.headline)
                    Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
            } else {
                Section {
                    ForEach(topModelChoices, id: \.id) { runnable in
                        nativeModelPickerModelRow(runnable)
                    }
                } header: {
                    Text(NSLocalizedString("置顶模型", comment: ""))
                } footer: {
                    Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                }

                if hasModelPickerRequestControls {
                    Section {
                        nativeModelPickerRequestControlRows
                    } header: {
                        Text(NSLocalizedString("请求控制", comment: ""))
                    } footer: {
                        Text(NSLocalizedString("点击控制名称后选择具体参数。", comment: ""))
                    }
                }

                if hasMoreModelChoices {
                    Section {
                        NavigationLink {
                            nativeModelPickerAllModelsList
                        } label: {
                            Label(NSLocalizedString("更多模型", comment: ""), systemImage: "ellipsis")
                        }
                    }
                }
            }
        }
    }

    private var nativeModelPickerAllModelsList: some View {
        List {
            Section {
                ForEach(viewModel.activatedModels, id: \.id) { runnable in
                    nativeModelPickerModelRow(runnable)
                }
            } header: {
                Text(NSLocalizedString("模型", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更多模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func nativeModelPickerModelRow(_ runnable: RunnableModel) -> some View {
        Button {
            viewModel.setSelectedModel(runnable)
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                isSelected: runnable.id == viewModel.selectedModel?.id,
                subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
            )
        }
    }

    @ViewBuilder
    private var nativeModelPickerRequestControlRows: some View {
        if let selectedModel = viewModel.selectedModel {
            ForEach(selectedModelRequestControls) { control in
                NavigationLink {
                    RequestBodyControlDetailView(runnableModel: selectedModel, control: control)
                } label: {
                    Text(control.title)
                }
            }
        }
    }

    private var nativeSessionPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                nativeSessionPickerTopBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                Divider()

                sessionPickerList(
                    queryActive: nativeSessionPickerQueryActive,
                    isSearching: isSessionPickerSearching,
                    includesSearchInput: false
                )

                Divider()

                sessionPickerFooter(
                    queryActive: nativeSessionPickerQueryActive,
                    displayedCount: nativeSessionPickerDisplayedCount,
                    isSearching: isSessionPickerSearching
                )
                .padding(.top, 10)
            }
            .navigationTitle(NSLocalizedString("会话", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissSessionPickerPanel()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.createNewSession()
                        editingSessionID = nil
                        sessionDraftName = ""
                        dismissSessionPickerPanel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("开启新对话", comment: ""))
                }
            }
        }
        .onAppear {
            showSessionPickerSearchInput = false
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: sessionPickerSearchText) { _, newValue in
            sessionPickerSearchResultPageIndex = 0
            scheduleSessionPickerSearch(for: newValue)
        }
        .onChange(of: viewModel.chatSessionListVersion) { _, _ in
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onDisappear {
            sessionPickerPendingSearchWorkItem?.cancel()
            sessionPickerPendingSearchWorkItem = nil
        }
    }

    private var nativeSessionPickerTopBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nativeSessionPickerSubtitle)
                .etFont(.footnote)
                .foregroundStyle(.secondary)

            sessionPickerSearchInput
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nativeSessionPickerQueryActive: Bool {
        !SessionHistorySearchSupport.normalizedQuery(sessionPickerSearchText).isEmpty
    }

    private var nativeSessionPickerDisplayedCount: Int {
        nativeSessionPickerQueryActive ? totalSessionPickerSearchResultCount : totalSessionPickerCount
    }

    private var nativeSessionPickerSubtitle: String {
        if nativeSessionPickerQueryActive {
            if isSessionPickerSearching {
                return NSLocalizedString("正在搜索历史会话…", comment: "")
            }
            return String(
                format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""),
                nativeSessionPickerDisplayedCount,
                sessionPickerSearchHits.count
            )
        }
        return NSLocalizedString("快速切换与管理", comment: "")
    }

    private var modelPickerOverlay: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height * modelPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissModelPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    modelPickerHeader

                    if viewModel.activatedModels.isEmpty {
                        modelPickerEmptyState
                    } else if let control = modelPickerRequestControl,
                              let selectedModel = viewModel.selectedModel {
                        overlayRequestControlDetail(runnableModel: selectedModel, control: control)
                    } else if showAllModelsInPicker {
                        modelPickerAllModelsList
                    } else {
                        modelPickerSplitContent
                    }
                }
                .frame(width: proxy.size.width, height: panelHeight, alignment: .top)
                .background(modelPickerPanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: modelPickerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
                .offset(y: navBarHeight + 6)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
    }

    private var modelPickerHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("选择模型", comment: ""))
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                    .etFont(.system(size: 12))
                    .foregroundColor(TelegramColors.navBarSubtitle)
            }

            Spacer()

            pickerHeaderActionButton(
                systemName: modelPickerBackButtonShowsClose ? "xmark" : "chevron.left",
                accessibilityLabel: modelPickerBackButtonShowsClose ? "关闭" : "返回"
            ) {
                if modelPickerRequestControl != nil {
                    modelPickerRequestControl = nil
                } else if showAllModelsInPicker {
                    showAllModelsInPicker = false
                } else {
                    dismissModelPickerPanel()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var modelPickerBackButtonShowsClose: Bool {
        modelPickerRequestControl == nil && !showAllModelsInPicker
    }

    private var modelPickerEmptyState: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("暂无可用模型", comment: ""))
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var modelPickerList: some View {
        ScrollView {
            LazyVStack(spacing: 10, pinnedViews: []) {
                ForEach(topModelChoices, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }

                if hasModelPickerRequestControls {
                    Divider()
                        .padding(.top, 2)

                    modelPickerRequestControlsPanel
                }

                if hasMoreModelChoices {
                    Divider()
                        .padding(.top, 2)

                    Button {
                        showAllModelsInPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(NSLocalizedString("更多模型", comment: ""))
                                .etFont(.system(size: 15, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarText)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 12, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarSubtitle)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.15), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var modelPickerAllModelsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.activatedModels, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var topModelChoices: [RunnableModel] {
        Array(viewModel.activatedModels.prefix(3))
    }

    private var hasMoreModelChoices: Bool {
        viewModel.activatedModels.count > topModelChoices.count
    }

    private var selectedModelRequestControls: [ModelRequestBodyControl] {
        viewModel.selectedModel?.model.requestBodyControls.filter(\.isEnabled) ?? []
    }

    private var hasModelPickerRequestControls: Bool {
        !selectedModelRequestControls.isEmpty
    }

    private var modelPickerSplitContent: some View {
        modelPickerList
    }

    private var modelPickerRequestControlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("请求控制", comment: ""))
                .etFont(.system(size: 13, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
                .padding(.horizontal, 2)

            LazyVStack(spacing: 8) {
                ForEach(selectedModelRequestControls) { control in
                    Button {
                        modelPickerRequestControl = control
                    } label: {
                        HStack(spacing: 8) {
                            Text(control.title)
                                .etFont(.system(size: 14, weight: .medium))
                                .foregroundColor(TelegramColors.navBarText)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 11, weight: .semibold))
                                .foregroundColor(TelegramColors.navBarSubtitle)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func overlayRequestControlDetail(
        runnableModel: RunnableModel,
        control: ModelRequestBodyControl
    ) -> some View {
        OverlayRequestControlDetailPanel(runnableModel: runnableModel, control: control)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
    }

    private func modelPickerRow(_ runnable: RunnableModel) -> some View {
        let isSelected = runnable.id == viewModel.selectedModel?.id
        let baseFill = colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.black.opacity(0.36) : Color.black.opacity(0.08)
        let borderOpacitySelected: Double = colorScheme == .dark ? 0.18 : 0.35
        let borderOpacityUnselected: Double = colorScheme == .dark ? 0.1 : 0.15

        return Button {
            viewModel.setSelectedModel(runnable)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                MarqueeTitleSubtitleLabel(
                    title: runnable.model.displayName,
                    subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                    titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                    subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    subtitleColor: TelegramColors.navBarSubtitle
                )
                .foregroundColor(TelegramColors.navBarText)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                Group {
                    if isLiquidGlassEnabled {
                        if #available(iOS 26.0, *) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.clear)
                                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(navBarGlassOverlayColor)
                                )
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? selectedFill : baseFill)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? borderOpacitySelected : borderOpacityUnselected), lineWidth: isSelected ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelPickerPanelBackground: some View {
        modelPickerMorphBackground(isExpanded: true, isSource: showModelPickerPanel)
    }

    @ViewBuilder
    private func modelPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? modelPickerCornerRadius : navBarPillHeight / 2

        ZStack {
            if isExpanded {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)
            }

            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .matchedGeometryEffect(id: modelPickerMorphID, in: modelPickerNamespace, isSource: isSource)
    }

    @ViewBuilder
    private func sessionPickerMorphBackground(isExpanded: Bool, isSource: Bool) -> some View {
        let cornerRadius = isExpanded ? sessionPickerCornerRadius : navBarIconSize / 2

        ZStack {
            if isExpanded {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(modelPickerPanelBaseTint)
            }

            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(navBarGlassOverlayColor)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .matchedGeometryEffect(id: sessionPickerMorphID, in: sessionPickerNamespace, isSource: isSource)
    }

    private var sessionPickerOverlay: some View {
        let normalizedQuery = SessionHistorySearchSupport.normalizedQuery(sessionPickerSearchText)
        let queryActive = !normalizedQuery.isEmpty
        let displayedSessionCount = queryActive ? totalSessionPickerSearchResultCount : totalSessionPickerCount

        return GeometryReader { proxy in
            let panelHeight = proxy.size.height * sessionPickerHeightRatio
            ZStack(alignment: .top) {
                Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSessionPickerPanel()
                    }
                    .transition(.opacity)

                VStack(spacing: 12) {
                    sessionPickerHeader(
                        queryActive: queryActive,
                        displayedCount: displayedSessionCount,
                        isSearching: isSessionPickerSearching
                    )

                    sessionPickerList(
                        queryActive: queryActive,
                        isSearching: isSessionPickerSearching
                    )

                    sessionPickerFooter(
                        queryActive: queryActive,
                        displayedCount: displayedSessionCount,
                        isSearching: isSessionPickerSearching
                    )
                }
                .frame(width: proxy.size.width, height: panelHeight, alignment: .top)
                .background(sessionPickerPanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: sessionPickerCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.2), radius: 22, x: 0, y: 12)
                .offset(y: navBarHeight + 6)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .top))
                )
            }
        }
        .onAppear {
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: sessionPickerSearchText) { _, newValue in
            sessionPickerSearchResultPageIndex = 0
            scheduleSessionPickerSearch(for: newValue)
        }
        .onChange(of: viewModel.chatSessionListVersion) { _, _ in
            normalizeSessionPickerPageIndex()
            normalizeSessionPickerSearchResultPageIndex()
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
            scheduleSessionPickerSearch(for: sessionPickerSearchText)
        }
        .onDisappear {
            sessionPickerPendingSearchWorkItem?.cancel()
            sessionPickerPendingSearchWorkItem = nil
        }
    }

    private func sessionPickerHeader(queryActive: Bool, displayedCount: Int, isSearching: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("会话", comment: ""))
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                if queryActive {
                    Text(
                        isSearching
                        ? NSLocalizedString("正在搜索历史会话…", comment: "")
                        : String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), displayedCount, sessionPickerSearchHits.count)
                    )
                        .etFont(.system(size: 12))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                } else {
                    Text(NSLocalizedString("快速切换与管理", comment: ""))
                        .etFont(.system(size: 12))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                pickerHeaderActionButton(
                    systemName: "magnifyingglass",
                    accessibilityLabel: "搜索会话"
                ) {
                    showSessionPickerSearchInput = true
                    DispatchQueue.main.async {
                        sessionPickerSearchFocused = true
                    }
                }

                pickerHeaderActionButton(
                    systemName: "plus",
                    accessibilityLabel: "开启新对话"
                ) {
                    viewModel.createNewSession()
                    editingSessionID = nil
                    sessionDraftName = ""
                    dismissSessionPickerPanel()
                }

                pickerHeaderActionButton(
                    systemName: "xmark",
                    accessibilityLabel: "关闭"
                ) {
                    dismissSessionPickerPanel()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var sessionPickerSearchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("搜索会话标题或消息", comment: ""), text: $sessionPickerSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($sessionPickerSearchFocused)
            if !sessionPickerSearchText.isEmpty {
                Button {
                    sessionPickerSearchText = ""
                    sessionPickerSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Group {
                if isLiquidGlassEnabled {
                    if #available(iOS 26.0, *) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.clear)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(navBarGlassOverlayColor)
                            )
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06))
                }
            }
        )
    }

    private var sessionPickerSearchingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    private func sessionPickerEmptyState(queryActive: Bool) -> some View {
        VStack(spacing: 8) {
            Text(queryActive ? NSLocalizedString("未找到匹配的搜索结果", comment: "") : NSLocalizedString("暂无会话", comment: ""))
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
            Text(queryActive ? NSLocalizedString("换个关键词试试看", comment: "") : NSLocalizedString("创建一个新对话开始吧", comment: ""))
                .etFont(.system(size: 12))
                .foregroundColor(TelegramColors.navBarSubtitle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    private func sessionPickerList(
        queryActive: Bool,
        isSearching: Bool,
        includesSearchInput: Bool = true
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if includesSearchInput && showSessionPickerSearchInput {
                    sessionPickerSearchInput
                        .id("session-picker-search-input")
                }

                if queryActive && isSearching {
                    sessionPickerSearchingState
                } else if queryActive && totalSessionPickerSearchResultCount == 0 {
                    sessionPickerEmptyState(queryActive: true)
                } else if !queryActive && pagedSessionPickerSessions.isEmpty {
                    sessionPickerEmptyState(queryActive: false)
                } else {
                    if queryActive {
                        ForEach(pagedSessionPickerSearchResults) { result in
                            sessionPickerSearchResultRow(result)
                        }
                    } else {
                        ForEach(pagedSessionPickerSessions) { session in
                            sessionPickerRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sessionPickerFooter(queryActive: Bool, displayedCount: Int, isSearching: Bool) -> some View {
        Group {
            if shouldShowSessionPickerPaginationBar(queryActive: queryActive) {
                HStack(spacing: 12) {
                    sessionPickerFooterButton(
                        systemName: "chevron.left",
                        accessibilityLabel: NSLocalizedString("上一页", comment: "Session picker previous page"),
                        isEnabled: canGoToPreviousActiveSessionPickerPage(queryActive: queryActive)
                    ) {
                        goToPreviousActiveSessionPickerPage(queryActive: queryActive)
                    }

                    Text(activeSessionPickerPaginationSummaryText(queryActive: queryActive))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)
                        .etFont(.system(size: 12, weight: .medium))
                        .foregroundColor(TelegramColors.navBarSubtitle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(sessionPickerFooterSummaryBackground)

                    sessionPickerFooterButton(
                        systemName: "chevron.right",
                        accessibilityLabel: NSLocalizedString("下一页", comment: "Session picker next page"),
                        isEnabled: canGoToNextActiveSessionPickerPage(queryActive: queryActive)
                    ) {
                        goToNextActiveSessionPickerPage(queryActive: queryActive)
                    }
                }
            } else {
                Text(
                    queryActive
                    ? (isSearching ? NSLocalizedString("正在搜索…", comment: "") : String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), displayedCount, sessionPickerSearchHits.count))
                    : String(format: NSLocalizedString("共 %d 个会话", comment: ""), viewModel.chatSessions.count)
                )
                .etFont(.system(size: 12, weight: .medium))
                .foregroundColor(TelegramColors.navBarSubtitle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func sessionPickerFooterButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(isEnabled ? TelegramColors.sendButtonColor : TelegramColors.navBarSubtitle.opacity(0.45))
                .frame(width: 32, height: 32)
                .background(sessionPickerFooterButtonBackground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(accessibilityLabel, comment: "会话选择器按钮无障碍标签"))
    }

    @ViewBuilder
    private var sessionPickerFooterButtonBackground: some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(navBarGlassOverlayColor)
                    )
            }
        } else {
            Circle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
        }
    }

    @ViewBuilder
    private var sessionPickerFooterSummaryBackground: some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Capsule())
                    .overlay(
                        Capsule()
                            .fill(navBarGlassOverlayColor)
                    )
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(navBarGlassOverlayColor)
                    )
            }
        } else {
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06))
        }
    }

    private func normalizeSessionPickerPageIndex() {
        let maxIndex = max(totalSessionPickerPages - 1, 0)
        if sessionPickerPageIndex > maxIndex {
            sessionPickerPageIndex = maxIndex
        } else if sessionPickerPageIndex < 0 {
            sessionPickerPageIndex = 0
        }
    }

    private func normalizeSessionPickerSearchResultPageIndex() {
        let maxIndex = max(totalSessionPickerSearchResultPages - 1, 0)
        if sessionPickerSearchResultPageIndex > maxIndex {
            sessionPickerSearchResultPageIndex = maxIndex
        } else if sessionPickerSearchResultPageIndex < 0 {
            sessionPickerSearchResultPageIndex = 0
        }
    }

    private func shouldShowSessionPickerPaginationBar(queryActive: Bool) -> Bool {
        queryActive ? shouldShowSessionPickerSearchPagination : shouldShowSessionPickerPagination
    }

    private func canGoToPreviousActiveSessionPickerPage(queryActive: Bool) -> Bool {
        queryActive ? canGoToPreviousSessionPickerSearchResultPage : canGoToPreviousSessionPickerPage
    }

    private func canGoToNextActiveSessionPickerPage(queryActive: Bool) -> Bool {
        queryActive ? canGoToNextSessionPickerSearchResultPage : canGoToNextSessionPickerPage
    }

    private func activeSessionPickerPaginationSummaryText(queryActive: Bool) -> String {
        queryActive ? sessionPickerSearchPaginationSummaryText : sessionPickerPaginationSummaryText
    }

    private func goToPreviousActiveSessionPickerPage(queryActive: Bool) {
        if queryActive {
            guard canGoToPreviousSessionPickerSearchResultPage else { return }
            sessionPickerSearchResultPageIndex -= 1
            return
        }
        guard canGoToPreviousSessionPickerPage else { return }
        sessionPickerPageIndex -= 1
    }

    private func goToNextActiveSessionPickerPage(queryActive: Bool) {
        if queryActive {
            guard canGoToNextSessionPickerSearchResultPage else { return }
            sessionPickerSearchResultPageIndex += 1
            return
        }
        guard canGoToNextSessionPickerPage else { return }
        sessionPickerPageIndex += 1
    }

    private func scheduleSessionPickerSearch(for query: String) {
        sessionPickerPendingSearchWorkItem?.cancel()
        sessionPickerPendingSearchWorkItem = nil

        let normalized = SessionHistorySearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            sessionPickerSearchHits = [:]
            isSessionPickerSearching = false
            sessionPickerSearchResultPageIndex = 0
            return
        }

        isSessionPickerSearching = true
        sessionPickerLatestSearchToken += 1
        let searchToken = sessionPickerLatestSearchToken
        let sessionsSnapshot = viewModel.chatSessions
        let currentSessionIDSnapshot = viewModel.currentSession?.id
        let currentMessagesSnapshot = viewModel.allMessagesForSession
        let querySnapshot = query

        let workItem = DispatchWorkItem {
            let hits = SessionHistorySearchSupport.searchHits(
                sessions: sessionsSnapshot,
                query: querySnapshot,
                currentSessionID: currentSessionIDSnapshot,
                currentSessionMessages: currentMessagesSnapshot,
                messageLoader: { sessionID in
                    Persistence.loadMessages(for: sessionID)
                }
            )
            DispatchQueue.main.async {
                guard searchToken == sessionPickerLatestSearchToken else { return }
                sessionPickerSearchHits = hits
                normalizeSessionPickerSearchResultPageIndex()
                isSessionPickerSearching = false
                sessionPickerPendingSearchWorkItem = nil
            }
        }

        sessionPickerPendingSearchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func pickerHeaderActionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundColor(TelegramColors.navBarText)
                .frame(width: 32, height: 32)
                .background(
                    Group {
                        if isLiquidGlassEnabled {
                            if #available(iOS 26.0, *) {
                                Circle()
                                    .fill(Color.clear)
                                    .glassEffect(.clear, in: Circle())
                                    .overlay(
                                        Circle()
                                            .fill(navBarGlassOverlayColor)
                                    )
                            } else {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Circle()
                                            .fill(navBarGlassOverlayColor)
                                    )
                            }
                        } else {
                            Circle()
                                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func sessionPickerRow(_ session: ChatSession) -> some View {
        let isCurrent = session.id == viewModel.currentSession?.id
        let isEditing = editingSessionID == session.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return SessionPickerRow(
            session: session,
            isCurrent: isCurrent,
            isRunning: viewModel.runningSessionIDs.contains(session.id),
            isEditing: isEditing,
            draftName: isEditing ? $sessionDraftName : .constant(session.name),
            searchSummary: nil,
            onCommit: { newName in
                viewModel.updateSessionName(session, newName: newName)
                editingSessionID = nil
            },
            onSelect: {
                selectSessionFromPicker(session)
            },
            onRename: {
                editingSessionID = session.id
                sessionDraftName = session.name
            },
            onBranch: { copyHistory in
                let newSession = viewModel.branchSession(from: session, copyMessages: copyHistory)
                viewModel.setCurrentSession(newSession)
                dismissSessionPickerPanel()
            },
            onDeleteLastMessage: {
                viewModel.deleteLastMessage(for: session)
            },
            onDelete: {
                sessionToDelete = session
            },
            onCancelRename: {
                editingSessionID = nil
                sessionDraftName = session.name
            },
            onInfo: {
                sessionInfo = SessionPickerInfoPayload(
                    session: session,
                    messageCount: viewModel.messageCount(for: session),
                    isCurrent: isCurrent
                )
            },
            onExport: { format, includeReasoning in
                exportSession(session, format: format, includeReasoning: includeReasoning)
            }
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
    }

    private func sessionPickerSearchResultRow(_ result: SessionHistorySearchResult) -> some View {
        let isCurrent = result.sessionID == viewModel.currentSession?.id
        let selectedFill = Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.12)

        return Button {
            if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
                selectSessionFromPicker(session, messageOrdinal: result.messageOrdinal)
            }
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: searchResultTitle(for: result),
                subtitle: result.match.preview,
                isSelected: isCurrent,
                titleUIFont: .systemFont(ofSize: 15, weight: .semibold),
                subtitleUIFont: .systemFont(ofSize: 12)
            )
            .foregroundColor(TelegramColors.navBarText)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? selectedFill : Color.clear)
        )
    }

    private func sourceLabel(for source: SessionHistorySearchHitSource) -> String {
        switch source {
        case .sessionName:
            return NSLocalizedString("标题", comment: "")
        case .topicPrompt:
            return NSLocalizedString("主题提示", comment: "")
        case .enhancedPrompt:
            return NSLocalizedString("增强提示词", comment: "")
        case .userMessage:
            return NSLocalizedString("用户消息", comment: "")
        case .assistantMessage:
            return NSLocalizedString("助手消息", comment: "")
        case .systemMessage:
            return NSLocalizedString("系统消息", comment: "")
        case .toolMessage:
            return NSLocalizedString("工具消息", comment: "")
        case .errorMessage:
            return NSLocalizedString("错误消息", comment: "")
        }
    }

    private func searchResultTitle(for result: SessionHistorySearchResult) -> String {
        if let messageOrdinal = result.messageOrdinal {
            return String(format: NSLocalizedString("“%@” 第%d条", comment: ""), result.sessionName, messageOrdinal)
        }
        return String(format: NSLocalizedString("“%@” %@", comment: ""), result.sessionName, sourceLabel(for: result.match.source))
    }

    private func selectSessionFromPicker(_ session: ChatSession, messageOrdinal: Int? = nil) {
        if session.isTemporary {
            editingSessionID = nil
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
            return
        }

        if !Persistence.sessionDataExists(sessionID: session.id) {
            ghostSession = session
            showGhostSessionAlert = true
        } else {
            editingSessionID = nil
            if let messageOrdinal {
                viewModel.requestMessageJump(sessionID: session.id, messageOrdinal: messageOrdinal)
            } else {
                viewModel.clearPendingMessageJumpTarget()
            }
            viewModel.setCurrentSession(session)
            dismissSessionPickerPanel()
        }
    }

}
