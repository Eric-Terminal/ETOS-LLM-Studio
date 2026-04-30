// ============================================================================
// ChatView.swift
// ============================================================================
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

// MARK: - Telegram 主题颜色
private struct TelegramColors {
    // 导航栏颜色
    static let navBarText = Color.primary
    static let navBarSubtitle = Color.secondary
    
    // 输入栏颜色
    static let inputBackground = Color(uiColor: .systemBackground)
    static let inputFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .separator)
    static let attachButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let sendButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    
    // 滚动按钮
    static let scrollButtonBackground = Color(uiColor: .systemBackground)
    static let scrollButtonShadow = Color.black.opacity(0.15)
}

private func resolvedFileMimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext),
       let mimeType = type.preferredMIMEType {
        return mimeType
    }
    return "application/octet-stream"
}

private struct ChatExportSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?

    init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var showScrollToBottom = false
    @State private var suppressAutoScrollOnce = false
    @State private var navigationDestination: ChatNavigationDestination?
    @State private var editingMessage: ChatMessage?
    @State private var messageInfo: MessageInfoPayload?
    @State private var showBranchOptions = false
    @State private var messageToBranch: ChatMessage?
    @State private var messageToDelete: ChatMessage?
    @State private var messageVersionToDelete: ChatMessage?
    @State private var fullErrorContent: FullErrorContentPayload?
    @State private var showModelPickerPanel = false
    @State private var showSessionPickerPanel = false
    @State private var editingSessionID: UUID?
    @State private var sessionDraftName: String = ""
    @State private var sessionToDelete: ChatSession?
    @State private var sessionInfo: SessionPickerInfoPayload?
    @State private var showGhostSessionAlert = false
    @State private var ghostSession: ChatSession?
    @State private var sessionPickerSearchText: String = ""
    @State private var sessionPickerSearchHits: [UUID: SessionHistorySearchHit] = [:]
    @State private var isSessionPickerSearching: Bool = false
    @State private var sessionPickerLatestSearchToken: Int = 0
    @State private var sessionPickerPendingSearchWorkItem: DispatchWorkItem?
    @State private var showSessionPickerSearchInput: Bool = false
    @State private var sessionPickerPageIndex: Int = 0
    @State private var sessionPickerSearchResultPageIndex: Int = 0
    @State private var imageDownloadAlertMessage: String?
    @State private var exportSharePayload: ChatExportSharePayload?
    @State private var exportErrorMessage: String?
    @State private var bottomSafeAreaInset: CGFloat = 0
    @State private var keyboardHeight: CGFloat = 0
    @State private var chatInputBarHeight: CGFloat = 0
    @State private var scrollDistanceToBottom: CGFloat = 0
    @State private var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State private var pendingBottomSnapTask: Task<Void, Never>?
    @State private var needsImmediateBottomSnap: Bool = true
    @State private var pendingJumpRequest: MessageJumpRequest?
    @FocusState private var composerFocused: Bool
    @FocusState private var sessionPickerSearchFocused: Bool
    @AppStorage("chat.composer.draft") private var draftText: String = ""
    @AppStorage(ChatNavigationMode.storageKey) private var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @Namespace private var modelPickerNamespace
    @Namespace private var sessionPickerNamespace
    
    private let scrollBottomAnchorID = "chat-scroll-bottom"
    private let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    private let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    private let navBarVerticalPadding: CGFloat = 8
    private let navBarPillVerticalPadding: CGFloat = 6
    private let navBarPillSpacing: CGFloat = 1
    private let navBarBlurFadeHeightRatio: CGFloat = 0.05
    private let modelPickerHeightRatio: CGFloat = 0.4
    private let modelPickerCornerRadius: CGFloat = 24
    private let modelPickerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private let scrollToBottomButtonAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.52)
    private let longDistanceScrollAnimationThresholdScreens: CGFloat = 25
    private let modelPickerMorphID = "modelPickerMorph"
    private let sessionPickerMorphID = "sessionPickerMorph"
    private let sessionPickerHeightRatio: CGFloat = 0.6
    private let sessionPickerCornerRadius: CGFloat = 26
    private let sessionPickerMaxSessionsPerPage = 100
    private let transcriptExportService = ChatTranscriptExportService()
    private var scrollToBottomButtonBottomPadding: CGFloat {
        max(chatInputBarHeight + 16, 92)
    }
    private var tabBarCompensation: CGFloat {
        guard keyboardHeight == 0 else { return 0 }
        let measuredTabBarHeight = UITabBarController().tabBar.frame.height
        let tabBarHeight = measuredTabBarHeight > 0 ? measuredTabBarHeight : 49
        guard bottomSafeAreaInset > tabBarHeight + 8, bottomSafeAreaInset < 160 else {
            return 0
        }
        return tabBarHeight
    }
    private var navBarPillHeight: CGFloat {
        navBarTitleFont.lineHeight
            + navBarSubtitleFont.lineHeight
            + navBarPillSpacing
            + navBarPillVerticalPadding * 2
    }
    private var navBarHeight: CGFloat {
        navBarPillHeight + navBarVerticalPadding * 2
    }
    private var navBarIconSize: CGFloat {
        navBarPillHeight
    }
    private var isOverlayPanelPresented: Bool {
        showModelPickerPanel || showSessionPickerPanel
    }
    private var isNativeNavigationEnabled: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
    }
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    private var messageDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { messageToDelete != nil },
            set: { if !$0 { messageToDelete = nil } }
        )
    }
    private var messageVersionDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { messageVersionToDelete != nil },
            set: { if !$0 { messageVersionToDelete = nil } }
        )
    }
    private var sessionDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    sessionToDelete = nil
                }
            }
        )
    }
    private var exportErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportErrorMessage = nil
                }
            }
        )
    }
    private var imageDownloadAlertPresented: Binding<Bool> {
        Binding(
            get: { imageDownloadAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    imageDownloadAlertMessage = nil
                }
            }
        )
    }
    private var navBarGlassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }
    private var modelPickerPanelBaseTint: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.78)
    }
    private var scrollToBottomButtonFillColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : .white
    }
    private var scrollToBottomButtonIconColor: Color {
        colorScheme == .dark ? .white : TelegramColors.sendButtonColor
    }
    private var scrollToBottomButtonBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    private var scrollToBottomButtonShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.3) : TelegramColors.scrollButtonShadow
    }
    private var totalSessionPickerCount: Int {
        viewModel.chatSessions.count
    }
    private var totalSessionPickerPages: Int {
        guard totalSessionPickerCount > 0 else { return 1 }
        return ((totalSessionPickerCount - 1) / sessionPickerMaxSessionsPerPage) + 1
    }
    private var shouldShowSessionPickerPagination: Bool {
        totalSessionPickerCount > sessionPickerMaxSessionsPerPage
    }
    private var sessionPickerSearchResults: [SessionHistorySearchResult] {
        SessionHistorySearchSupport.flattenedResults(
            sessions: viewModel.chatSessions,
            hits: sessionPickerSearchHits
        )
    }
    private var totalSessionPickerSearchResultCount: Int {
        sessionPickerSearchResults.count
    }
    private var totalSessionPickerSearchResultPages: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 1 }
        return ((totalSessionPickerSearchResultCount - 1) / sessionPickerMaxSessionsPerPage) + 1
    }
    private var shouldShowSessionPickerSearchPagination: Bool {
        totalSessionPickerSearchResultCount > sessionPickerMaxSessionsPerPage
    }
    private var canGoToPreviousSessionPickerPage: Bool {
        sessionPickerPageIndex > 0
    }
    private var canGoToNextSessionPickerPage: Bool {
        sessionPickerPageIndex + 1 < totalSessionPickerPages
    }
    private var canGoToPreviousSessionPickerSearchResultPage: Bool {
        sessionPickerSearchResultPageIndex > 0
    }
    private var canGoToNextSessionPickerSearchResultPage: Bool {
        sessionPickerSearchResultPageIndex + 1 < totalSessionPickerSearchResultPages
    }
    private var currentSessionPickerPageStartOrdinal: Int {
        guard totalSessionPickerCount > 0 else { return 0 }
        return sessionPickerPageIndex * sessionPickerMaxSessionsPerPage + 1
    }
    private var currentSessionPickerPageEndOrdinal: Int {
        guard totalSessionPickerCount > 0 else { return 0 }
        return min((sessionPickerPageIndex + 1) * sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
    }
    private var currentSessionPickerSearchResultPageStartOrdinal: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 0 }
        return sessionPickerSearchResultPageIndex * sessionPickerMaxSessionsPerPage + 1
    }
    private var currentSessionPickerSearchResultPageEndOrdinal: Int {
        guard totalSessionPickerSearchResultCount > 0 else { return 0 }
        return min(
            (sessionPickerSearchResultPageIndex + 1) * sessionPickerMaxSessionsPerPage,
            totalSessionPickerSearchResultCount
        )
    }
    private var sessionPickerPaginationSummaryText: String {
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
    private var sessionPickerSearchPaginationSummaryText: String {
        String(
            format: NSLocalizedString("当前显示 %1$d-%2$d 条结果（总共 %3$d）", comment: "Session picker search pagination summary"),
            currentSessionPickerSearchResultPageStartOrdinal,
            currentSessionPickerSearchResultPageEndOrdinal,
            totalSessionPickerSearchResultCount
        )
    }
    private var pagedSessionPickerSessions: [ChatSession] {
        guard totalSessionPickerCount > 0 else { return [] }
        let start = min(sessionPickerPageIndex * sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
        let end = min(start + sessionPickerMaxSessionsPerPage, totalSessionPickerCount)
        guard start < end else { return [] }
        return Array(viewModel.chatSessions[start..<end])
    }
    private var pagedSessionPickerSearchResults: [SessionHistorySearchResult] {
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
                                        }
                                    )
                                    .id(state.id)
                                    .contextMenu {
                                        contextMenu(for: message)
                                    }
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
                    .overlay(alignment: .top) {
                        navBarFadeBlurOverlay
                    }
                    .allowsHitTesting(!isOverlayPanelPresented)
                }

                VStack {
                    Spacer()
                    TTSFloatingController()
                }
                .animation(.easeInOut(duration: 0.2), value: ttsManager.isSpeaking)

                if showModelPickerPanel {
                    modelPickerOverlay
                }

                if showSessionPickerPanel {
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
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .sessions:
                    SessionListView()
                case .settings:
                    SettingsView()
                case .preferenceSettings:
                    preferenceSettingsView
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
            .sheet(item: $fullErrorContent) { payload in
                FullErrorContentSheet(payload: payload)
            }
            .sheet(item: $sessionInfo) { info in
                SessionPickerInfoSheet(payload: info)
            }
            .sheet(item: $exportSharePayload) { payload in
                ActivityShareSheet(activityItems: [payload.fileURL])
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
            .alert(NSLocalizedString("确认删除当前版本", comment: ""), isPresented: messageVersionDeleteAlertPresented) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let message = messageVersionToDelete {
                        viewModel.deleteCurrentVersion(of: message)
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
    
    // MARK: - Background

    private func memoryRetryStoppedNoticeBanner(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(text)
                .etFont(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.memoryRetryStoppedNoticeMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .etFont(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("关闭提示", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
    }
    
    /// Telegram 风格的背景层
    private var telegramBackgroundLayer: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.enableBackground,
                   let image = viewModel.currentBackgroundImageBlurredUIImage {
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }
                        
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(
                                contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .clipped()
                            .opacity(viewModel.backgroundOpacity)
                    }
                } else {
                    // Telegram 默认背景 - 浅色图案背景
                    TelegramDefaultBackground()
                }
            }
        }
    }

// MARK: - Telegram Style Components

    /// Telegram 风格导航栏
    @ViewBuilder
    private var telegramNavBar: some View {
        HStack(spacing: 12) {
            if isNativeNavigationEnabled {
                navBarBackButton
            } else {
                navBarSessionButton
            }

            Spacer(minLength: 12)

            Button {
                toggleModelPickerPanel()
            } label: {
                navBarCenterPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Button {
                navigationDestination = isNativeNavigationEnabled ? .preferenceSettings : .settings
            } label: {
                navBarIconLabel(systemName: "gearshape", accessibilityLabel: "设置")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, navBarVerticalPadding)
    }

    private var navBarBackButton: some View {
        Button {
            dismiss()
        } label: {
            navBarIconLabel(systemName: "chevron.left", accessibilityLabel: "返回历史会话")
        }
        .buttonStyle(.plain)
    }

    private var preferenceSettingsView: some View {
        ModelAdvancedSettingsView(
            aiTemperature: $viewModel.aiTemperature,
            aiTopP: $viewModel.aiTopP,
            globalSystemPromptEntries: $viewModel.globalSystemPromptEntries,
            selectedGlobalSystemPromptEntryID: $viewModel.selectedGlobalSystemPromptEntryID,
            maxChatHistory: $viewModel.maxChatHistory,
            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
            enableStreaming: $viewModel.enableStreaming,
            enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
            enableOpenAIStreamIncludeUsage: $viewModel.enableOpenAIStreamIncludeUsage,
            enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
            enableReasoningSummary: $viewModel.enableReasoningSummary,
            currentSession: $viewModel.currentSession,
            includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
            systemTimeInjectionPosition: $viewModel.systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: $viewModel.enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: $viewModel.periodicTimeLandmarkIntervalMinutes,
            addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
            selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
            updateSelectedGlobalSystemPromptContent: viewModel.updateSelectedGlobalSystemPromptContent,
            updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
            deleteGlobalSystemPromptEntry: { viewModel.deleteGlobalSystemPromptEntry(id: $0) }
        )
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigationDestination = nil
                } label: {
                    Label(NSLocalizedString("返回对话", comment: ""), systemImage: "chevron.left")
                }
            }
        }
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
                    .stroke(showSessionPickerPanel ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
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
                .stroke(showModelPickerPanel ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6)
        )
        .overlay(alignment: .trailing) {
            Image(systemName: showModelPickerPanel ? "chevron.up" : "chevron.down")
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

    private var navBarFadeBlurOverlay: some View {
        GeometryReader { proxy in
            let adaptiveHeight = proxy.size.height * navBarBlurFadeHeightRatio
            BlurView(style: .regular)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black, location: 0),
                            .init(color: Color.black.opacity(0.7), location: 0.35),
                            .init(color: Color.black.opacity(0), location: 1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: navBarHeight + adaptiveHeight)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func toggleModelPickerPanel() {
        withAnimation(modelPickerAnimation) {
            if showSessionPickerPanel {
                showSessionPickerPanel = false
            }
            showModelPickerPanel.toggle()
        }
    }

    private func dismissModelPickerPanel() {
        withAnimation(modelPickerAnimation) {
            showModelPickerPanel = false
        }
    }

    private func toggleSessionPickerPanel() {
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
                    } else {
                        modelPickerList
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
                systemName: "xmark",
                accessibilityLabel: "关闭"
            ) {
                dismissModelPickerPanel()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
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
            LazyVStack(spacing: 10) {
                ForEach(viewModel.activatedModels, id: \.id) { runnable in
                    modelPickerRow(runnable)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func modelPickerRow(_ runnable: RunnableModel) -> some View {
        let isSelected = runnable.id == viewModel.selectedModel?.id
        let baseFill = colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05)
        let selectedFill = colorScheme == .dark ? Color.black.opacity(0.36) : Color.black.opacity(0.08)
        let borderOpacitySelected: Double = colorScheme == .dark ? 0.18 : 0.35
        let borderOpacityUnselected: Double = colorScheme == .dark ? 0.1 : 0.15

        return Button {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerPanel()
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

    private func sessionPickerList(queryActive: Bool, isSearching: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if showSessionPickerSearchInput {
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

    /// Telegram 风格输入栏
    @ViewBuilder
    private var telegramInputBar: some View {
        if let request = viewModel.activeAskUserInputRequest {
            AskUserInputComposerPanel(
                request: request,
                submitAction: { answers in
                    composerFocused = false
                    draftText = ""
                    viewModel.submitAskUserInputAnswers(answers, for: request)
                },
                cancelAction: {
                    composerFocused = false
                    draftText = ""
                    viewModel.cancelAskUserInputRequest(using: request)
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6 - tabBarCompensation)
        } else {
            TelegramMessageComposer(
                text: Binding(
                    get: { draftText },
                    set: { newValue in
                        draftText = newValue
                        viewModel.userInput = newValue
                    }
                ),
                isSending: viewModel.isSendingMessage,
                sendAction: {
                    guard viewModel.canSendMessage else { return }
                    viewModel.sendMessage()
                    draftText = ""
                },
                stopAction: {
                    viewModel.cancelSending()
                },
                focus: $composerFocused
            )
            .onAppear {
                viewModel.userInput = draftText
            }
            .padding(.bottom, -tabBarCompensation)
        }
    }
    
    /// Telegram 风格滚动到底部按钮
    @ViewBuilder
    private func telegramScrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(scrollToBottomButtonFillColor)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle()
                            .stroke(scrollToBottomButtonBorderColor, lineWidth: 0.8)
                    )
                    .shadow(color: scrollToBottomButtonShadowColor, radius: 6, x: 0, y: 2)
                
                Image(systemName: "chevron.down")
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundColor(scrollToBottomButtonIconColor)
            }
        }
        .accessibilityLabel(NSLocalizedString("滚动到底部", comment: ""))
    }
    
    /// Telegram 风格历史加载提示
    @ViewBuilder
    private var historyBanner: some View {
        let remainingCount = viewModel.remainingHistoryCount
        if remainingCount > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = viewModel.historyLoadChunkCount
            Button {
                suppressAutoScrollOnce = true
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .etFont(.system(size: 14))
                    Text(String(format: NSLocalizedString("加载更早的 %d 条消息", comment: ""), chunk))
                        .etFont(.system(size: 13, weight: .medium))
                }
                .foregroundColor(TelegramColors.attachButtonColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(
                    Capsule()
                        .fill(Color(uiColor: .systemBackground).opacity(0.9))
                        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        if !hasAttachments {
            Button {
                editingMessage = message
            } label: {
                Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
            }
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                performDeferredRetry(message)
            } label: {
                Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
            }
        }
        
        // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
        if message.role == .error, let fullContent = message.fullErrorContent {
            Button {
                fullErrorContent = FullErrorContentPayload(content: fullContent)
            } label: {
                Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
            }
        }
        
        Button {
            messageToBranch = message
            showBranchOptions = true
        } label: {
            Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
        }

        Menu {
            Menu(NSLocalizedString("包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
            Menu(NSLocalizedString("不包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
        } label: {
            Label(NSLocalizedString("导出整个会话", comment: ""), systemImage: "square.and.arrow.up")
        }

        Menu {
            Menu(NSLocalizedString("包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
            Menu(NSLocalizedString("不包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
        } label: {
            Label(NSLocalizedString("导出到此消息（含上文）", comment: ""), systemImage: "arrow.up.doc")
        }

        if message.role == .assistant || message.role == .tool || message.role == .system {
            Button {
                if ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking {
                    viewModel.stopSpeakingMessage()
                } else {
                    viewModel.speakMessage(message)
                }
            } label: {
                Label(
                    ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                    systemImage: ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? "stop.circle" : "speaker.wave.2"
                )
            }
        }
        
        Divider()
        
        // 版本管理菜单项
        if viewModel.hasDisplayVersions(for: message) {
            Menu {
                ForEach(0..<viewModel.displayVersionCount(for: message), id: \.self) { index in
                    Button {
                        viewModel.switchToVersion(index, of: message)
                    } label: {
                        HStack {
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                            if index == viewModel.displayCurrentVersionIndex(for: message) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    String(
                        format: NSLocalizedString("切换版本 (%d/%d)", comment: ""),
                        viewModel.displayCurrentVersionIndex(for: message) + 1,
                        viewModel.displayVersionCount(for: message)
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
            }
            
            if viewModel.displayVersionCount(for: message) > 1 {
                Button(role: .destructive) {
                    messageVersionToDelete = message
                } label: {
                    Label(NSLocalizedString("删除当前版本", comment: ""), systemImage: "trash")
                }
            }
            
            Divider()
        }
        
        Button(role: .destructive) {
            messageToDelete = message
        } label: {
            Label(viewModel.hasDisplayVersions(for: message) ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
        }
        
        Divider()
        
        if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
            Button {
                Task {
                    await downloadImagesToPhotoLibrary(fileNames: imageFileNames)
                }
            } label: {
                Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
            }
        }

        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label(NSLocalizedString("复制内容", comment: ""), systemImage: "doc.on.doc")
        }
        
        if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
            Button {
                messageInfo = MessageInfoPayload(
                    message: message,
                    displayIndex: index + 1,
                    totalCount: viewModel.allMessagesForSession.count
                )
            } label: {
                Label(NSLocalizedString("查看消息信息", comment: ""), systemImage: "info.circle")
            }
        }
    }

    private func performDeferredRetry(_ message: ChatMessage) {
        Task { @MainActor in
            await Task.yield()
            viewModel.retryMessage(message)
        }
    }

    private func exportConversation(
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        upToMessage: ChatMessage?
    ) {
        do {
            let output = try transcriptExportService.export(
                session: viewModel.currentSession,
                messages: ChatResponseAttemptSupport.visibleMessages(from: viewModel.allMessagesForSession),
                format: format,
                includeReasoning: includeReasoning,
                upToMessageID: upToMessage?.id
            )
            applyExportOutput(output)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func exportSession(
        _ session: ChatSession,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool
    ) {
        do {
            let messages: [ChatMessage]
            if viewModel.currentSession?.id == session.id {
                messages = viewModel.allMessagesForSession
            } else {
                messages = Persistence.loadMessages(for: session.id)
            }

            let output = try transcriptExportService.export(
                session: session,
                messages: ChatResponseAttemptSupport.visibleMessages(from: messages),
                format: format,
                includeReasoning: includeReasoning,
                upToMessageID: nil
            )
            applyExportOutput(output)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func applyExportOutput(_ output: ChatTranscriptExportOutput) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
        do {
            try output.data.write(to: fileURL, options: .atomic)
            exportSharePayload = ChatExportSharePayload(fileURL: fileURL)
        } catch {
            exportErrorMessage = String(
                format: NSLocalizedString("导出失败：%@", comment: "Export failed alert message"),
                error.localizedDescription
            )
        }
    }

    private func downloadImagesToPhotoLibrary(fileNames: [String]) async {
        do {
            try await saveImagesToPhotoLibrary(fileNames: fileNames)
            await MainActor.run {
                imageDownloadAlertMessage = NSLocalizedString("已保存到相册。", comment: "Saved to photo library")
            }
        } catch {
            await MainActor.run {
                imageDownloadAlertMessage = String(
                    format: NSLocalizedString("保存失败: %@", comment: "Save generated image failed"),
                    error.localizedDescription
                )
            }
        }
    }

    private func saveImagesToPhotoLibrary(fileNames: [String]) async throws {
        let fileURLs = fileNames.map { Persistence.getImageDirectory().appendingPathComponent($0) }
        guard fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "ChatViewImageDownload",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("图片文件不存在。", comment: "Generated image file missing")]
            )
        }

        let status = await requestPhotoLibraryAccessStatus()
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "ChatViewImageDownload",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("没有相册访问权限。", comment: "Photo library permission denied")]
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                for fileURL in fileURLs {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "ChatViewImageDownload",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("保存到相册失败。", comment: "Failed to save image to photo library")]
                    ))
                }
            }
        }
    }

    private func requestPhotoLibraryAccessStatus() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private struct SafeAreaBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollDistanceToBottomObserver: UIViewRepresentable {
    let onDistanceChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDistanceChange: onDistanceChange)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onDistanceChange = onDistanceChange
        uiView.coordinator = context.coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
        }
    }

    final class Coordinator {
        var onDistanceChange: (CGFloat) -> Void
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        init(onDistanceChange: @escaping (CGFloat) -> Void) {
            self.onDistanceChange = onDistanceChange
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                notifyDistanceChange()
                return
            }

            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
        }

        private func notifyDistanceChange() {
            guard let scrollView else { return }
            let visibleMaxY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(scrollView.contentSize.height - visibleMaxY, 0)
            onDistanceChange(distanceToBottom)
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToScrollViewIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
        }

        func attachToScrollViewIfNeeded() {
            guard let coordinator, let scrollView = enclosingScrollView() else { return }
            coordinator.attach(to: scrollView)
        }

        private func enclosingScrollView() -> UIScrollView? {
            var currentSuperview = superview
            while let view = currentSuperview {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                currentSuperview = view.superview
            }
            return nil
        }
    }
}

// MARK: - Helpers

private extension ChatView {
    func resolvePendingSearchJumpIfNeeded() {
        guard let target = viewModel.pendingSearchJumpTarget,
              viewModel.currentSession?.id == target.sessionID,
              !viewModel.allMessagesForSession.isEmpty else {
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

    func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, nextMessage)
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
        animated: Bool = true,
        animation: Animation = .easeOut(duration: 0.25)
    ) {
        let action = {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(animation) {
                action()
            }
        } else {
            action()
        }
    }

    func handleScrollToBottomButtonTap(proxy: ScrollViewProxy) {
        pendingHistoryResetWorkItem?.cancel()

        let shouldAnimate = shouldAnimateScrollToBottomButton
        let shouldResetHistoryWindow = viewModel.lazyLoadMessageCount > 0
        showScrollToBottom = false
        scrollToBottom(
            proxy: proxy,
            animated: shouldAnimate,
            animation: scrollToBottomButtonAnimation
        )

        guard shouldResetHistoryWindow else {
            pendingHistoryResetWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                viewModel.resetLazyLoadState()
            }
            scrollToBottom(proxy: proxy, animated: false)
            pendingHistoryResetWorkItem = nil
        }
        pendingHistoryResetWorkItem = workItem

        let delay = shouldAnimate ? 0.56 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func scheduleImmediateBottomSnap(proxy: ScrollViewProxy) {
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy, animated: false)
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            needsImmediateBottomSnap = false
            pendingBottomSnapTask = nil
        }
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat) {
        let normalizedDistance = max(distanceToBottom, 0)
        DispatchQueue.main.async {
            scrollDistanceToBottom = normalizedDistance
            guard !viewModel.displayMessages.isEmpty else {
                if showScrollToBottom {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showScrollToBottom = false
                    }
                }
                return
            }
            let shouldShow = normalizedDistance > 48
            if showScrollToBottom != shouldShow {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottom = shouldShow
                }
            }
        }
    }

    private var shouldAnimateScrollToBottomButton: Bool {
        let screenHeight = max(UIScreen.main.bounds.height, 1)
        return scrollDistanceToBottom <= screenHeight * longDistanceScrollAnimationThresholdScreens
    }

}

private struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}

// MARK: - Telegram Default Background

private struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

/// Telegram 风格默认背景（浅色图案）
private struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 基础渐变背景
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.1, blue: 0.12)]
                        : [Color(red: 0.85, green: 0.9, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // 图案覆盖层（模拟 Telegram 的微妙图案）
                TelegramPatternView()
                    .opacity(colorScheme == .dark ? 0.03 : 0.05)
            }
        }
        .ignoresSafeArea()
    }
}

/// Telegram 风格背景图案
private struct TelegramPatternView: View {
    var body: some View {
        Canvas { context, size in
            let patternSize: CGFloat = 60
            let iconSize: CGFloat = 16
            
            for row in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                for col in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                    let offset = Int(row / patternSize) % 2 == 0 ? 0 : patternSize / 2
                    let x = col + offset
                    let y = row
                    
                    // 随机选择不同的图标
                    let iconIndex = Int(x + y) % 4
                    let symbolName: String
                    switch iconIndex {
                    case 0: symbolName = "bubble.left.fill"
                    case 1: symbolName = "heart.fill"
                    case 2: symbolName = "star.fill"
                    default: symbolName = "paperplane.fill"
                    }
                    
                    if let symbol = context.resolveSymbol(id: symbolName) {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                    } else {
                        // 绘制简单的圆形作为后备
                        let rect = CGRect(x: x - iconSize/2, y: y - iconSize/2, width: iconSize, height: iconSize)
                        context.fill(Circle().path(in: rect), with: .color(.gray))
                    }
                }
            }
        } symbols: {
            Image(systemName: "bubble.left.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")
            
            Image(systemName: "heart.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")
            
            Image(systemName: "star.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")
            
            Image(systemName: "paperplane.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}

// MARK: - Telegram Message Composer

private enum AudioRecorderEntryMode {
    case attachment
    case speechInput
}

private struct AskUserInputComposerPanel: View {
    let request: AppToolAskUserInputRequest
    let submitAction: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let cancelAction: () -> Void

    @State private var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var otherTextByQuestion: [String: String] = [:]
    @State private var currentQuestionIndex = 0
    @State private var measuredQuestionContentHeight: CGFloat = 0

    private var canSubmit: Bool {
        request.questions.allSatisfy { question in
            !question.required || isQuestionAnswered(question)
        }
    }

    private var currentQuestion: AppToolAskUserInputQuestion? {
        guard request.questions.indices.contains(currentQuestionIndex) else { return nil }
        return request.questions[currentQuestionIndex]
    }

    private var progressText: String {
        let total = max(request.questions.count, 1)
        let current = min(currentQuestionIndex + 1, total)
        return "\(current) / \(total)"
    }

    private var questionContentMaxHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.42, 340)
    }

    private var questionContentFrameHeight: CGFloat {
        let measured = measuredQuestionContentHeight
        guard measured > 1 else { return 180 }
        return min(max(measured + 4, 120), questionContentMaxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar

            if let question = currentQuestion {
                questionContent(for: question)
                navigationInputBar(for: question)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("暂无可填写问题", comment: ""))
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        .onAppear {
            resetSelectionState()
        }
        .onChange(of: request) {
            resetSelectionState()
        }
        .onChange(of: currentQuestionIndex) {
            measuredQuestionContentHeight = 0
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: goToPreviousQuestion) {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(currentQuestionIndex == 0)
                .opacity(currentQuestionIndex == 0 ? 0.45 : 1)

                Spacer(minLength: 6)

                HStack(spacing: 8) {
                    Text(progressText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("取消", comment: ""), action: cancelAction)
                        .etFont(.footnote)
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.title ?? NSLocalizedString("请补充信息", comment: ""))
                    .etFont(.headline)
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .padding(.leading, 2)
        }
    }

    private func questionContent(for question: AppToolAskUserInputQuestion) -> some View {
        ScrollView {
            questionBlock(question)
                .padding(.vertical, 2)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AskUserInputQuestionContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                )
        }
        .frame(height: questionContentFrameHeight, alignment: .top)
        .onPreferenceChange(AskUserInputQuestionContentHeightPreferenceKey.self) { newHeight in
            measuredQuestionContentHeight = newHeight
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: AppToolAskUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(question.question)
                    .etFont(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if question.required {
                    Text("*")
                        .foregroundStyle(.red)
                        .etFont(.subheadline.weight(.bold))
                }
            }

            ForEach(question.options) { option in
                Button {
                    toggleOption(question: question, optionID: option.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: optionIconName(question: question, optionID: option.id))
                            .foregroundStyle(.blue)
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .etFont(.subheadline)
                                .foregroundStyle(.primary)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .disabled(
                    !AppToolAskUserInputAnswerPolicy.canSelectOption(
                        type: question.type,
                        customText: otherTextByQuestion[question.id]
                    )
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func navigationInputBar(for question: AppToolAskUserInputQuestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString("请输入自定义偏好", comment: ""),
                text: Binding(
                    get: { otherTextByQuestion[question.id, default: ""] },
                    set: { newValue in
                        otherTextByQuestion[question.id] = newValue
                        if AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(
                            type: question.type,
                            customText: newValue
                        ) {
                            selectedOptionIDsByQuestion[question.id] = []
                        }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.plain)

            Button(skipButtonTitle(for: question)) {
                handleSkipOrSubmit(for: question)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue(from: question))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private func optionIconName(question: AppToolAskUserInputQuestion, optionID: String) -> String {
        let isSelected = selectedOptionIDsByQuestion[question.id, default: []].contains(optionID)
        switch question.type {
        case .singleSelect:
            return isSelected ? "largecircle.fill.circle" : "circle"
        case .multiSelect:
            return isSelected ? "checkmark.square.fill" : "square"
        }
    }

    private func toggleOption(question: AppToolAskUserInputQuestion, optionID: String) {
        guard AppToolAskUserInputAnswerPolicy.canSelectOption(
            type: question.type,
            customText: otherTextByQuestion[question.id]
        ) else {
            return
        }
        switch question.type {
        case .singleSelect:
            let current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                selectedOptionIDsByQuestion[question.id] = []
            } else {
                selectedOptionIDsByQuestion[question.id] = [optionID]
                autoAdvanceIfNeeded(afterSelecting: question)
            }
        case .multiSelect:
            var current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                current.remove(optionID)
            } else {
                current.insert(optionID)
            }
            selectedOptionIDsByQuestion[question.id] = current
        }
    }

    private func autoAdvanceIfNeeded(afterSelecting question: AppToolAskUserInputQuestion) {
        guard question.type == .singleSelect else { return }
        if isLastQuestion(question) {
            if canSubmit {
                submit()
            }
            return
        }
        guard canContinue(from: question) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
    }

    private func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex -= 1
        }
    }

    private func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
    }

    private func isQuestionAnswered(_ question: AppToolAskUserInputQuestion) -> Bool {
        let selected = selectedOptionIDsByQuestion[question.id] ?? []
        return AppToolAskUserInputAnswerPolicy.hasAnswer(
            selectedOptionIDs: selected,
            customText: otherTextByQuestion[question.id]
        )
    }

    private func canContinue(from question: AppToolAskUserInputQuestion) -> Bool {
        if isLastQuestion(question) {
            return canSubmit
        }
        return true
    }

    private func isLastQuestion(_ question: AppToolAskUserInputQuestion) -> Bool {
        request.questions.last?.id == question.id
    }

    private func skipButtonTitle(for question: AppToolAskUserInputQuestion) -> String {
        if isLastQuestion(question) {
            return request.submitLabel
        }
        return isQuestionAnswered(question) ? NSLocalizedString("下一题", comment: "") : NSLocalizedString("跳过", comment: "")
    }

    private func submit() {
        let answers = request.questions.map { question -> AppToolAskUserInputQuestionAnswer in
            let selectedIDs = question.options
                .map(\.id)
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0) }
            let selectedLabels = question.options
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0.id) }
                .map(\.label)
            let otherText = AppToolAskUserInputAnswerPolicy.normalizedCustomText(
                otherTextByQuestion[question.id]
            )

            return AppToolAskUserInputQuestionAnswer(
                questionID: question.id,
                question: question.question,
                type: question.type,
                selectedOptionIDs: selectedIDs,
                selectedOptionLabels: selectedLabels,
                otherText: otherText
            )
        }
        submitAction(answers)
    }

    private func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
        measuredQuestionContentHeight = 0
    }
}

private struct AskUserInputQuestionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Telegram 风格的消息输入框
private struct TelegramMessageComposer: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showAudioRecorder = false
    @State private var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State private var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State private var showAudioImporter = false
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isExpandedComposer = false
    @State private var inputAvailableWidth: CGFloat = 0
    @State private var compactInputWidth: CGFloat = 0
    
    private let controlSize: CGFloat = 40
    private let expandedControlSize: CGFloat = 34
    private let compactInputHeight: CGFloat = 44
    private var expandedInputHeight: CGFloat {
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160, min(rawHeight, 360))
    }
    private let inputFont = UIFont.systemFont(ofSize: 16)
    private let textContainerInset: CGFloat = 8
    private let textHorizontalPadding: CGFloat = 10
    private let compactTextVerticalPadding: CGFloat = 4
    private let expandedTextVerticalPadding: CGFloat = 6
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    private var composerCornerRadius: CGFloat {
        isExpandedComposer ? 18 : compactInputHeight / 2
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
                telegramAttachmentPreview
                    .padding(.horizontal, 16)
            }
            
            // 主输入栏
            HStack(alignment: .bottom, spacing: 12) {
                if !isExpandedComposer {
                    attachmentMenuButton(size: controlSize)
                }
                
                // 输入框容器
                HStack(alignment: .bottom, spacing: 8) {
                    inputEditor
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: controlSize)
                .background(glassRoundedBackground(cornerRadius: composerCornerRadius))
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: InputWidthKey.self, value: proxy.size.width)
                    }
                }
                .onPreferenceChange(InputWidthKey.self) { width in
                    if abs(width - inputAvailableWidth) > 0.5 {
                        inputAvailableWidth = width
                    }
                    if !isExpandedComposer, abs(width - compactInputWidth) > 0.5 {
                        compactInputWidth = width
                    }
                }
                
                // 麦克风 / 发送 / 停止按钮
                if !isExpandedComposer {
                    actionControlButton(size: controlSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)

        }
        .padding(.bottom, 6)
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .onChange(of: text) { _, newValue in
            handleAutoExpand(for: newValue)
        }
        .onChange(of: inputAvailableWidth) { _, _ in
            handleAutoExpand(for: text)
        }
        .onChange(of: showAudioRecorder) { _, presented in
            if presented {
                audioRecorderSheetDetent = .fraction(0.5)
            }
        }
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if isFocused {
                handleAutoExpand(for: text)
            } else if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker(isPresented: $showCamera) { image in
                if let image {
                    viewModel.addImageAttachment(image)
                }
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(
                format: viewModel.audioRecordingFormat,
                mode: recorderMode,
                transcribeRemotely: { model, attachment in
                    try await viewModel.transcribeAudioAttachment(using: model, attachment: attachment)
                },
                onCompleteAudio: { attachment in
                    viewModel.setAudioAttachment(attachment)
                },
                onCompleteTranscript: { transcript in
                    viewModel.appendTranscribedText(transcript)
                }
            )
            .presentationDetents([.fraction(0.5), .large], selection: $audioRecorderSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importAudioAttachment(from: url)
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    importFileAttachment(from: url)
                }
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func attachmentMenuButton(size: CGFloat) -> some View {
        Menu {
            Button {
                showImagePicker = true
            } label: {
                Label(NSLocalizedString("选择图片", comment: ""), systemImage: "photo")
            }

            Button {
                showCamera = true
            } label: {
                Label(NSLocalizedString("拍照", comment: ""), systemImage: "camera")
            }
            .disabled(!isCameraAvailable)

            Button {
                audioRecorderEntryMode = .attachment
                showAudioRecorder = true
            } label: {
                Label(NSLocalizedString("录制语音", comment: ""), systemImage: "waveform")
            }

            Button {
                showAudioImporter = true
            } label: {
                Label(NSLocalizedString("从录音备忘录上传", comment: ""), systemImage: "music.note.list")
            }

            Button {
                showFileImporter = true
            } label: {
                Label(NSLocalizedString("选择文件", comment: ""), systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)
                .frame(width: size, height: size)
                .background(glassCircleBackground)
        }
        .buttonStyle(.plain)
    }

    private func actionControlButton(size: CGFloat) -> some View {
        Button {
            if isSending {
                stopAction()
            } else if hasContent {
                sendAction()
            } else if viewModel.enableSpeechInput {
                audioRecorderEntryMode = .speechInput
                showAudioRecorder = true
            } else {
                focus.wrappedValue = true
            }
        } label: {
            Image(systemName: actionIconName)
                .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(actionForegroundColor)
                .frame(width: size, height: size)
                .background(actionBackground)
        }
        .buttonStyle(.plain)
        .disabled(!isSending && hasContent && !viewModel.canSendMessage)
    }

    @ViewBuilder
    private var inputEditor: some View {
        let targetHeight = isExpandedComposer ? expandedInputHeight : compactInputHeight
        let verticalPadding = isExpandedComposer ? expandedTextVerticalPadding : compactTextVerticalPadding

        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .etFont(.system(size: inputFont.pointSize))
                .focused(focus)
                .scrollContentBackground(.hidden)
                .scrollDisabled(!isExpandedComposer)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, textHorizontalPadding)

            if text.isEmpty {
                Text("Message")
                    .etFont(.system(size: inputFont.pointSize))
                    .foregroundColor(.secondary)
                    .padding(.top, verticalPadding + textContainerInset)
                    .padding(.leading, textHorizontalPadding + textContainerInset)
            }
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpandedComposer)
    }

    private var recorderMode: AudioRecorderSheet.Mode {
        guard audioRecorderEntryMode == .speechInput, viewModel.enableSpeechInput else {
            return .audioAttachment
        }
        guard !viewModel.sendSpeechAsAudio else {
            return .audioAttachment
        }
        if let model = viewModel.selectedSpeechModel ?? viewModel.speechModels.first {
            return .speechToText(model: model)
        }
        return .audioAttachment
    }

    private func handleAutoExpand(for newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if isExpandedComposer {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpandedComposer = false
                }
            }
            return
        }

        let hasExplicitNewline = newValue.contains("\n")
        var shouldExpand = hasExplicitNewline

        if !shouldExpand {
            let baseWidth = compactInputWidth > 0 ? compactInputWidth : inputAvailableWidth
            let availableWidth = baseWidth
                - textHorizontalPadding * 2
                - textContainerInset * 2
            if availableWidth > 0 {
                let boundingRect = (newValue as NSString).boundingRect(
                    with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: inputFont],
                    context: nil
                )
                let lineCount = max(1, Int(ceil(boundingRect.height / inputFont.lineHeight)))
                shouldExpand = lineCount > 1
            }
        }

        if shouldExpand {
            guard focus.wrappedValue else { return }
            guard !isExpandedComposer else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = true
            }
            focus.wrappedValue = true
        } else if isExpandedComposer {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpandedComposer = false
            }
        }
    }

    private struct InputWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
    
    /// Telegram 风格附件预览
    @ViewBuilder
    private var telegramAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .etFont(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("语音消息", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(audio.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }

                // 文件预览
                ForEach(viewModel.pendingFileAttachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("文件", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(attachment.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.removePendingFileAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            glassRoundedBackground(cornerRadius: 18)
        )
    }

    private var hasContent: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = viewModel.pendingAudioAttachment != nil || !viewModel.pendingImageAttachments.isEmpty || !viewModel.pendingFileAttachments.isEmpty
        return hasText || hasAttachments
    }

    private func importAudioAttachment(from url: URL) {
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = await AudioAttachment(
                    data: data,
                    mimeType: audioMimeType(for: url),
                    format: audioFormat(for: url),
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.setAudioAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func importFileAttachment(from url: URL) {
        let mimeType = resolvedFileMimeType(for: url)
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = FileAttachment(
                    data: data,
                    mimeType: mimeType,
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.addFileAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private func fileMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private func audioMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return ext.isEmpty ? "audio/m4a" : "audio/\(ext)"
    }

    private func audioFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? AudioRecordingFormat.aac.fileExtension : ext
    }
    
    private var actionIconName: String {
        if isSending {
            return "stop.fill"
        }
        if hasContent {
            return "arrow.up"
        }
        if viewModel.enableSpeechInput {
            return "mic.fill"
        }
        return "arrow.up"
    }
    
    private var actionForegroundColor: Color {
        if isSending || hasContent {
            return .white
        }
        return TelegramColors.attachButtonColor
    }
    
    @ViewBuilder
    private var actionBackground: some View {
        if isSending {
            actionCircleBackground(fill: Color.red.opacity(0.85))
        } else if hasContent {
            let fillColor = viewModel.canSendMessage
                ? TelegramColors.sendButtonColor
                : Color.gray.opacity(0.3)
            actionCircleBackground(fill: fillColor)
        } else {
            glassCircleBackground
        }
    }
    
    @ViewBuilder
    private func actionCircleBackground(fill: Color) -> some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(fill)
                    .glassEffect(.clear, in: Circle())
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                Circle()
                    .fill(fill)
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        } else {
            Circle()
                .fill(fill)
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        }
    }

    private var glassCircleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Circle())
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }
    
    private var glassCapsuleBackground: some View {
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Capsule())
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Capsule()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }

    private func glassRoundedBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        shape
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }
    
    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }
    
    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }
    
    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}

// MARK: - Legacy Composer (kept for compatibility)

private struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var audioRecorderSheetDetent: PresentationDetent = .fraction(0.5)
    @State private var audioRecorderEntryMode: AudioRecorderEntryMode = .attachment
    @State private var showFileImporter = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil || !viewModel.pendingFileAttachments.isEmpty {
                attachmentPreviewBar
                    .padding(.horizontal, 12)
            }
            
            HStack(alignment: .center, spacing: 12) {
                // 加号按钮（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .confirmationDialog(NSLocalizedString("添加附件", comment: ""), isPresented: $showAttachmentMenu) {
                        Button(NSLocalizedString("选择图片", comment: "")) {
                            showImagePicker = true
                        }
                        Button(NSLocalizedString("录制语音", comment: "")) {
                            audioRecorderEntryMode = .attachment
                            showAudioRecorder = true
                        }
                        Button(NSLocalizedString("选择文件", comment: "")) {
                            showFileImporter = true
                        }
                    }
                } else {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog(NSLocalizedString("添加附件", comment: ""), isPresented: $showAttachmentMenu) {
                        Button(NSLocalizedString("选择图片", comment: "")) {
                            showImagePicker = true
                        }
                        Button(NSLocalizedString("录制语音", comment: "")) {
                            audioRecorderEntryMode = .attachment
                            showAudioRecorder = true
                        }
                        Button(NSLocalizedString("选择文件", comment: "")) {
                            showFileImporter = true
                        }
                    }
                }
                
                // 输入框（拉长的药丸型）
                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.clear, in: Capsule())
                } else {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .secondarySystemFill))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
                
                // 发送箭头（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .disabled(!viewModel.canSendMessage)
                } else {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .etFont(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .onChange(of: showAudioRecorder) { _, presented in
            if presented {
                audioRecorderSheetDetent = .fraction(0.5)
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(
                format: viewModel.audioRecordingFormat,
                mode: recorderMode,
                transcribeRemotely: { model, attachment in
                    try await viewModel.transcribeAudioAttachment(using: model, attachment: attachment)
                },
                onCompleteAudio: { attachment in
                    viewModel.setAudioAttachment(attachment)
                },
                onCompleteTranscript: { transcript in
                    viewModel.appendTranscribedText(transcript)
                }
            )
            .presentationDetents([.fraction(0.5), .large], selection: $audioRecorderSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    importFileAttachment(from: url)
                }
            case .failure(let error):
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    private var recorderMode: AudioRecorderSheet.Mode {
        guard audioRecorderEntryMode == .speechInput, viewModel.enableSpeechInput else {
            return .audioAttachment
        }
        guard !viewModel.sendSpeechAsAudio else {
            return .audioAttachment
        }
        if let model = viewModel.selectedSpeechModel ?? viewModel.speechModels.first {
            return .speechToText(model: model)
        }
        return .audioAttachment
    }
    
    @ViewBuilder
    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .etFont(.system(size: 16))
                            .foregroundStyle(.tint)
                        
                        Text(audio.fileName)
                            .etFont(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // 文件预览
                ForEach(viewModel.pendingFileAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 16))
                            .foregroundStyle(.tint)
                        
                        Text(attachment.fileName)
                            .etFont(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 120)
                        
                        Button {
                            viewModel.removePendingFileAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func importFileAttachment(from url: URL) {
        let mimeType = resolvedFileMimeType(for: url)
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = FileAttachment(
                    data: data,
                    mimeType: mimeType,
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.addFileAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    // file MIME type helper lives at file scope (resolvedFileMimeType)
}

// MARK: - Camera Image Picker

private final class PortraitCameraImagePickerController: UIImagePickerController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .portrait
    }

    override var shouldAutorotate: Bool {
        false
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = PortraitCameraImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.onImagePicked(image)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Audio Recorder Sheet

private struct AudioRecorderSheet: View {
    enum Mode {
        case audioAttachment
        case speechToText(model: RunnableModel)
    }

    let format: AudioRecordingFormat
    let mode: Mode
    let transcribeRemotely: ((RunnableModel, AudioAttachment) async throws -> String)?
    let onCompleteAudio: (AudioAttachment) -> Void
    let onCompleteTranscript: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isRecording = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var timer: Timer?
    @State private var liveTranscript: String = ""
    @State private var preparedTranscript: String?
    @State private var hasAppliedPreparedTranscript = false
    @State private var processingErrorMessage: String?
    @State private var isTranscriptionInProgress = false
    @State private var streamingSession: SystemSpeechStreamingSession?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                if isTranscriptionInProgress {
                    ProgressView(NSLocalizedString("正在转换…", comment: ""))
                        .progressViewStyle(.circular)
                    Text(NSLocalizedString("请稍候，正在将语音转换为文本。", comment: ""))
                        .etFont(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // 录音时长显示
                    Text(formatDuration(recordingDuration))
                        .etFont(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(isRecording ? .red : .primary)
                    
                    // 录音按钮
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red : Color.accentColor)
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .etFont(.system(size: 30))
                                .foregroundStyle(isRecording ? .white : (colorScheme == .dark ? .black : .white))
                        }
                    }
                    
                    if isRecording {
                        Text(NSLocalizedString("正在录音...", comment: ""))
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isSpeechToTextMode ? NSLocalizedString("点击开始识别", comment: "") : NSLocalizedString("点击开始录音", comment: ""))
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if isSpeechToTextMode && !liveTranscript.isEmpty {
                        ScrollView {
                            Text(liveTranscript)
                                .etFont(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .frame(maxHeight: 120)
                    }

                    if let processingErrorMessage, !processingErrorMessage.isEmpty {
                        Text(processingErrorMessage)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Spacer()
            }
            .navigationTitle(isSpeechToTextMode ? NSLocalizedString("语音输入", comment: "") : NSLocalizedString("录制语音", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        cancelRecording()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        finishRecording()
                    }
                    .disabled(doneButtonDisabled)
                }
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }
    
    private func startRecording() {
        processingErrorMessage = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        liveTranscript = ""
        if let existingURL = recordingURL {
            try? FileManager.default.removeItem(at: existingURL)
        }
        recordingURL = nil
        audioRecorder = nil
        streamingSession = nil
        if usesSystemStreamingRecognizer {
            startSystemStreamingRecording()
            return
        }
        startFileRecording()
    }

    private func startSystemStreamingRecording() {
        Task { @MainActor in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)

                let speechPermissionGranted = await SystemSpeechRecognizerService.requestAuthorization()
                guard speechPermissionGranted else {
                    processingErrorMessage = NSLocalizedString("语音识别权限被拒绝，请到设置中开启。", comment: "")
                    return
                }

                let streamSession = try SystemSpeechStreamingSession()
                liveTranscript = ""
                try streamSession.start { transcript in
                    Task { @MainActor in
                        liveTranscript = transcript
                    }
                }
                streamingSession = streamSession
                isRecording = true
                startTimer()
            } catch {
                processingErrorMessage = error.localizedDescription
                stopTimer()
                streamingSession = nil
            }
        }
    }

    private func startFileRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
            
            let settings: [String: Any]
            switch format {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                // 默认使用 AAC 格式
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            startTimer()
        } catch {
            // 录音启动失败
            processingErrorMessage = error.localizedDescription
        }
    }
    
    private func stopRecording() {
        stopTimer()
        if usesSystemStreamingRecognizer {
            let transcript = streamingSession?.finish() ?? liveTranscript
            liveTranscript = transcript
            streamingSession = nil
            isRecording = false
            return
        }

        audioRecorder?.stop()
        isRecording = false
    }
    
    private func cancelRecording() {
        stopTimer()
        if isRecording {
            audioRecorder?.stop()
        }
        streamingSession?.stop()
        streamingSession = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
        isRecording = false
        isTranscriptionInProgress = false
        liveTranscript = ""
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        processingErrorMessage = nil
    }
    
    private func finishRecording() {
        processingErrorMessage = nil
        if isRecording {
            stopRecording()
        }

        if usesSystemStreamingRecognizer {
            let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                processingErrorMessage = NSLocalizedString("未识别到有效语音内容。", comment: "")
                return
            }
            onCompleteTranscript(transcript)
            dismiss()
            return
        }

        if case .speechToText = mode,
           let preparedText = preparedTranscript,
           !preparedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !hasAppliedPreparedTranscript {
                onCompleteTranscript(preparedText)
                hasAppliedPreparedTranscript = true
            }
            cleanupRecordedFile()
            dismiss()
            return
        }

        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }

        let attachment = AudioAttachment(
            data: data,
            mimeType: format.mimeType,
            format: format.fileExtension,
            fileName: url.lastPathComponent
        )

        switch mode {
        case .audioAttachment:
            onCompleteAudio(attachment)
            cleanupRecordedFile()
            dismiss()
        case .speechToText(let model):
            isTranscriptionInProgress = true
            Task {
                do {
                    let transcript: String
                    if ChatService.isSystemSpeechRecognizerModel(model) {
                        transcript = try await SystemSpeechRecognizerService.transcribe(
                            audioData: attachment.data,
                            fileExtension: attachment.format
                        )
                    } else if let transcribeRemotely {
                        transcript = try await transcribeRemotely(model, attachment)
                    } else {
                        throw NSError(
                            domain: "AudioRecorderSheet",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前未配置语音转写处理器。", comment: "")]
                        )
                    }

                    await MainActor.run {
                        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTranscript.isEmpty else {
                            processingErrorMessage = NSLocalizedString("未识别到有效语音内容。", comment: "")
                            isTranscriptionInProgress = false
                            return
                        }
                        liveTranscript = trimmedTranscript
                        preparedTranscript = trimmedTranscript
                        if !hasAppliedPreparedTranscript {
                            onCompleteTranscript(trimmedTranscript)
                            hasAppliedPreparedTranscript = true
                        }
                        isTranscriptionInProgress = false
                    }
                } catch {
                    await MainActor.run {
                        processingErrorMessage = error.localizedDescription
                        isTranscriptionInProgress = false
                    }
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingDuration += 0.1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanupRecordedFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
        streamingSession = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
    }

    private var isSpeechToTextMode: Bool {
        if case .speechToText = mode {
            return true
        }
        return false
    }

    private var usesSystemStreamingRecognizer: Bool {
        if case .speechToText(let model) = mode {
            return ChatService.isSystemSpeechRecognizerModel(model)
        }
        return false
    }

    private var doneButtonDisabled: Bool {
        if isTranscriptionInProgress {
            return true
        }
        if usesSystemStreamingRecognizer {
            return isRecording
                ? false
                : liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isSpeechToTextMode,
           let preparedTranscript,
           !preparedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return recordingURL == nil || isRecording
    }
}

// MARK: - Session Picker

/// 会话信息弹窗的数据载体，用于隔离 UI 与业务模型
private struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

/// 会话信息弹窗，展示基础状态与唯一标识
private struct SessionPickerInfoSheet: View {
    let payload: SessionPickerInfoPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话概览", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: "")) {
                        Text(payload.session.name)
                    }
                    LabeledContent(NSLocalizedString("状态", comment: "")) {
                        Text(payload.isCurrent ? NSLocalizedString("当前会话", comment: "") : NSLocalizedString("历史会话", comment: ""))
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(NSLocalizedString("消息数量", comment: "")) {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section(NSLocalizedString("主题提示", comment: "")) {
                        Text(topic)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section(NSLocalizedString("增强提示词", comment: "")) {
                        Text(enhanced)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(NSLocalizedString("会话信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
}

private struct SessionPickerRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let searchSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onExport: (ChatTranscriptExportFormat, Bool) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }

                HStack {
                    Button(NSLocalizedString("保存", comment: "")) {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(NSLocalizedString("取消", comment: "")) {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .etFont(.headline)
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        } else if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .etFont(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(NSLocalizedString("切换到此会话", comment: ""), systemImage: "checkmark.circle")
            }

            Button {
                onRename()
            } label: {
                Label(NSLocalizedString("重命名", comment: ""), systemImage: "pencil")
            }

            Button {
                onBranch(false)
            } label: {
                Label(NSLocalizedString("创建提示词分支", comment: ""), systemImage: "arrow.branch")
            }

            Button {
                onBranch(true)
            } label: {
                Label(NSLocalizedString("复制历史创建分支", comment: ""), systemImage: "arrow.triangle.branch")
            }

            Button {
                onDeleteLastMessage()
            } label: {
                Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward")
            }

            Button {
                onInfo()
            } label: {
                Label(NSLocalizedString("查看会话信息", comment: ""), systemImage: "info.circle")
            }

            Menu {
                Menu(NSLocalizedString("包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, true)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, true)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
                Menu(NSLocalizedString("不包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, false)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, false)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, false)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
            } label: {
                Label(NSLocalizedString("导出会话", comment: ""), systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

// MARK: - Message Info

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
private struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

/// 用于承载完整错误响应内容的数据结构
private struct FullErrorContentPayload: Identifiable {
    let id = UUID()
    let content: String
}

/// 完整错误响应内容弹窗
private struct FullErrorContentSheet: View {
    let payload: FullErrorContentPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.content)
                    .etFont(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(NSLocalizedString("完整响应", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = payload.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

/// 消息详情弹窗，展示消息的唯一标识与位置索引。
private struct MessageInfoSheet: View {
    let payload: MessageInfoPayload
    let onJumpToMessage: (Int) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var jumpInput: String = ""
    @State private var jumpError: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基础信息", comment: "")) {
                    LabeledContent(NSLocalizedString("角色", comment: "")) {
                        Text(roleDescription(payload.message.role))
                    }
                    LabeledContent(NSLocalizedString("列表位置", comment: "")) {
                        Text(
                            String(
                                format: NSLocalizedString("第 %d / %d 条", comment: ""),
                                payload.displayIndex,
                                payload.totalCount
                            )
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("快速定位", comment: "Quick message jump section title"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)

                        TextField(
                            String(
                                format: NSLocalizedString("输入消息序号（1-%d）", comment: "Message index input placeholder"),
                                payload.totalCount
                            ),
                            text: $jumpInput
                        )
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title")) {
                            submitJump()
                        }
                        .buttonStyle(.borderedProminent)

                        if let jumpError, !jumpError.isEmpty {
                            Text(jumpError)
                                .etFont(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                
                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.message.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if let usage = payload.message.tokenUsage, usage.hasData {
                    Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                        if let prompt = usage.promptTokens {
                            LabeledContent(NSLocalizedString("发送 Tokens", comment: "Prompt tokens label")) {
                                Text("\(prompt)")
                            }
                        }
                        if let completion = usage.completionTokens {
                            LabeledContent(NSLocalizedString("接收 Tokens", comment: "Completion tokens label")) {
                                Text("\(completion)")
                            }
                        }
                        if let thinking = usage.thinkingTokens {
                            LabeledContent(NSLocalizedString("思考 Tokens", comment: "Thinking tokens label")) {
                                Text("\(thinking)")
                            }
                        }
                        if let cacheWrite = usage.cacheWriteTokens {
                            LabeledContent(NSLocalizedString("缓存写入 Tokens", comment: "Cache write tokens label")) {
                                Text("\(cacheWrite)")
                            }
                        }
                        if let cacheRead = usage.cacheReadTokens {
                            LabeledContent(NSLocalizedString("缓存读取 Tokens", comment: "Cache read tokens label")) {
                                Text("\(cacheRead)")
                            }
                        }
                        if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                            LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                                Text("\(total)")
                            }
                        } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                            LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                                Text("\(totalOnly)")
                            }
                        }
                    }
                } else if let metrics = payload.message.responseMetrics, metrics.isTokenPerSecondEstimated {
                    Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                        Text(NSLocalizedString("当前响应未返回官方 token 用量（仅有估算速度）。", comment: "No official token usage returned hint"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let metrics = payload.message.responseMetrics,
                   metrics.timeToFirstToken != nil
                    || metrics.totalResponseDuration != nil
                    || metrics.reasoningDuration != nil
                    || metrics.completionTokensForSpeed != nil
                    || metrics.tokenPerSecond != nil {
                    Section(NSLocalizedString("响应测速", comment: "Response speed metrics section title")) {
                        if let firstToken = metrics.timeToFirstToken {
                            LabeledContent(NSLocalizedString("首字时间", comment: "Time to first token")) {
                                Text(formatDuration(firstToken))
                            }
                        }
                        if let totalDuration = metrics.totalResponseDuration {
                            LabeledContent(NSLocalizedString("总回复时间", comment: "Total response time")) {
                                Text(formatDuration(totalDuration))
                            }
                        }
                        if let reasoningDuration = metrics.reasoningDuration {
                            LabeledContent(NSLocalizedString("思考耗时", comment: "Reasoning duration")) {
                                Text(formatDuration(reasoningDuration))
                            }
                        }
                        if let completionTokens = metrics.completionTokensForSpeed {
                            LabeledContent(NSLocalizedString("测速 Tokens", comment: "Tokens used for speed calculation")) {
                                Text("\(completionTokens)")
                            }
                        }
                        if let speed = metrics.tokenPerSecond {
                            LabeledContent(NSLocalizedString("响应速度", comment: "Response speed")) {
                                Text(formatSpeed(speed, estimated: metrics.isTokenPerSecondEstimated))
                            }
                        }
                    }
                }

                if let metrics = payload.message.responseMetrics,
                   let samples = metrics.speedSamples,
                   !samples.isEmpty {
                    Section(NSLocalizedString("流式速度曲线", comment: "Streaming speed chart title")) {
                        MessageInfoStreamingSpeedChart(metrics: metrics)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("消息信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
    
    /// 将消息角色转换为易读的中文描述
        private func roleDescription(_ role: MessageRole) -> String {
            switch role {
            case .system:
                return NSLocalizedString("系统", comment: "")
            case .user:
                return NSLocalizedString("用户", comment: "")
            case .assistant:
                return NSLocalizedString("助手", comment: "")
            case .tool:
                return NSLocalizedString("工具", comment: "")
        case .error:
            return NSLocalizedString("错误", comment: "")
        @unknown default:
            return NSLocalizedString("未知", comment: "")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let clamped = max(0, duration)
        return String(format: "%.2fs", clamped)
    }

    private func formatSpeed(_ speed: Double, estimated: Bool) -> String {
        let base = String(format: "%.2f %@", max(0, speed), NSLocalizedString("token/s", comment: "Tokens per second unit"))
        if estimated {
            return "\(base) (\(NSLocalizedString("估算", comment: "Estimated")))"
        }
        return base
    }

    private func submitJump() {
        let trimmed = jumpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayIndex = Int(trimmed) else {
            jumpError = NSLocalizedString("请输入有效的序号。", comment: "Invalid message index hint")
            return
        }

        guard displayIndex >= 1 && displayIndex <= payload.totalCount else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                payload.totalCount
            )
            return
        }

        guard onJumpToMessage(displayIndex) else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                payload.totalCount
            )
            return
        }

        jumpError = nil
        dismiss()
    }
}

private struct MessageInfoStreamingSpeedChart: View {
    let metrics: MessageResponseMetrics

    private var samples: [MessageResponseMetrics.SpeedSample] {
        let values = metrics.speedSamples ?? []
        return values.sorted { $0.elapsedSecond < $1.elapsedSecond }
    }

    private var currentSpeed: Double {
        max(0, samples.last?.tokenPerSecond ?? metrics.tokenPerSecond ?? 0)
    }

    private var fluctuation: Double? {
        guard samples.count >= 2 else { return nil }
        guard let minSpeed = samples.map(\.tokenPerSecond).min(),
              let maxSpeed = samples.map(\.tokenPerSecond).max() else {
            return nil
        }
        return max(0, maxSpeed - minSpeed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.2f %@", currentSpeed, NSLocalizedString("token/s", comment: "Tokens per second unit")))
                    .etFont(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(NSLocalizedString("每秒采样", comment: "Per-second speed sampling"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let points = normalizedPoints(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))

                    if points.count >= 2 {
                        smoothedAreaPath(points: points, height: proxy.size.height)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        smoothedLinePath(points: points)
                            .stroke(
                                Color.accentColor.opacity(0.9),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                    }

                    if let last = points.last {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .position(last)
                    }
                }
            }
            .frame(height: 96)

            if let fluctuation {
                Text("\(NSLocalizedString("波动", comment: "Speed fluctuation label")) \(String(format: "%.2f %@", fluctuation, NSLocalizedString("token/s", comment: "Tokens per second unit")))")
                    .etFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !samples.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let minSecond = Double(samples.first?.elapsedSecond ?? 0)
        let maxSecond = Double(samples.last?.elapsedSecond ?? 0)
        let secondSpan = max(1, maxSecond - minSecond)
        let maxSpeed = max(1, samples.map(\.tokenPerSecond).max() ?? 1)

        return samples.map { sample in
            let xRatio = (Double(sample.elapsedSecond) - minSecond) / secondSpan
            let yRatio = sample.tokenPerSecond / maxSpeed
            return CGPoint(
                x: xRatio * size.width,
                y: (1 - yRatio) * size.height
            )
        }
    }

    private func smoothedLinePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 1 else { return path }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
            if index == points.count - 1 {
                path.addQuadCurve(to: current, control: current)
            }
        }
        return path
    }

    private func smoothedAreaPath(points: [CGPoint], height: CGFloat) -> Path {
        var path = smoothedLinePath(points: points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }
}
