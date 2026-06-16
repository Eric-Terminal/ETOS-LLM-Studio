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
import ETOSCore
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
    @State var showBranchOptions = false
    @State var messageToBranch: ChatMessage?
    @State var messageToDelete: ChatMessage?
    @State var messageVersionToDelete: MessageVersionDeletePayload?
    @State var messageActionSheetPayload: MessageActionSheetPayload?
    @State var fullErrorContent: FullErrorContentPayload?
    @State var editingSessionID: UUID?
    @State var sessionDraftName: String = ""
    @State var sessionToDelete: ChatSession?
    @State var sessionInfo: SessionPickerInfoPayload?
    @State var showGhostSessionAlert = false
    @State var ghostSession: ChatSession?
    @State var sessionPickerSearchText: String = ""
    @State var sessionPickerSearchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var sessionPickerFolderID: UUID?
    @State var isSessionPickerSearching: Bool = false
    @State var sessionPickerLatestSearchToken: Int = 0
    @State var sessionPickerPendingSearchWorkItem: DispatchWorkItem?
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
    @State var activeChatPickerDetent: PresentationDetent = .medium
    @State var isChatLayoutLandscape = false
    @State var isLandscapeSessionSidebarPresented = true
    @State var bottomSafeAreaInset: CGFloat = 0
    @State var isKeyboardVisible = false
    @State var chatInputBarHeight: CGFloat = 0
    @State var scrollDistanceToBottom: CGFloat = 0
    @State var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var chatLayoutSettleTask: Task<Void, Never>?
    @State var chatScrollTarget: ChatScrollTargetID?
    @State var chatScrollTargetAnchor: UnitPoint = .bottom
    @State var needsImmediateBottomSnap: Bool = true
    @State var isChatLayoutSettling: Bool = false
    @State var shouldRestorePendingJumpOnAppear: Bool = false
    @State var pendingJumpRequest: MessageJumpRequest?
    @State var localResourceUsagePanelOffset: CGSize = .zero
    @FocusState var composerFocused: Bool
    @FocusState var sessionPickerSearchFocused: Bool

    var draftText: String {
        get { appConfig.chatComposerDraft }
        nonmutating set { appConfig.chatComposerDraft = newValue }
    }

    let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    let navBarVerticalPadding: CGFloat = 8
    let navBarPillVerticalPadding: CGFloat = 6
    let navBarPillSpacing: CGFloat = 1
    let navBarBlurFadeMinHeight: CGFloat = 44
    let navBarBlurFadeMaxHeight: CGFloat = 96
    let navBarBlurFadeHeightRatio: CGFloat = 0.06
    let chatPickerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    let scrollToBottomButtonAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.52)
    let landscapeSessionSidebarMinWidth: CGFloat = 220
    let landscapeSessionSidebarMaxWidth: CGFloat = 300
    let landscapeSessionSidebarWidthRatio: CGFloat = 0.32
    let reasoningPreviewHeightRatio: CGFloat = 0.208
    let reasoningPreviewMinHeight: CGFloat = 118
    let reasoningPreviewMaxHeightLimit: CGFloat = 220
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
    func responsiveReasoningPreviewMaxHeight(for viewportHeight: CGFloat) -> CGFloat {
        let viewportHeight = max(1, viewportHeight)
        guard appConfig.enableResponsiveReasoningPreviewHeight else {
            let percent = appConfig.reasoningPreviewHeightPercent
            let safePercent = percent.isFinite ? max(0, percent) : 0
            return viewportHeight * CGFloat(safePercent / 100)
        }
        let scaledHeight = viewportHeight * reasoningPreviewHeightRatio
        return min(max(scaledHeight, reasoningPreviewMinHeight), reasoningPreviewMaxHeightLimit)
    }
    var usesLandscapeSessionSidebar: Bool {
        isChatLayoutLandscape
    }
    var isModelPickerPresented: Bool {
        activeChatPickerSheet == .model
    }
    var isSessionPickerPresented: Bool {
        if usesLandscapeSessionSidebar {
            return isLandscapeSessionSidebarPresented
        }
        return activeChatPickerSheet == .session
    }
    var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return viewModel.enableLiquidGlass
        }
        return false
    }
    var shouldShowLocalResourceUsageFloatingPanel: Bool {
        appConfig.localModelPerformanceMonitorEnabled
            && LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel)
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
        sessionPickerChildFolders.count + sessionPickerDirectSessions.count
    }
    var sessionPickerSearchResults: [SessionHistorySearchResult] {
        SessionHistorySearchSupport.flattenedResults(
            sessions: sessionPickerSearchSourceSessions,
            hits: sessionPickerSearchHits
        )
    }
    var totalSessionPickerSearchResultCount: Int {
        sessionPickerSearchResults.count
    }
    var hasMoreSessionPickerSessions: Bool {
        loadedSessionPickerSessions.count < sessionPickerDirectSessions.count
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
    var pagedSessionPickerEntries: [SessionMergedEntry] {
        sessionPickerMergedEntries
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
                    landscapeChatLayout(chatViewportSize: proxy.size)
                } else {
                    chatConversationContent(
                        chatViewportWidth: chatViewportWidth,
                        chatViewportSize: proxy.size
                    )
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

}

private struct LocalResourceUsageFloatingPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var resourceUsageMonitor = LocalResourceUsageMonitor.shared
    let containerSize: CGSize
    let topPadding: CGFloat
    let leadingPadding: CGFloat
    @Binding var offset: CGSize
    let isLiquidGlassEnabled: Bool

    @State private var isExpanded = false
    @State private var resourceUsageTask: Task<Void, Never>?
    @State private var dragStartOffset: CGSize?

    private var panelWidth: CGFloat {
        isExpanded ? 248 : 188
    }

    private var panelHeight: CGFloat {
        isExpanded ? max(64, CGFloat(expandedMetricRowCount) * 28 + 20) : 40
    }

    private var panelSize: CGSize {
        CGSize(width: panelWidth, height: panelHeight)
    }

    var body: some View {
        let currentOffset = clampedOffset(offset, panelSize: panelSize)

        panelContent
            .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: isExpanded ? 14 : 18, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                    offset = self.clampedOffset(offset, panelSize: panelSize)
                }
            }
            .simultaneousGesture(dragGesture(panelSize: panelSize))
            .position(
                x: defaultCenter(for: panelSize).x + currentOffset.width,
                y: defaultCenter(for: panelSize).y + currentOffset.height
            )
            .onAppear {
                startSampling()
            }
            .onDisappear {
                stopSampling()
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isExpanded)
            .accessibilityLabel(resourceUsageMonitor.snapshot.displayText)
            .accessibilityAddTraits(.isButton)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            if isExpanded {
                VStack(spacing: 6) {
                    if let cpuPercent = resourceUsageMonitor.snapshot.cpuPercent {
                        resourceUsageMetricRow(
                            iconName: "cpu",
                            title: NSLocalizedString("CPU", comment: "Local resource CPU title"),
                            value: String(format: NSLocalizedString("%.0f%%", comment: "Local resource CPU percent value"), cpuPercent)
                        )
                    }
                    if let gpuAllocatedBytes = resourceUsageMonitor.snapshot.gpuAllocatedBytes,
                       gpuAllocatedBytes > 0 {
                        resourceUsageMetricRow(
                            iconName: "display",
                            title: NSLocalizedString("Metal", comment: "Local resource Metal allocated memory title"),
                            value: formatBytes(gpuAllocatedBytes)
                        )
                    }
                    if let memoryBytes = resourceUsageMonitor.snapshot.memoryBytes {
                        resourceUsageMetricRow(
                            iconName: "memorychip",
                            title: NSLocalizedString("内存", comment: "Local resource memory title"),
                            value: formatBytes(memoryBytes)
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                compactHeader
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isExpanded ? 10 : 8)
        .background(panelBackground(cornerRadius: isExpanded ? 14 : 18))
    }

    private var compactHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)

            Text(compactDisplayText)
                .etFont(.system(size: 12, weight: .semibold), sampleText: compactDisplayText)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .layoutPriority(1)

            Spacer(minLength: 4)

            Image(systemName: "chevron.up")
                .etFont(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    private var expandedMetricRowCount: Int {
        var count = 0
        if resourceUsageMonitor.snapshot.cpuPercent != nil {
            count += 1
        }
        if let gpuAllocatedBytes = resourceUsageMonitor.snapshot.gpuAllocatedBytes, gpuAllocatedBytes > 0 {
            count += 1
        }
        if resourceUsageMonitor.snapshot.memoryBytes != nil {
            count += 1
        }
        return count
    }

    private var compactDisplayText: String {
        var parts: [String] = []
        if let cpuPercent = resourceUsageMonitor.snapshot.cpuPercent {
            parts.append(String(format: NSLocalizedString("%.0f%%", comment: "Local resource compact CPU percent"), cpuPercent))
        }
        if let memoryBytes = resourceUsageMonitor.snapshot.memoryBytes {
            parts.append(formatBytes(memoryBytes))
        }
        return parts.isEmpty ? resourceUsageMonitor.snapshot.displayText : parts.joined(separator: " / ")
    }

    private func resourceUsageMetricRow(iconName: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)
                .frame(width: 14)

            Text(title)
                .etFont(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .etFont(.system(size: 12, weight: .semibold), sampleText: value)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private func dragGesture(panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let startOffset = dragStartOffset ?? offset
                offset = clampedOffset(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
            }
            .onEnded { value in
                let startOffset = dragStartOffset ?? offset
                offset = clampedOffset(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
                dragStartOffset = nil
            }
    }

    private func clampedOffset(_ candidate: CGSize, panelSize: CGSize) -> CGSize {
        let defaultCenter = defaultCenter(for: panelSize)
        let minX = panelSize.width / 2 + 12
        let maxX = max(minX, containerSize.width - panelSize.width / 2 - 12)
        let minY = topPadding + panelSize.height / 2
        let maxY = max(minY, containerSize.height - panelSize.height / 2 - 12)
        let clampedX = min(max(defaultCenter.x + candidate.width, minX), maxX)
        let clampedY = min(max(defaultCenter.y + candidate.height, minY), maxY)
        return CGSize(width: clampedX - defaultCenter.x, height: clampedY - defaultCenter.y)
    }

    private func defaultCenter(for panelSize: CGSize) -> CGPoint {
        CGPoint(
            x: leadingPadding + panelSize.width / 2,
            y: topPadding + panelSize.height / 2
        )
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : StorageUtility.formatSize(Int64(bytes))
    }

    private func startSampling() {
        guard resourceUsageTask == nil else { return }
        resourceUsageTask = Task { @MainActor in
            while !Task.isCancelled {
                resourceUsageMonitor.refresh()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopSampling() {
        resourceUsageTask?.cancel()
        resourceUsageTask = nil
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.fill(glassOverlayColor))
                        .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                        .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
                } else {
                    materialPanelBackground(shape: shape)
                }
            } else {
                materialPanelBackground(shape: shape)
            }
        }
    }

    private func materialPanelBackground(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glassOverlayColor))
            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
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
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: viewModel.allMessagesForSession,
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
                ScrollView {
                    VStack(spacing: 0) {
                        ScrollDistanceToBottomObserver { distanceToBottom in
                            updateScrollToBottomVisibility(distanceToBottom: distanceToBottom)
                        }
                        .frame(width: 0, height: 0)

                        LazyVStack(spacing: 0) {
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
                                    reasoningPreviewMaxHeight: reasoningPreviewMaxHeight,
                                    preparedMarkdownPayload: viewModel.preparedMarkdownByMessageID[message.id],
                                    preparedReasoningMarkdownPayload: viewModel.preparedReasoningMarkdownByMessageID[message.id],
                                    reasoningThinkingTitle: viewModel.reasoningThinkingTitleByMessageID[message.id],
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
                                    onOpenMore: { latestMessage in
                                        messageActionSheetPayload = MessageActionSheetPayload(message: latestMessage)
                                    },
                                    providers: viewModel.providers
                                )
                                // 发送入场动画：用户气泡从右下弹入，助手气泡从左下弹入
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .scale(
                                            scale: 0.92,
                                            anchor: message.role == .user ? .bottomTrailing : .bottomLeading
                                        ))
                                        .combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .id(ChatScrollTargetID.message(state.id))
                                // iMessage 风格滚动波浪：纯位置偏移驱动弹性交错
                                .scrollTransition(
                                    topLeading: .animated(.smooth(duration: 0.4)),
                                    bottomTrailing: .animated(.spring(
                                        response: appConfig.chatScrollAnimationSpringResponse,
                                        dampingFraction: appConfig.chatScrollAnimationSpringDamping
                                    ))
                                ) { [scrollAnimEnabled = appConfig.chatScrollAnimationEnabled,
                                     scrollAnimOffset = appConfig.chatScrollAnimationOffset] content, phase in
                                    content
                                        .offset(y: scrollAnimEnabled ? phase.value * scrollAnimOffset : 0)
                                }
                                .onAppear {
                                    loadMoreAutomaticHistoryIfNeeded(
                                        anchorMessageID: state.id,
                                        isFirstDisplayedMessage: index == 0
                                    )
                                }
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
                .onChange(of: viewModel.streamingScrollAnchorVersion) { _, _ in
                    guard !showScrollToBottom || scrollDistanceToBottom < 80 else { return }
                    scrollToBottom(animated: false)
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
                    handleChatInputBarHeightChange(newHeight)
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
                beginChatLayoutSettling(keepBottomPinned: scrollDistanceToBottom < 120)
                if !isKeyboardVisible {
                    isKeyboardVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                beginChatLayoutSettling(keepBottomPinned: scrollDistanceToBottom < 120)
                if isKeyboardVisible {
                    isKeyboardVisible = false
                }
            }
            .onDisappear {
                pendingHistoryResetWorkItem?.cancel()
                pendingHistoryResetWorkItem = nil
                pendingBottomSnapTask?.cancel()
                pendingBottomSnapTask = nil
                chatLayoutSettleTask?.cancel()
                chatLayoutSettleTask = nil
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
        }
    }
