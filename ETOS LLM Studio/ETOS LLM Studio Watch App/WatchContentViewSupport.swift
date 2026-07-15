// ============================================================================
// WatchContentViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接 watchOS 主聊天视图的布局碎片、滚动控制、消息动作与迁移弹层。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
import AVKit
import AVFoundation

extension ContentView {
    var legacyChatRootView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                chatList(proxy: proxy)

                WatchRoleplaySessionScriptHost(
                    sessionID: viewModel.currentSession?.id,
                    messageID: viewModel.displayMessages.last?.message.id,
                    versionIndex: viewModel.displayMessages.last?.message.getCurrentVersionIndex() ?? 0
                )

                if showScrollToBottomButton {
                    scrollToBottomButton(proxy: proxy)
                }
            }
        }
        .navigationTitle(viewModel.currentSession?.name ?? NSLocalizedString("新对话", comment: ""))
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: viewModel, requestedDestination: $settingsDestination)
                .appLockOverlayLayer()
        }
        .sheet(isPresented: $isSessionListPresented) {
            NavigationStack {
                sessionListView
            }
            .appLockOverlayLayer()
        }
        .sheet(isPresented: $isContextCompressionPresented) {
            if let session = viewModel.currentSession {
                NavigationStack {
                    WatchContextCompressionOptionsView(
                        session: session,
                        models: viewModel.activatedChatModels,
                        selectedModelID: viewModel.selectedModel?.id,
                        onCompress: { options, progress in
                            try await viewModel.createCompressedContinuation(
                                from: session.id,
                                options: options,
                                progress: progress
                            )
                        }
                    )
                }
                .appLockOverlayLayer()
            }
        }
        .sheet(item: $watchInputQuickActionDestination) { action in
            NavigationStack {
                watchInputQuickActionDestinationView(for: action)
            }
            .appLockOverlayLayer()
        }
        .sheet(item: $contextCompressionReminderSourceSession) { session in
            NavigationStack {
                WatchContextCompressionOneTapView(
                    session: session,
                    onCompress: { progress in
                        try await viewModel.createCompressedContinuation(
                            from: session.id,
                            options: ContextCompressionOptions(
                                compressionModelIdentifier: viewModel.selectedModel?.id
                            ),
                            progress: progress
                        )
                    }
                )
            }
            .appLockOverlayLayer()
        }
        .sheet(item: $viewModel.activeSheet) { item in
            sheetView(for: item)
                .appLockOverlayLayer()
        }
        .sheet(item: Binding(
            get: { fullErrorContent.map { FullErrorContentWrapper(content: $0) } },
            set: { _ in fullErrorContent = nil }
        )) { wrapper in
            FullErrorContentView(content: wrapper.content)
                .appLockOverlayLayer()
        }
        .sheet(item: $presentedAskUserInputRequest, onDismiss: {
            presentedAskUserInputRequest = nil
            refreshWatchPresentationPriorities()
        }) { request in
            WatchAskUserInputView(
                request: request,
                onSubmit: { answers in
                    viewModel.submitAskUserInputAnswers(answers, for: request)
                },
                onCancel: {
                    viewModel.cancelAskUserInputRequest(using: request)
                }
            )
            .appLockOverlayLayer()
        }
        .sheet(item: watchGlobalToolPermissionRequestBinding) { request in
            WatchGlobalToolPermissionView(request: request) { decision in
                toolPermissionCenter.resolveActiveRequest(with: decision)
            }
            .interactiveDismissDisabled(true)
            .appLockOverlayLayer()
        }
        .navigationDestination(item: $messageActionsTarget) { target in
            messageActionsView(for: target.id)
        }
        .navigationDestination(item: $selectedMessagesExportTarget) { target in
            ChatExportFormatsView(
                session: viewModel.currentSession,
                messages: viewModel.allMessagesForSession,
                upToMessageID: nil,
                selectedMessageIDs: target.messageIDs
            )
        }
        .sheet(item: $messageRewriteTarget) { target in
            NavigationStack {
                rewriteMessageView(for: target)
            }
            .appLockOverlayLayer()
        }
        .alert(NSLocalizedString("数据库已恢复", comment: ""), isPresented: Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { if !$0 { launchRecoveryNoticeMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
        .alert(NSLocalizedString("检测到数据库损坏", comment: ""), isPresented: Binding(
            get: { launchRecoveryRequest != nil },
            set: { if !$0 { launchRecoveryRequest = nil } }
        )) {
            Button(NSLocalizedString("稍后再说", comment: ""), role: .cancel) {
                Persistence.dismissPendingLaunchRecoveryRequest()
                launchRecoveryRequest = nil
            }
            Button(NSLocalizedString("从启动备份恢复", comment: "")) {
                restoreLaunchBackupFromPrompt()
            }
        } message: {
            Text(launchRecoveryRequest?.message ?? "")
        }
        .alert(NSLocalizedString("启动备份恢复失败", comment: ""), isPresented: Binding(
            get: { launchRecoveryErrorMessage != nil },
            set: { if !$0 { launchRecoveryErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                launchRecoveryErrorMessage = nil
            }
        } message: {
            Text(launchRecoveryErrorMessage ?? "")
        }
        .alert(NSLocalizedString("重写失败", comment: "Message rewrite failure alert title"), isPresented: Binding(
            get: { viewModel.messageRewriteErrorMessage != nil },
            set: { if !$0 { viewModel.messageRewriteErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                viewModel.messageRewriteErrorMessage = nil
            }
        } message: {
            Text(viewModel.messageRewriteErrorMessage ?? "")
        }
        .alert(NSLocalizedString("确认删除所选消息", comment: "Selected messages delete confirmation title"), isPresented: $showSelectedMessagesDeleteConfirm) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                deleteSelectedMessages()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        } message: {
            Text(
                String(
                    format: NSLocalizedString("将删除选中的 %d 个气泡。此操作无法撤销。", comment: "Selected messages delete confirmation message"),
                    selectedMessageIDs.count
                )
            )
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
                .appLockOverlayLayer()
            }
        }
        .task {
            launchRecoveryRequest = Persistence.currentLaunchRecoveryRequest()
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
                case .contextCompression:
                    openContextCompressionFromNotification()
                case .achievementJournal:
                    openAchievementJournalFromNotification()
                case .updateTimeline:
                    openUpdateTimelineFromNotification()
                }
            }
        }
        .onAppear {
            refreshWatchPresentationPriorities()
        }
        .onDisappear {
            setWatchToolPermissionAutoPresentationBlocked(false)
        }
        .onChange(of: watchToolPermissionAutoPresentationBlocked) { _, _ in
            refreshWatchPresentationPriorities()
        }
        .onChange(of: watchModalBlocksAskUserInputPresentation) { _, _ in
            presentPendingAskUserInputIfPossible()
        }
        .onChange(of: viewModel.activeAskUserInputRequest?.requestID) { _, _ in
            syncPresentedAskUserInputRequest()
            refreshWatchPresentationPriorities()
        }
        .onChange(of: presentedAskUserInputRequest?.requestID) { _, _ in
            refreshWatchPresentationPriorities()
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

    var watchModalBlocksAskUserInputPresentation: Bool {
        isSettingsPresented
            || isSessionListPresented
            || isContextCompressionPresented
            || watchInputQuickActionDestination != nil
            || contextCompressionReminderSourceSession != nil
            || viewModel.activeSheet != nil
            || fullErrorContent != nil
            || messageActionsTarget != nil
            || messageRewriteTarget != nil
            || selectedMessagesExportTarget != nil
            || isMessageSelectionMode
            || announcementManager.shouldShowAlert
            || launchRecoveryNoticeMessage != nil
            || launchRecoveryRequest != nil
            || launchRecoveryErrorMessage != nil
            || viewModel.messageRewriteErrorMessage != nil
            || legacyJSONMigrationManager.isMigrationPromptPresented
            || legacyJSONMigrationManager.isMigrating
            || legacyJSONMigrationManager.isCleanupPromptPresented
            || legacyMigrationErrorMessage != nil
            || isRequestControlsPresented
            || isAttachmentImportPresented
            || viewModel.showSpeechErrorAlert
            || viewModel.showAttachmentImportErrorAlert
            || viewModel.showDimensionMismatchAlert
            || viewModel.showMemoryEmbeddingErrorAlert
            || appLockManager.state == .locked
            || toolPermissionCenter.hasAutoPresentationBlockers(excluding: ["watch.root.presentation"])
    }

    var watchToolPermissionAutoPresentationBlocked: Bool {
        watchModalBlocksAskUserInputPresentation
            || presentedAskUserInputRequest != nil
    }

    var watchGlobalToolPermissionRequestBinding: Binding<ToolPermissionRequest?> {
        Binding(
            get: { watchGlobalToolPermissionRequest },
            set: { _ in }
        )
    }

    var watchGlobalToolPermissionRequest: ToolPermissionRequest? {
        guard toolPermissionCenter.canAutoPresentRequestDetails,
              let request = toolPermissionCenter.activeRequest,
              let sourceSessionID = request.sourceSessionID,
              sourceSessionID != viewModel.currentSession?.id else {
            return nil
        }
        return request
    }

    func setWatchToolPermissionAutoPresentationBlocked(_ blocked: Bool) {
        toolPermissionCenter.setAutoPresentationBlocked(blocked, reason: "watch.root.presentation")
    }

    func refreshWatchPresentationPriorities() {
        setWatchToolPermissionAutoPresentationBlocked(watchToolPermissionAutoPresentationBlocked)
        presentPendingAskUserInputIfPossible()
    }

    func syncPresentedAskUserInputRequest() {
        guard let activeRequest = viewModel.activeAskUserInputRequest else {
            presentedAskUserInputRequest = nil
            return
        }
        if let presentedAskUserInputRequest,
           presentedAskUserInputRequest.requestID == activeRequest.requestID {
            return
        }
        presentPendingAskUserInputIfPossible()
    }

    func presentPendingAskUserInputIfPossible() {
        guard presentedAskUserInputRequest == nil,
              !watchModalBlocksAskUserInputPresentation,
              let request = viewModel.activeAskUserInputRequest else {
            return
        }
        presentedAskUserInputRequest = request
    }

    @ViewBuilder
    var chatBackgroundLayer: some View {
        if viewModel.enableBackground,
           viewModel.currentBackgroundIsVideo,
           let videoURL = viewModel.currentBackgroundMediaURL {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    if viewModel.backgroundContentMode == "fit" {
                        colorScheme == .dark ? Color.black : Color(white: 0.95)
                    }

                    WatchLoopingBackgroundVideoView(url: videoURL)
                        .aspectRatio(contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit)
                        .frame(width: size.width, height: size.height)
                        .position(x: size.width / 2, y: size.height / 2)
                        .clipped()
                        .blur(radius: viewModel.backgroundBlur)
                        .opacity(viewModel.resolvedBackgroundOpacity)
                }
                .frame(width: size.width, height: size.height)
            }
        } else if viewModel.enableBackground,
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

    var sessionListView: some View {
        SessionListView(
            sessions: $viewModel.chatSessions,
            folders: $viewModel.sessionFolders,
            tags: viewModel.sessionTags,
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
                isSessionListPresented = false
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
            createTagAction: { name, color in
                viewModel.createSessionTag(name: name, color: color)
            },
            updateTagAction: { tag, name, color in
                viewModel.updateSessionTag(tag, name: name, color: color)
            },
            deleteTagAction: { tag in
                viewModel.deleteSessionTag(tag)
            },
            setSessionTagsAction: { session, tagIDs in
                viewModel.setSessionTags(for: session, tagIDs: tagIDs)
            },
            createConversationAction: {
                viewModel.createNewSession()
                isSessionListPresented = false
            }
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
                canRewrite: viewModel.canRewrite(message: message),
                onInsertText: { text in
                    viewModel.applyToolInputDraftRequest(
                        AppToolInputDraftRequest(text: text, mode: .append)
                    )
                },
                onEdit: {
                    viewModel.messageToEdit = message
                    viewModel.activeSheet = .editMessage
                },
                onRewrite: {
                    messageRewriteTarget = WatchMessageRewriteNavigationTarget(id: message.id)
                },
                onRewriteSelection: { target in
                    messageRewriteTarget = WatchMessageRewriteNavigationTarget(
                        id: message.id,
                        selectionTarget: target
                    )
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
                onSelectMultiple: {
                    beginMessageSelection(with: message)
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
                mathRenderContent: viewModel.preparedMarkdownByMessageID[message.id]?.normalizedText ?? message.content,
                onJumpToMessageIndex: { displayIndex in
                    jumpToMessage(displayIndex: displayIndex)
                },
                session: viewModel.currentSession,
                allMessages: viewModel.allMessagesForSession,
                providers: viewModel.providers,
                messageIndex: viewModel.allMessagesForSession.firstIndex { $0.id == message.id },
                totalMessages: viewModel.allMessagesForSession.count
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    func rewriteMessageView(for target: WatchMessageRewriteNavigationTarget) -> some View {
        if let message = viewModel.allMessagesForSession.first(where: { $0.id == target.id }) {
            RewriteMessageView(
                message: message,
                selectionTarget: target.selectionTarget,
                referenceVersions: MessageRewriteReferenceSupport.referenceVersions(
                    for: message,
                    in: viewModel.allMessagesForSession
                )
            ) { instruction, referenceVersions in
                viewModel.rewriteMessage(
                    message,
                    instruction: instruction,
                    referenceVersions: referenceVersions,
                    selectionTarget: target.selectionTarget
                )
            }
        } else {
            EmptyView()
        }
    }

    func restoreLaunchBackupFromPrompt() {
        launchRecoveryRequest = nil
        Task {
            do {
                let message = try await Task.detached(priority: .userInitiated) {
                    try Persistence.restorePendingLaunchBackupRequest()
                }.value
                viewModel.reloadAfterSnapshotRestore()
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryNoticeMessage = message
            } catch {
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryErrorMessage = error.localizedDescription
            }
        }
    }

}

private struct WatchLoopingBackgroundVideoView: View {
    let url: URL

    @State private var player = AVPlayer()
    @State private var endObserver: NSObjectProtocol?
    @State private var currentURL: URL?

    var body: some View {
        VideoPlayer(player: player)
            .disabled(true)
            .onAppear {
                configurePlayerIfNeeded()
                player.play()
            }
            .onDisappear {
                player.pause()
            }
            .onChange(of: url) { _, _ in
                configurePlayerIfNeeded()
                player.play()
            }
    }

    private func configurePlayerIfNeeded() {
        guard currentURL != url else { return }
        player.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [player] _ in
            player.seek(to: .zero)
            player.play()
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        currentURL = url
    }
}
