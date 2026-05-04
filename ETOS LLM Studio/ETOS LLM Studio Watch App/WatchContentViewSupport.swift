// ============================================================================
// WatchContentViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接 watchOS 主聊天视图的布局碎片、滚动控制、消息动作与迁移弹层。
// ============================================================================

import SwiftUI
import Foundation
import Shared

extension ContentView {
    @ViewBuilder
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
        .alert(NSLocalizedString("数据库已自动恢复", comment: ""), isPresented: Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { if !$0 { launchRecoveryNoticeMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
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
                    openFeedbackFromNotification()
                case .chatSession:
                    openChatSessionFromNotification()
                case .achievementJournal:
                    openAchievementJournalFromNotification()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                ChatAppearanceProfileManager.shared.handleAppBecameActive()
                scheduleDailyPulsePreparation(after: 1_500_000_000)
            default:
                cancelDailyPulsePreparation()
            }
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
        switch item {
        case .editMessage:
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
                WatchMessageRowView(
                    viewModel: viewModel,
                    toolPermissionCenter: toolPermissionCenter,
                    state: state,
                    mergeWithPrevious: mergeWithPrevious,
                    mergeWithNext: mergeWithNext,
                    connectsTimelineFromPrevious: connectsTimelineFromPrevious,
                    connectsTimelineToNext: connectsTimelineToNext,
                    isLiquidGlassEnabled: isLiquidGlassEnabled,
                    onOpenMore: {
                        messageActionsTarget = WatchMessageActionsNavigationTarget(id: message.id)
                    }
                )
            }

            if viewModel.activeAskUserInputRequest == nil {
                WatchInputBubbleView(
                    viewModel: viewModel,
                    isLiquidGlassEnabled: isLiquidGlassEnabled,
                    isNativeNavigationEnabled: isNativeNavigationEnabled,
                    inputControlHeight: inputControlHeight,
                    inputFillColor: inputFillColor,
                    inputStrokeColor: inputStrokeColor,
                    inputPlaceholderText: NSLocalizedString("输入...", comment: "Default input placeholder on watch"),
                    inputBubbleVerticalPadding: inputBubbleVerticalPadding,
                    onOpenSessionHistory: {
                        viewModel.activeSheet = nil
                        isSettingsPresented = false
                        settingsDestination = nil
                        if isNativeNavigationEnabled {
                            nativeDestination = nil
                        } else {
                            isSessionListPresented = true
                        }
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
                            viewModel.beginSpeechInputFlow()
                        case .inactive:
                            break
                        }
                    },
                    onRememberAttachmentSource: { source in
                        let updatedHistory = WatchImportSourceHistory.appending(
                            source,
                            to: importSourceHistory
                        )
                        attachmentSourceHistoryRawValue = WatchImportSourceHistory.rawValue(for: updatedHistory)
                        lastAttachmentSource = updatedHistory.first ?? ""
                        importSourceHistory = updatedHistory
                    },
                    importSourceHistory: importSourceHistory,
                    lastAttachmentSource: lastAttachmentSource,
                    isQuickModelSelectorPresented: $isQuickModelSelectorPresented,
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
                onDeleteVersion: { index in
                    viewModel.deleteVersion(at: index, of: message)
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

    func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        let scrollAction = {
            shouldKeepBottomPinned = true
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

    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
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

    func scheduleImmediateBottomSnap(proxy: ScrollViewProxy) {
        pendingBottomSnapTask?.cancel()
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

    var inputStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }
}
