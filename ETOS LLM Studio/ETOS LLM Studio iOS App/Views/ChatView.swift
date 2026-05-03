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
}
