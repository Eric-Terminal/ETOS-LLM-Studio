// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图文件 
//
// 功能特性:
// - 应用的主界面，负责组合聊天列表和输入框
// - 连接 ChatViewModel 来驱动视图
// - 管理 Sheet 和导航
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - 状态对象
    
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var announcementManager = AnnouncementManager.shared
    @StateObject private var legacyJSONMigrationManager = LegacyJSONMigrationManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject private var progressStore = OnboardingProgressStore.shared
    @State private var isAtBottom = true
    @State private var showScrollToBottomButton = false
    @State private var fullErrorContent: String?
    @State private var isSettingsPresented = false
    @State private var isShowingOnboardingHub = false
    @State private var settingsDestination: WatchSettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    @State private var shouldForceScrollToBottom = false
    @State private var suppressAutoScrollOnce = false
    @State private var pendingJumpRequest: MessageJumpRequest?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var rootBodyFont: Font = .body
    @State private var legacyMigrationErrorMessage: String?
    @AppStorage(FontLibrary.customFontEnabledStorageKey) private var isCustomFontEnabled: Bool = true
    private let inputControlHeight: CGFloat = 38
    private let inputBubbleVerticalPadding: CGFloat = 8
    private let emptyStateSpacerHeight: CGFloat = 120
    private let bottomAnchorID = "inputBubble"
    
    private var isLiquidGlassEnabled: Bool {
        if #available(watchOS 26.0, *) {
            return viewModel.enableLiquidGlass
        } else {
            return false
        }
    }
    
    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            // 背景图
            if viewModel.enableBackground, let bgImage = viewModel.currentBackgroundImageBlurredUIImage {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(white: 0.95)
                        }
                        
                        Image(uiImage: bgImage)
                            .resizable()
                            .aspectRatio(contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit)
                            .frame(width: size.width, height: size.height)
                            .position(x: size.width / 2, y: size.height / 2)
                            .clipped()
                            .opacity(viewModel.backgroundOpacity)
                    }
                    .frame(width: size.width, height: size.height)
                }
                .ignoresSafeArea()
            }
            
            // 主导航
            NavigationStack {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatList(proxy: proxy)

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
                .navigationTitle(viewModel.currentSession?.name ?? "新对话")
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView(viewModel: viewModel, requestedDestination: $settingsDestination)
                }
                .sheet(isPresented: $isShowingOnboardingHub) {
                    NavigationStack {
                        OnboardingHubView(viewModel: viewModel)
                    }
                }
                .sheet(item: $viewModel.activeSheet) { item in
                    sheetView(for: item)
                }
                .sheet(item: Binding(
                    get: { fullErrorContent.map { FullErrorContentWrapper(content: $0) } },
                    set: { _ in fullErrorContent = nil }
                )) { wrapper in
                    FullErrorContentView(content: wrapper.content)
                }
                .sheet(item: $viewModel.activeAskUserInputRequest) { request in
                    WatchAskUserInputView(
                        request: request,
                        onSubmit: { answers in
                            viewModel.submitAskUserInputAnswers(answers, for: request)
                        },
                        onCancel: {
                            viewModel.cancelAskUserInputRequest(using: request)
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenDailyPulse)) { _ in
                openDailyPulse()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenFeedback)) { _ in
                openFeedbackFromNotification()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenChatSession)) { _ in
                openChatSessionFromNotification()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
                Task { @MainActor in
                    applyDailyPulseContinuationIfNeeded()
                }
            }
            .onChange(of: viewModel.activeSheet) {
                if viewModel.activeSheet == nil {
                    viewModel.saveCurrentSessionDetails()
                }
            }

            if let notice = viewModel.memoryRetryStoppedNoticeMessage {
                VStack {
                    memoryRetryStoppedNoticeBanner(text: notice)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }

            if !progressStore.isHintDismissed(.chatMessages) && !progressStore.isGuideCompleted(.firstChat) {
                VStack {
                    WatchOnboardingHintCard(
                        title: "新手提示",
                        message: "手表端聊天页先试左滑消息看更多，再回设置页进入历史会话练右滑删除。",
                        actionTitle: "查看新手教程",
                        onAction: {
                            isShowingOnboardingHub = true
                        },
                        onDismiss: {
                            progressStore.dismissHint(.chatMessages)
                        }
                    )
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(19)
            }

            VStack {
                Spacer()
                TTSFloatingController()
            }
        }
        .environment(\.font, rootBodyFont)
        .onAppear {
            refreshRootBodyFont()
            progressStore.markVisited(.chat)
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .sheet(isPresented: $legacyJSONMigrationManager.isMigrationPromptPresented) {
            NavigationStack {
                legacyJSONMigrationPromptSheet
            }
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: Binding(
            get: { legacyJSONMigrationManager.isMigrating },
            set: { _ in }
        )) {
            NavigationStack {
                legacyJSONMigrationProgressSheet
            }
            .interactiveDismissDisabled(true)
        }
        .alert(
            "是否清理旧版 JSON 文件？",
            isPresented: $legacyJSONMigrationManager.isCleanupPromptPresented
        ) {
            Button("保留", role: .cancel) {
                legacyJSONMigrationManager.keepLegacyJSONForNow()
            }
            Button("删除") {
                legacyJSONMigrationManager.cleanupLegacyJSONArtifacts()
            }
        } message: {
            Text("SQLite 迁移完成后，建议删除旧 JSON 释放空间。")
        }
        .alert("迁移失败", isPresented: Binding(
            get: { legacyMigrationErrorMessage != nil },
            set: { if !$0 { legacyMigrationErrorMessage = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(legacyMigrationErrorMessage ?? "")
        }
        .onReceive(legacyJSONMigrationManager.$errorMessage) { message in
            guard let message, !message.isEmpty else { return }
            legacyMigrationErrorMessage = message
        }
        .onReceive(NotificationCenter.default.publisher(for: .legacyJSONMigrationDidFinish)) { _ in
            viewModel.reloadPersistedDataAfterLegacyJSONMigration()
        }
        .task {
            legacyJSONMigrationManager.refreshStatus()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
    }
    
    // MARK: - 视图组件

    private func memoryRetryStoppedNoticeBanner(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(text)
                .etFont(.footnote)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.memoryRetryStoppedNoticeMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .etFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func sheetView(for item: ActiveSheet) -> some View {
        // 修复: 增加 @unknown default 来处理未来可能的 case
        switch item {
        case .editMessage:
            // 修复: 将 var 改为 let，因为该变量未被修改
            if let messageToEdit = viewModel.messageToEdit {
                EditMessageView(message: messageToEdit, onSave: { updatedMessage in
                    viewModel.commitEditedMessage(updatedMessage)
                })
            }
        case .settings:
            SettingsView(viewModel: viewModel)
        @unknown default:
            Text("未知视图")
        }
    }
    
    private func chatList(proxy: ScrollViewProxy) -> some View {
        let displayedMessages = viewModel.displayMessages
        return List {
            if viewModel.messages.isEmpty {
                Spacer().frame(height: emptyStateSpacerHeight).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            
            let remainingCount = viewModel.remainingHistoryCount
            if !viewModel.isHistoryFullyLoaded && remainingCount > 0 {
                let chunk = viewModel.historyLoadChunkCount
                Button(action: {
                    suppressAutoScrollOnce = true
                    withAnimation {
                        viewModel.loadMoreHistoryChunk()
                    }
                }) {
                    Label(
                        String(format: NSLocalizedString("向上加载 %d 条记录", comment: ""), chunk),
                        systemImage: "arrow.up.circle"
                    )
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
            }

            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, state in
                let message = state.message
                let previousMessage = index > 0 ? displayedMessages[index - 1].message : nil
                let nextMessage = index + 1 < displayedMessages.count ? displayedMessages[index + 1].message : nil
                let mergeWithPrevious = shouldMergeTurnMessages(previousMessage, with: message)
                let mergeWithNext = shouldMergeTurnMessages(message, with: nextMessage)
                messageRow(
                    for: state,
                    mergeWithPrevious: mergeWithPrevious,
                    mergeWithNext: mergeWithNext
                )
            }

            if viewModel.activeAskUserInputRequest == nil {
                inputBubble
                    .id(bottomAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .onAppear { isAtBottom = true; showScrollToBottomButton = false }
                    .onDisappear { isAtBottom = false; showScrollToBottomButton = true }
            } else {
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: {
                    viewModel.activeSheet = nil
                    isSettingsPresented = true
                }) {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .onChange(of: viewModel.messages.count) {
            if suppressAutoScrollOnce {
                suppressAutoScrollOnce = false
                return
            }
            let shouldScroll = isAtBottom || shouldForceScrollToBottom
            shouldForceScrollToBottom = false
            guard shouldScroll else { return }
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
    }

    private func refreshRootBodyFont() {
        rootBodyFont = AppFontAdapter.adaptedFont(
            from: .body,
            sampleText: "The quick brown fox 你好こんにちは"
        )
    }

    private var legacyJSONMigrationPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测到旧版 JSON 数据")
                .etFont(.headline)
            Text("建议立即迁移到 SQLite，后续版本可能不再支持旧格式。迁移会在后台分批执行，尽量避免卡顿。")
                .etFont(.footnote)
                .foregroundStyle(.secondary)

            if let status = legacyJSONMigrationManager.status {
                Text(String(format: "预计 %.1f MB，约 %d 个会话", status.estimatedLegacyMegabytes, status.estimatedSessionCount))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("立即迁移（推荐）") {
                legacyJSONMigrationManager.startMigration()
            }
            .buttonStyle(.borderedProminent)

            Button("稍后再说") {
                legacyJSONMigrationManager.postponeMigrationPrompt()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .navigationTitle("数据迁移")
    }

    private var legacyJSONMigrationProgressSheet: some View {
        VStack(spacing: 10) {
            Text("正在迁移")
                .etFont(.headline)
            if let progress = legacyJSONMigrationManager.progress {
                ProgressView(value: progress.fractionCompleted)
                Text("会话 \(progress.processedSessions)/\(max(progress.totalSessions, progress.processedSessions))")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Text("消息 \(progress.importedMessages)")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text("迁移完成后会再询问是否删除旧 JSON。")
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .navigationTitle("迁移中")
    }
    
    /// 辅助函数，用于构建单个消息行，以简化 chatList 的主体
    @ViewBuilder
    private func messageRow(for state: ChatMessageRenderState, mergeWithPrevious: Bool, mergeWithNext: Bool) -> some View {
        let message = state.message
        let preparedPayload = viewModel.preparedMarkdownByMessageID[message.id]
        let isReasoningExpandedBinding = Binding<Bool>(
            get: { viewModel.reasoningExpandedState[message.id, default: false] },
            set: { viewModel.reasoningExpandedState[message.id] = $0 }
        )
        
        let isToolCallsExpandedBinding = Binding<Bool>(
            get: { viewModel.toolCallsExpandedState[message.id, default: false] },
            set: { viewModel.toolCallsExpandedState[message.id] = $0 }
        )
        let showsStreamingIndicators = viewModel.isSendingMessage && viewModel.latestAssistantMessageID == message.id
        let hasActivePermission = hasActiveToolPermissionRequest(for: message)

        let bubble = ChatBubble(
            messageState: state,
            preparedMarkdownPayload: viewModel.preparedMarkdownByMessageID[message.id],
            isReasoningExpanded: isReasoningExpandedBinding,
            isToolCallsExpanded: isToolCallsExpandedBinding,
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled,
            enableNoBubbleUI: viewModel.enableNoBubbleUI,
            enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
            enableExperimentalToolResultDisplay: true,
            enableMathRendering: viewModel.isMathRenderingEnabled(for: message.id),
            showsStreamingIndicators: showsStreamingIndicators,
            mergeWithPrevious: mergeWithPrevious,
            mergeWithNext: mergeWithNext,
            hasAutoOpenedPendingToolCall: { toolCallID in
                viewModel.hasAutoOpenedPendingToolCall(toolCallID)
            },
            markPendingToolCallAutoOpened: { toolCallID in
                viewModel.markPendingToolCallAutoOpened(toolCallID)
            },
            onCodeBlockHeaderTap: { content in
                viewModel.appendCodeBlockContentToInput(content)
            }
        )
        .id(state.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)

        if hasActivePermission {
            bubble
        } else {
            bubble
                .swipeActions(edge: .leading) {
                    messageActionsNavigationLink(for: message, preparedPayload: preparedPayload)
                }
        }
    }

    private func hasActiveToolPermissionRequest(for message: ChatMessage) -> Bool {
        guard let request = toolPermissionCenter.activeRequest,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return false
        }
        let normalizedRequestArguments = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return toolCalls.contains { call in
            call.toolName == request.toolName
                && call.arguments.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedRequestArguments
        }
    }

    @ViewBuilder
    private func messageActionsNavigationLink(
        for message: ChatMessage,
        preparedPayload: ETPreparedMarkdownRenderPayload?
    ) -> some View {
        NavigationLink {
            MessageActionsView(
                message: message,
                canRetry: viewModel.canRetry(message: message),
                onEdit: {
                    viewModel.messageToEdit = message
                    viewModel.activeSheet = .editMessage
                },
                onRetry: { message in
                    viewModel.retryMessage(message)
                },
                onSpeak: { message in
                    viewModel.speakMessage(message)
                },
                onStopSpeaking: {
                    viewModel.stopSpeakingMessage()
                },
                onDelete: {
                    viewModel.deleteMessage(message)
                },
                onDeleteCurrentVersion: {
                    viewModel.deleteCurrentVersion(of: message)
                },
                onSwitchVersion: { index in
                    viewModel.switchToVersion(index, of: message)
                },
                onBranch: { copyPrompts in
                    _ = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: copyPrompts)
                },
                onShowFullError: { content in
                    fullErrorContent = content
                },
                supportsMathRenderToggle: viewModel.enableAdvancedRenderer && (preparedPayload?.containsMathContent ?? false),
                isMathRenderingEnabled: viewModel.isMathRenderingEnabled(for: message.id),
                onToggleMathRendering: {
                    viewModel.toggleMathRendering(for: message.id)
                },
                onJumpToMessageIndex: { displayIndex in
                    jumpToMessage(displayIndex: displayIndex)
                },
                session: viewModel.currentSession,
                allMessages: viewModel.allMessagesForSession,
                messageIndex: viewModel.allMessagesForSession.firstIndex { $0.id == message.id },
                totalMessages: viewModel.allMessagesForSession.count
            )
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
        .tint(.gray)
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        let scrollAction = {
            // 点击回底按钮时，重置懒加载状态到初始数量
            viewModel.resetLazyLoadState()
            scrollToBottom(proxy: proxy, animated: true)
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

    private func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return isAssistantTurnMessage(message) && isAssistantTurnMessage(nextMessage)
    }

    private func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        @unknown default:
            return false
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
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

    private func jumpToMessage(displayIndex: Int) -> Bool {
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

    private func sendMessage() {
        shouldForceScrollToBottom = true
        viewModel.sendMessage()
    }

    private func sendOrStopMessage() {
        if viewModel.isSendingMessage {
            viewModel.cancelSending()
        } else {
            sendMessage()
        }
    }

    private var inputFillColor: Color {
        viewModel.enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    private var inputStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }
    
    private var transparentInputField: some View {
        ZStack(alignment: .leading) {
            Text(viewModel.userInput.isEmpty ? inputPlaceholderText : viewModel.userInput)
                .foregroundStyle(viewModel.userInput.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
            TextField("", text: $viewModel.userInput.watchKeyboardNewlineBinding())
                .textFieldStyle(.plain)
                .opacity(0.01)
                .accessibilityLabel("输入...")
        }
        .etFont(.body)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: inputControlHeight, maxHeight: inputControlHeight, alignment: .leading)
        .layoutPriority(1)
    }
    
    private var inputBubble: some View {
        let hasTrimmedText = !viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasTrimmedText || viewModel.pendingAudioAttachment != nil
        
        let coreBubble = Group {
            VStack(spacing: 6) {
                // 音频附件预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .etFont(.system(size: 12))
                            .foregroundStyle(.blue)
                        
                        Text(audio.fileName)
                            .etFont(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .etFont(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.2))
                    .cornerRadius(8)
                }
                
                if isLiquidGlassEnabled {
                    HStack(spacing: 10) {
                        if #available(watchOS 26.0, *) {
                            transparentInputField
                                .glassEffect(.clear, in: Capsule())

                            Button(action: sendOrStopMessage) {
                                Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                    .etFont(.system(size: 18, weight: .medium))
                                    .frame(width: inputControlHeight, height: inputControlHeight)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.clear, in: Circle())
                            .disabled(!viewModel.isSendingMessage && !canSend)
                        } else {
                            ZStack {
                                Capsule()
                                    .fill(inputFillColor)
                                    .overlay(
                                        Capsule()
                                            .stroke(inputStrokeColor, lineWidth: 0.6)
                                    )
                                transparentInputField
                            }

                            Button(action: sendOrStopMessage) {
                                Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                    .etFont(.system(size: 18, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .overlay(
                                Circle()
                                    .stroke(inputStrokeColor, lineWidth: 0.8)
                            )
                            .disabled(!viewModel.isSendingMessage && !canSend)
                        }
                    }
                    .frame(height: inputControlHeight)
                } else {
                    HStack(spacing: 12) {
                        ZStack {
                            Capsule()
                                .fill(inputFillColor)
                                .overlay(
                                    Capsule()
                                        .stroke(inputStrokeColor, lineWidth: 0.6)
                                )
                            transparentInputField
                        }

                        Button(action: sendOrStopMessage) {
                            Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                .etFont(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .background(
                            Circle().fill(inputFillColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(inputStrokeColor, lineWidth: 0.8)
                        )
                        .disabled(!viewModel.isSendingMessage && !canSend)
                    }
                    .frame(height: inputControlHeight)
                    .padding(.horizontal, 10)
                    .background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                    .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, inputBubbleVerticalPadding)
        
        let speechSheetBinding = Binding(
            get: { viewModel.isSpeechRecorderPresented },
            set: { viewModel.isSpeechRecorderPresented = $0 }
        )
        let speechErrorBinding = Binding(
            get: { viewModel.showSpeechErrorAlert },
            set: { viewModel.showSpeechErrorAlert = $0 }
        )
        
        return coreBubble
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !viewModel.userInput.isEmpty || viewModel.pendingAudioAttachment != nil {
                    Button(role: .destructive) {
                        viewModel.clearUserInput()
                        viewModel.clearPendingAudioAttachment()
                    } label: {
                        Image(systemName: "trash")
                            .etFont(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("清空输入")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if viewModel.enableSpeechInput {
                    Button {
                        viewModel.beginSpeechInputFlow()
                    } label: {
                        Image(systemName: viewModel.isRecordingSpeech ? "waveform.circle.fill" : "mic.fill")
                            .etFont(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("语言输入")
                    .tint(.blue)
                    .disabled(viewModel.speechModels.isEmpty)
                }
            }
            .sheet(isPresented: speechSheetBinding) {
                SpeechRecorderView(viewModel: viewModel)
            }
            .alert("语音输入错误", isPresented: speechErrorBinding) {
                Button("好的", role: .cancel) { }
            } message: {
                Text(viewModel.speechErrorMessage ?? "发生未知错误，请稍后重试。")
            }
            .alert("记忆系统需要更新", isPresented: $viewModel.showDimensionMismatchAlert) {
                Button("好的", role: .cancel) { }
            } message: {
                Text(viewModel.dimensionMismatchMessage)
            }
            .alert("数据库已自动恢复", isPresented: Binding(
                get: { launchRecoveryNoticeMessage != nil },
                set: { if !$0 { launchRecoveryNoticeMessage = nil } }
            )) {
                Button("好的", role: .cancel) { }
            } message: {
                Text(launchRecoveryNoticeMessage ?? "")
            }
            .alert(
                Text(NSLocalizedString("记忆嵌入失败", comment: "Memory embedding failure alert title")),
                isPresented: $viewModel.showMemoryEmbeddingErrorAlert
            ) {
                Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) { }
            } message: {
                Text(viewModel.memoryEmbeddingErrorMessage)
            }
            // MARK: - 公告弹窗
            .sheet(isPresented: $announcementManager.shouldShowAlert) {
                if let announcement = announcementManager.currentAnnouncement {
                    NavigationStack {
                        AnnouncementAlertView(
                            announcement: announcement,
                            onDismiss: {
                                announcementManager.dismissAlert()
                            }
                        )
                    }
                }
            }
            // 启动时检查公告
            .task {
                launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
                await announcementManager.checkAnnouncement()
                scheduleDailyPulsePreparation(after: 1_500_000_000)
                if applyDailyPulseContinuationIfNeeded() {
                    return
                }
                if let pendingRoute = notificationCenter.consumePendingRoute() {
                    switch pendingRoute {
                    case .dailyPulse:
                        openDailyPulse()
                    case .feedback:
                        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
                    case .chatSession:
                        if let sessionID = notificationCenter.consumePendingChatSessionID() {
                            openChatSession(sessionID: sessionID)
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    scheduleDailyPulsePreparation(after: 1_500_000_000)
                default:
                    cancelDailyPulsePreparation()
                }
            }
    }

    private func openDailyPulse() {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .dailyPulse
        }
    }

    private func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    private func openChatSessionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.consumePendingChatSessionID() else { return }
        openChatSession(sessionID: sessionID)
    }

    private func openChatSession(sessionID: UUID) {
        guard viewModel.setCurrentSessionIfExists(sessionID: sessionID) else { return }
        isSettingsPresented = false
        settingsDestination = nil
    }

    private func openFeedback(issueNumber: Int?) {
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            if let issueNumber,
               FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
                settingsDestination = .feedbackIssue(issueNumber: issueNumber)
            } else {
                settingsDestination = .feedbackCenter
            }
        }
    }

    @discardableResult
    private func applyDailyPulseContinuationIfNeeded() -> Bool {
        guard let continuation = notificationCenter.consumePendingDailyPulseContinuation() else {
            return false
        }
        viewModel.applyDailyPulseContinuation(
            sessionID: continuation.sessionID,
            prompt: continuation.prompt
        )
        isSettingsPresented = false
        settingsDestination = nil
        return true
    }

    private var inputPlaceholderText: String {
        return NSLocalizedString("输入...", comment: "Default input placeholder on watch")
    }

    private func scheduleDailyPulsePreparation(after delayNanoseconds: UInt64) {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = Task(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let isSceneActive = await MainActor.run { scenePhase == .active }
            guard isSceneActive else { return }
            await viewModel.prepareDailyPulseIfNeeded()
            guard !Task.isCancelled else { return }
            await viewModel.prepareMorningDailyPulseDeliveryIfNeeded()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dailyPulsePreparationTask = nil
            }
        }
    }

    private func cancelDailyPulsePreparation() {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = nil
    }

}

private struct WatchAskUserInputView: View {
    let request: AppToolAskUserInputRequest
    let onSubmit: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var otherTextByQuestion: [String: String] = [:]
    @State private var currentQuestionIndex = 0
    @State private var hasHandledAction = false

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let title = request.title, !title.isEmpty {
                        Text(title)
                            .etFont(.headline)
                    } else {
                        Text("请补充信息")
                            .etFont(.headline)
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(description)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(progressText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let question = currentQuestion {
                    Section {
                        ForEach(question.options) { option in
                            Button {
                                toggleOption(question: question, optionID: option.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: optionIconName(question: question, optionID: option.id))
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .foregroundStyle(.primary)
                                        if let description = option.description, !description.isEmpty {
                                            Text(description)
                                                .etFont(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                !AppToolAskUserInputAnswerPolicy.canSelectOption(
                                    type: question.type,
                                    customText: otherTextByQuestion[question.id]
                                )
                            )
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(question.question)
                            if question.required {
                                Text("*")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Section {
                        HStack(spacing: 6) {
                            TextField(
                                "请输入自定义偏好",
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
                                )
                            )

                            Button(skipButtonTitle(for: question)) {
                                handleSkipOrSubmit(for: question)
                            }
                            .disabled(!canContinue(from: question))
                        }
                    }
                } else {
                    Section {
                        Text("暂无可填写问题")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("结构化问答")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        goToPreviousQuestion()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentQuestionIndex == 0)
                    .opacity(currentQuestionIndex == 0 ? 0.45 : 1)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        handleCancelAndDismiss()
                    }
                }
            }
            .onAppear {
                resetSelectionState()
                hasHandledAction = false
            }
            .onChange(of: request) {
                resetSelectionState()
                hasHandledAction = false
            }
            .onDisappear {
                guard !hasHandledAction else { return }
                onCancel()
            }
        }
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
        currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
    }

    private func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        currentQuestionIndex -= 1
    }

    private func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
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
        return isQuestionAnswered(question) ? "下一题" : "跳过"
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
        hasHandledAction = true
        onSubmit(answers)
        dismiss()
    }

    private func handleCancelAndDismiss() {
        hasHandledAction = true
        onCancel()
        dismiss()
    }

    private func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
    }
}

// MARK: - 完整错误响应辅助类型

/// 用于包装完整错误内容的 Identifiable 结构
private struct FullErrorContentWrapper: Identifiable {
    let id = UUID()
    let content: String
}

private struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}

/// 完整错误响应内容视图
private struct FullErrorContentView: View {
    let content: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .etFont(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("完整响应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font))
    }

    @ViewBuilder
    func etFont(_ font: Font?, sampleText: String?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font, sampleText: String?) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
    }
}

extension Text {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
    }
}

private enum TextSampleExtractor {
    private static let maxDepth = 10

    static func extract(from text: Text) -> String? {
        let strings = collectStrings(from: text, depth: 0)
        guard !strings.isEmpty else { return nil }

        var ordered: [String] = []
        var seen = Set<String>()
        for item in strings {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: " ")
    }

    private static func collectStrings(from value: Any, depth: Int) -> [String] {
        guard depth <= maxDepth else { return [] }

        if let string = value as? String {
            return [string]
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let childValue = mirror.children.first?.value else { return [] }
            return collectStrings(from: childValue, depth: depth + 1)
        }

        var results: [String] = []
        for child in mirror.children {
            if shouldSkip(label: child.label) {
                continue
            }
            results.append(contentsOf: collectStrings(from: child.value, depth: depth + 1))
        }
        return results
    }

    private static func shouldSkip(label: String?) -> Bool {
        switch label {
        case "modifiers", "table", "bundle", "arguments", "hasFormatting":
            return true
        default:
            return false
        }
    }
}

private enum AppFontAdapter {
    private static let cacheLock = NSLock()
    private static var adaptedFontCache: [String: Font] = [:]
    private static var adaptedFontCacheToken: String = ""

    static func adaptedFont(from original: Font, sampleText: String? = nil) -> Font {
        let rawDescriptor = String(describing: original)
        let descriptor = FontDescriptorInfo(rawDescription: rawDescriptor)
        let role = inferredRole(from: descriptor)
        let resolvedSample = resolvedSampleText(for: role, override: sampleText)
        let cacheKey = "\(rawDescriptor)|\(role.rawValue)|\(resolvedSample)"
        let cacheToken = FontLibrary.adapterCacheToken()

        if let cached = cachedFont(for: cacheKey, cacheToken: cacheToken) {
            return cached
        }

        guard let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: resolvedSample) else {
            storeAdaptedFont(original, for: cacheKey, cacheToken: cacheToken)
            return original
        }

        let fallbackPostScriptNames = FontLibrary.fallbackPostScriptNames(for: role)
        let mapped = mappedFont(
            postScriptName: postScriptName,
            descriptor: descriptor,
            fallbackPostScriptNames: fallbackPostScriptNames
        )
        storeAdaptedFont(mapped, for: cacheKey, cacheToken: cacheToken)
        return mapped
    }

    private static func resolvedSampleText(for role: FontSemanticRole, override sampleText: String?) -> String {
        if let sampleText {
            let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let scalars = trimmed.unicodeScalars.filter {
                    !$0.properties.isWhitespace && $0.properties.generalCategory != .control
                }
                let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }
        return self.sampleText(for: role)
    }

    private static func inferredRole(from descriptor: FontDescriptorInfo) -> FontSemanticRole {
        if descriptor.isMonospaced {
            return .code
        }
        if descriptor.isItalic {
            return .emphasis
        }
        if let weight = descriptor.weight, weightStrength(weight) >= weightStrength(.semibold) {
            return .strong
        }
        return .body
    }

    private static func mappedFont(
        postScriptName: String,
        descriptor: FontDescriptorInfo,
        fallbackPostScriptNames: [String]
    ) -> Font {
        if FontLibrary.fallbackScope == .character {
            let fallbackChain = fallbackPostScriptNames.filter {
                !$0.isEmpty && $0.caseInsensitiveCompare(postScriptName) != .orderedSame
            }
            if let cascaded = mappedFontWithCascade(
                primaryPostScriptName: postScriptName,
                fallbackPostScriptNames: fallbackChain,
                descriptor: descriptor
            ) {
                return cascaded
            }
        }

        var mapped: Font
        if let explicitSize = descriptor.explicitSize {
            mapped = .custom(postScriptName, size: explicitSize)
        } else if let textStyle = descriptor.textStyle {
            mapped = .custom(
                postScriptName,
                size: defaultPointSize(for: textStyle),
                relativeTo: textStyle
            )
        } else {
            mapped = .custom(postScriptName, size: 15, relativeTo: .body)
        }

        if descriptor.isItalic {
            mapped = mapped.italic()
        }
        if let weight = descriptor.weight {
            mapped = mapped.weight(weight)
        }
        return mapped
    }

    private static func resolvedPointSize(for descriptor: FontDescriptorInfo) -> CGFloat {
        if let explicitSize = descriptor.explicitSize {
            return explicitSize
        }
        if let textStyle = descriptor.textStyle {
            return defaultPointSize(for: textStyle)
        }
        return 15
    }

    private static func mappedFontWithCascade(
        primaryPostScriptName: String,
        fallbackPostScriptNames: [String],
        descriptor: FontDescriptorInfo
    ) -> Font? {
#if canImport(UIKit) && canImport(CoreText)
        guard !fallbackPostScriptNames.isEmpty else { return nil }
        let pointSize = resolvedPointSize(for: descriptor)
        guard UIFont(name: primaryPostScriptName, size: pointSize) != nil else { return nil }

        let cascadeDescriptors = fallbackPostScriptNames.compactMap { candidate -> CTFontDescriptor? in
            guard UIFont(name: candidate, size: pointSize) != nil else { return nil }
            return CTFontDescriptorCreateWithNameAndSize(candidate as CFString, pointSize)
        }
        guard !cascadeDescriptors.isEmpty else { return nil }

        let cascadeKey = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        var descriptorAttributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: primaryPostScriptName,
            .size: pointSize,
            cascadeKey: cascadeDescriptors
        ]

        if let weight = descriptor.weight {
            descriptorAttributes[.traits] = [
                UIFontDescriptor.TraitKey.weight: uiFontWeightValue(weight)
            ]
        }

        var uiFontDescriptor = UIFontDescriptor(fontAttributes: descriptorAttributes)
        if descriptor.isItalic,
           let italicDescriptor = uiFontDescriptor.withSymbolicTraits(.traitItalic) {
            uiFontDescriptor = italicDescriptor
        }

        let uiFont = UIFont(descriptor: uiFontDescriptor, size: pointSize)
        return Font(uiFont)
#else
        _ = primaryPostScriptName
        _ = fallbackPostScriptNames
        _ = descriptor
        return nil
#endif
    }

    private static func uiFontWeightValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight:
            return UIFont.Weight.ultraLight.rawValue
        case .thin:
            return UIFont.Weight.thin.rawValue
        case .light:
            return UIFont.Weight.light.rawValue
        case .regular:
            return UIFont.Weight.regular.rawValue
        case .medium:
            return UIFont.Weight.medium.rawValue
        case .semibold:
            return UIFont.Weight.semibold.rawValue
        case .bold:
            return UIFont.Weight.bold.rawValue
        case .heavy:
            return UIFont.Weight.heavy.rawValue
        case .black:
            return UIFont.Weight.black.rawValue
        default:
            return UIFont.Weight.regular.rawValue
        }
    }

    private static func sampleText(for role: FontSemanticRole) -> String {
        switch role {
        case .body:
            return "The quick brown fox 你好こんにちは"
        case .emphasis:
            return "Emphasis 斜体预览 こんにちは"
        case .strong:
            return "Strong 粗体预览 こんにちは"
        case .code:
            return "let value = 42 // 代码"
        }
    }

    private static func defaultPointSize(for textStyle: Font.TextStyle) -> CGFloat {
        switch textStyle {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .body:
            return 15
        case .callout:
            return 16
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 15
        }
    }

    private static func weightStrength(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight:
            return 1
        case .thin:
            return 2
        case .light:
            return 3
        case .regular:
            return 4
        case .medium:
            return 5
        case .semibold:
            return 6
        case .bold:
            return 7
        case .heavy:
            return 8
        case .black:
            return 9
        default:
            return 4
        }
    }

    private static func cachedFont(for key: String, cacheToken: String) -> Font? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        return adaptedFontCache[key]
    }

    private static func storeAdaptedFont(_ font: Font, for key: String, cacheToken: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        adaptedFontCache[key] = font
    }
}

private struct FontDescriptorInfo {
    let raw: String
    let lowercasedRaw: String

    init(rawDescription: String) {
        self.raw = rawDescription
        self.lowercasedRaw = rawDescription.lowercased()
    }

    var explicitSize: CGFloat? {
        firstMatchedNumber(after: "size:")
            ?? firstMatchedNumber(after: "size ")
    }

    var textStyle: Font.TextStyle? {
        if lowercasedRaw.contains("caption2") { return .caption2 }
        if lowercasedRaw.contains("caption") { return .caption }
        if lowercasedRaw.contains("footnote") { return .footnote }
        if lowercasedRaw.contains("callout") { return .callout }
        if lowercasedRaw.contains("subheadline") { return .subheadline }
        if lowercasedRaw.contains("headline") { return .headline }
        if lowercasedRaw.contains("title3") { return .title3 }
        if lowercasedRaw.contains("title2") { return .title2 }
        if lowercasedRaw.contains("largetitle") || lowercasedRaw.contains("large title") { return .largeTitle }
        if lowercasedRaw.contains("title") { return .title }
        if lowercasedRaw.contains("body") { return .body }
        return nil
    }

    var isItalic: Bool {
        lowercasedRaw.contains("italic")
    }

    var isMonospaced: Bool {
        lowercasedRaw.contains("monospaced") || lowercasedRaw.contains("mono")
    }

    var weight: Font.Weight? {
        if lowercasedRaw.contains("black") { return .black }
        if lowercasedRaw.contains("heavy") { return .heavy }
        if lowercasedRaw.contains("semibold") { return .semibold }
        if lowercasedRaw.contains("bold") { return .bold }
        if lowercasedRaw.contains("medium") { return .medium }
        if lowercasedRaw.contains("light") { return .light }
        if lowercasedRaw.contains("thin") { return .thin }
        if lowercasedRaw.contains("ultralight") || lowercasedRaw.contains("ultra light") { return .ultraLight }
        return nil
    }

    private func firstMatchedNumber(after marker: String) -> CGFloat? {
        guard let markerRange = lowercasedRaw.range(of: marker) else { return nil }
        var cursor = markerRange.upperBound
        var digits = ""
        var hasStarted = false

        while cursor < lowercasedRaw.endIndex {
            let character = lowercasedRaw[cursor]
            if character.isNumber || character == "." {
                digits.append(character)
                hasStarted = true
            } else if hasStarted {
                break
            }
            cursor = lowercasedRaw.index(after: cursor)
        }

        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return CGFloat(value)
    }
}
