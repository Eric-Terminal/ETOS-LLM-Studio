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

extension ContentView {
    var effectiveFontScale: CGFloat {
        CGFloat(FontLibrary.effectiveFontScale(customFontScale, isCustomFontEnabled: isCustomFontEnabled))
    }
    var inputControlHeight: CGFloat {
        max(38, 38 * effectiveFontScale)
    }

    var isLiquidGlassEnabled: Bool {
        if #available(watchOS 26.0, *) {
            return viewModel.enableLiquidGlass
        } else {
            return false
        }
    }

    var isNativeNavigationEnabled: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
    }

    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            if !isNativeNavigationEnabled {
                chatBackgroundLayer
                    .ignoresSafeArea()
            }

            // 主导航
            NavigationStack {
                if isNativeNavigationEnabled {
                    nativeSessionRootView
                        .navigationDestination(item: $nativeDestination) { destination in
                            switch destination {
                            case .chat:
                                legacyChatRootView
                            case .settings:
                                SettingsView(
                                    viewModel: viewModel,
                                    requestedDestination: $settingsDestination,
                                    embedsInNavigationStack: false
                                )
                            }
                        }
                } else {
                    legacyChatRootView
                        .navigationDestination(isPresented: $isSessionListPresented) {
                            sessionListView
                        }
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
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenAchievementJournal)) { _ in
                openAchievementJournalFromNotification()
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

            VStack {
                Spacer()
                TTSFloatingController()
            }
        }
        .environment(\.font, rootBodyFont)
        .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appLanguageRawValue))
        .onAppear {
            AppLanguageRuntime.apply(rawValue: appLanguageRawValue)
            refreshRootBodyFont()
            refreshAttachmentSourceHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .onChange(of: customFontScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                customFontScale = normalizedValue
            }
            refreshRootBodyFont()
        }
        .onChange(of: chatNavigationModeRawValue) { _, _ in
            if !isNativeNavigationEnabled {
                nativeDestination = nil
            } else {
                nativeDestination = .chat
                isSessionListPresented = false
                isSettingsPresented = false
            }
        }
        .onChange(of: appLanguageRawValue) { _, newValue in
            AppLanguageRuntime.apply(rawValue: newValue)
        }
        .onChange(of: attachmentSourceHistoryRawValue) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onChange(of: lastAttachmentSource) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onDisappear {
            pendingBottomSnapTask?.cancel()
            pendingBottomSnapTask = nil
            bottomAnchorVisibilityWorkItem?.cancel()
            bottomAnchorVisibilityWorkItem = nil
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
        .alert(NSLocalizedString("是否清理旧版 JSON 文件？", comment: ""),
            isPresented: $legacyJSONMigrationManager.isCleanupPromptPresented
        ) {
            Button(NSLocalizedString("保留", comment: ""), role: .cancel) {
                legacyJSONMigrationManager.keepLegacyJSONForNow()
            }
            Button(NSLocalizedString("删除", comment: "")) {
                legacyJSONMigrationManager.cleanupLegacyJSONArtifacts()
            }
        } message: {
            Text(NSLocalizedString("SQLite 迁移完成后，建议删除旧 JSON 释放空间。", comment: ""))
        }
        .alert(NSLocalizedString("迁移失败", comment: ""), isPresented: Binding(
            get: { legacyMigrationErrorMessage != nil },
            set: { if !$0 { legacyMigrationErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
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

    var nativeSessionRootView: some View {
        Group {
            if nativeDestination == nil {
                sessionListView
            } else {
                Color.clear
            }
        }
            .navigationTitle(NSLocalizedString("历史会话", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if nativeDestination == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            nativeDestination = .settings
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                }
            }
    }

    var legacyChatRootView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                if isNativeNavigationEnabled {
                    chatBackgroundLayer
                        .ignoresSafeArea()
                }

                chatList(proxy: proxy)

                if showScrollToBottomButton {
                    scrollToBottomButton(proxy: proxy)
                }
            }
        }
        .navigationTitle(viewModel.currentSession?.name ?? NSLocalizedString("新对话", comment: ""))
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: viewModel, requestedDestination: $settingsDestination)
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
        .navigationDestination(item: $messageActionsTarget) { target in
            messageActionsView(for: target.id)
        }
    }

    @ViewBuilder
    var chatBackgroundLayer: some View {
        if viewModel.enableBackground,
           let bgImage = viewModel.currentBackgroundImageBlurredUIImage {
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
                        .opacity(viewModel.resolvedBackgroundOpacity)
                }
                .frame(width: size.width, height: size.height)
            }
        } else {
            Color.clear
        }
    }
    
    // MARK: - 视图组件

    func memoryRetryStoppedNoticeBanner(text: String) -> some View {
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
            .accessibilityLabel(NSLocalizedString("关闭提示", comment: ""))
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
    func sheetView(for item: ActiveSheet) -> some View {
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
            Text(NSLocalizedString("未知视图", comment: ""))
        }
    }
    
    func chatList(proxy: ScrollViewProxy) -> some View {
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
                let connectsTimelineFromPrevious = shouldConnectTimeline(previousMessage, with: message)
                let connectsTimelineToNext = shouldConnectTimeline(message, with: nextMessage)
                messageRow(
                    for: state,
                    mergeWithPrevious: mergeWithPrevious,
                    mergeWithNext: mergeWithNext,
                    connectsTimelineFromPrevious: connectsTimelineFromPrevious,
                    connectsTimelineToNext: connectsTimelineToNext
                )
            }

            if viewModel.activeAskUserInputRequest == nil {
                inputBubble
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
        .toolbar {
            if !isNativeNavigationEnabled {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.activeSheet = nil
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
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
            shouldKeepBottomPinned = true
            needsImmediateBottomSnap = true
            scheduleImmediateBottomSnap(proxy: proxy)
            resolvePendingSearchJumpIfNeeded()
        }
    }

    func refreshRootBodyFont() {
        rootBodyFont = AppFontAdapter.adaptedFont(
            from: .body,
            sampleText: "The quick brown fox 你好こんにちは"
        )
    }

    var sessionListView: some View {
        SessionListView(
            sessions: $viewModel.chatSessions,
            folders: $viewModel.sessionFolders,
            currentSession: $viewModel.currentSession,
            runningSessionIDs: viewModel.runningSessionIDs,
            deleteSessionAction: { session in
                viewModel.deleteSessions([session])
            },
            branchAction: { session, copyMessages in
                viewModel.branchSession(from: session, copyMessages: copyMessages)
            },
            deleteLastMessageAction: { session in
                viewModel.deleteLastMessage(for: session)
            },
            sendSessionToCompanionAction: { session in
                WatchSyncManager.shared.sendSessionToCompanion(sessionID: session.id)
            },
            onSessionSelected: { selectedSession, messageOrdinal in
                if let messageOrdinal {
                    viewModel.requestMessageJump(
                        sessionID: selectedSession.id,
                        messageOrdinal: messageOrdinal
                    )
                } else {
                    viewModel.clearPendingMessageJumpTarget()
                }
                ChatService.shared.setCurrentSession(selectedSession)
                if isNativeNavigationEnabled {
                    nativeDestination = .chat
                } else {
                    isSessionListPresented = false
                }
            },
            updateSessionAction: { session in
                viewModel.updateSession(session)
            },
            createFolderAction: { name, parentID in
                viewModel.createSessionFolder(name: name, parentID: parentID)
            },
            renameFolderAction: { folder, newName in
                viewModel.renameSessionFolder(folder, newName: newName)
            },
            deleteFolderAction: { folder in
                viewModel.deleteSessionFolder(folder)
            },
            moveSessionToFolderAction: { session, folderID in
                viewModel.moveSession(session, toFolderID: folderID)
            },
            moveFolderToFolderAction: { folder, parentID in
                viewModel.moveSessionFolder(folder, toParentID: parentID)
            },
            createConversationAction: isNativeNavigationEnabled ? {
                viewModel.createNewSession()
                nativeDestination = .chat
            } : nil
        )
    }

    var legacyJSONMigrationPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("检测到旧版 JSON 数据", comment: ""))
                .etFont(.headline)
            Text(NSLocalizedString("建议立即迁移到 SQLite，后续版本可能不再支持旧格式。迁移会在后台分批执行，尽量避免卡顿。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)

            if let status = legacyJSONMigrationManager.status {
                Text(String(format: NSLocalizedString("预计 %.1f MB，约 %d 个会话", comment: ""), status.estimatedLegacyMegabytes, status.estimatedSessionCount))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(NSLocalizedString("立即迁移（推荐）", comment: "")) {
                legacyJSONMigrationManager.startMigration()
            }
            .buttonStyle(.borderedProminent)

            Button(NSLocalizedString("稍后再说", comment: "")) {
                legacyJSONMigrationManager.postponeMigrationPrompt()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .navigationTitle(NSLocalizedString("数据迁移", comment: ""))
    }

    var legacyJSONMigrationProgressSheet: some View {
        VStack(spacing: 10) {
            Text(NSLocalizedString("正在迁移", comment: ""))
                .etFont(.headline)
            if let progress = legacyJSONMigrationManager.progress {
                ProgressView(value: progress.fractionCompleted)
                Text(String(format: NSLocalizedString("会话 %d/%d", comment: ""), progress.processedSessions, max(progress.totalSessions, progress.processedSessions)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("消息 %d", comment: ""), progress.importedMessages))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(NSLocalizedString("迁移完成后会再询问是否删除旧 JSON。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .navigationTitle(NSLocalizedString("迁移中", comment: ""))
    }
    
    /// 辅助函数，用于构建单个消息行，以简化 chatList 的主体
    @ViewBuilder
    func messageRow(
        for state: ChatMessageRenderState,
        mergeWithPrevious: Bool,
        mergeWithNext: Bool,
        connectsTimelineFromPrevious: Bool,
        connectsTimelineToNext: Bool
    ) -> some View {
        let message = state.message
        let isReasoningExpandedBinding = Binding<Bool>(
            get: { viewModel.reasoningExpandedState[message.id, default: false] },
            set: { viewModel.setReasoningExpanded($0, for: message.id) }
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
            preparedReasoningMarkdownPayload: viewModel.preparedReasoningMarkdownByMessageID[message.id],
            isReasoningExpanded: isReasoningExpandedBinding,
            isReasoningAutoPreview: viewModel.isAutoReasoningPreview(for: message.id),
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
            connectsTimelineFromPrevious: connectsTimelineFromPrevious,
            connectsTimelineToNext: connectsTimelineToNext,
            hasAutoOpenedPendingToolCall: { toolCallID in
                viewModel.hasAutoOpenedPendingToolCall(toolCallID)
            },
            markPendingToolCallAutoOpened: { toolCallID in
                viewModel.markPendingToolCallAutoOpened(toolCallID)
            },
            onCodeBlockHeaderTap: { content in
                viewModel.appendCodeBlockContentToInput(content)
            },
            onOpenMore: hasActivePermission ? nil : {
                openMessageActions(for: message)
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
                    messageActionsSwipeAction(for: message)
                }
        }
    }

    func hasActiveToolPermissionRequest(for message: ChatMessage) -> Bool {
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

    func openMessageActions(for message: ChatMessage) {
        messageActionsTarget = WatchMessageActionsNavigationTarget(id: message.id)
    }

    @ViewBuilder
    func messageActionsView(for messageID: UUID) -> some View {
        if let message = viewModel.allMessagesForSession.first(where: { $0.id == messageID }) {
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
                    viewModel.deleteAllVersions(of: message)
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
                supportsMathRenderToggle: viewModel.enableAdvancedRenderer && (viewModel.preparedMarkdownByMessageID[message.id]?.containsMathContent ?? false),
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
        } else {
            EmptyView()
        }
    }
}
