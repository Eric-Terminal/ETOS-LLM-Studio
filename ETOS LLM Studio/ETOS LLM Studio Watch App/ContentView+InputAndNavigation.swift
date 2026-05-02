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

    @ViewBuilder
    func messageActionsSwipeAction(for message: ChatMessage) -> some View {
        Button {
            openMessageActions(for: message)
        } label: {
            Label(NSLocalizedString("更多", comment: ""), systemImage: "ellipsis")
        }
        .tint(.gray)
    }
    
    func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        let scrollAction = {
            // 点击回底按钮时，重置懒加载状态到初始数量
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

    func sendMessage() {
        shouldForceScrollToBottom = true
        shouldKeepBottomPinned = true
        viewModel.sendMessage()
    }

    func openSessionHistory() {
        viewModel.activeSheet = nil
        isSettingsPresented = false
        settingsDestination = nil
        if isNativeNavigationEnabled {
            nativeDestination = nil
        } else {
            isSessionListPresented = true
        }
    }

    func handleInputAction(_ state: WatchChatInputActionState) {
        switch state {
        case .stop:
            viewModel.cancelSending()
        case .send:
            sendMessage()
        case .quickRetry:
            shouldForceScrollToBottom = true
            shouldKeepBottomPinned = true
            viewModel.quickRetryLatestMessage()
        case .speechInput:
            viewModel.beginSpeechInputFlow()
        case .inactive:
            break
        }
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

    func rememberAttachmentSource(_ source: String) {
        let updatedHistory = WatchImportSourceHistory.appending(
            source,
            to: importSourceHistory
        )
        attachmentSourceHistoryRawValue = WatchImportSourceHistory.rawValue(for: updatedHistory)
        lastAttachmentSource = updatedHistory.first ?? ""
        importSourceHistory = updatedHistory
    }

    func refreshAttachmentSourceHistory() {
        importSourceHistory = WatchImportSourceHistory.values(
            from: attachmentSourceHistoryRawValue,
            fallback: lastAttachmentSource
        )
    }

    var hasPendingAttachments: Bool {
        viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty
    }

    @ViewBuilder
    var pendingAttachmentPreview: some View {
        VStack(spacing: 6) {
            if let audio = viewModel.pendingAudioAttachment {
                attachmentPreviewRow(
                    systemImage: "waveform",
                    title: NSLocalizedString("语音文件", comment: ""),
                    fileName: audio.fileName,
                    tint: .blue,
                    onRemove: {
                        viewModel.clearPendingAudioAttachment()
                    }
                )
            }

            ForEach(viewModel.pendingImageAttachments) { attachment in
                attachmentPreviewRow(
                    systemImage: "photo",
                    title: NSLocalizedString("图片文件", comment: ""),
                    fileName: attachment.fileName,
                    tint: .green,
                    onRemove: {
                        viewModel.removePendingImageAttachment(attachment)
                    }
                )
            }

            ForEach(viewModel.pendingFileAttachments) { attachment in
                attachmentPreviewRow(
                    systemImage: "doc",
                    title: NSLocalizedString("文件", comment: ""),
                    fileName: attachment.fileName,
                    tint: .cyan,
                    onRemove: {
                        viewModel.removePendingFileAttachment(attachment)
                    }
                )
            }
        }
    }

    func attachmentPreviewRow(
        systemImage: String,
        title: String,
        fileName: String,
        tint: Color,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .etFont(.system(size: 12))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .etFont(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(fileName)
                    .etFont(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(action: onRemove) {
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
    
    var transparentInputField: some View {
        ZStack(alignment: .leading) {
            Text(viewModel.userInput.isEmpty ? inputPlaceholderText : viewModel.userInput)
                .foregroundStyle(viewModel.userInput.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
            TextField("", text: $viewModel.userInput.watchKeyboardNewlineBinding())
                .textFieldStyle(.plain)
                .opacity(0.01)
                .accessibilityLabel(NSLocalizedString("输入...", comment: ""))
        }
        .etFont(.body, sampleText: viewModel.userInput.isEmpty ? inputPlaceholderText : viewModel.userInput)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: inputControlHeight, maxHeight: inputControlHeight, alignment: .leading)
        .layoutPriority(1)
    }
    
    var inputBubble: some View {
        let hasTrimmedText = !viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasTrimmedText || hasPendingAttachments
        let inputActionState = WatchChatInputActionState.resolve(
            isSending: viewModel.isSendingMessage,
            hasSendableContent: canSend,
            canQuickRetry: viewModel.canQuickRetryLatestMessage,
            isSpeechInputEnabled: viewModel.enableSpeechInput
        )
        
        let coreBubble = Group {
            VStack(spacing: 6) {
                if hasPendingAttachments {
                    pendingAttachmentPreview
                }
                
                if isLiquidGlassEnabled {
                    HStack(spacing: 10) {
                        if #available(watchOS 26.0, *) {
                            transparentInputField
                                .glassEffect(.clear, in: Capsule())

                            Button {
                                handleInputAction(inputActionState)
                            } label: {
                                Image(systemName: inputActionState.systemImageName)
                                    .etFont(.system(size: 18, weight: .medium))
                                    .frame(width: inputControlHeight, height: inputControlHeight)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.clear, in: Circle())
                            .disabled(inputActionState.isDisabled)
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

                            Button {
                                handleInputAction(inputActionState)
                            } label: {
                                Image(systemName: inputActionState.systemImageName)
                                    .etFont(.system(size: 18, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .overlay(
                                Circle()
                                    .stroke(inputStrokeColor, lineWidth: 0.8)
                            )
                            .disabled(inputActionState.isDisabled)
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

                        Button {
                            handleInputAction(inputActionState)
                        } label: {
                            Image(systemName: inputActionState.systemImageName)
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
                        .disabled(inputActionState.isDisabled)
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
        let bubbleWithTrailingSwipe = coreBubble
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    attachmentSourceText = importSourceHistory.first ?? lastAttachmentSource
                    isAttachmentImportPresented = true
                } label: {
                    Image(systemName: "plus")
                        .etFont(.system(size: 16, weight: .semibold))
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .contentShape(Circle())
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(NSLocalizedString("添加附件", comment: ""))
                .tint(.blue)
                .disabled(viewModel.attachmentImportInProgress)

                if !viewModel.userInput.isEmpty || hasPendingAttachments {
                    Button(role: .destructive) {
                        viewModel.clearUserInput()
                        viewModel.clearAllAttachments()
                    } label: {
                        Image(systemName: "trash")
                            .etFont(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(NSLocalizedString("清空输入", comment: ""))
                }
            }

        let bubbleWithLeadingSwipe: AnyView
        if isNativeNavigationEnabled {
            bubbleWithLeadingSwipe = AnyView(
                bubbleWithTrailingSwipe
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            isQuickModelSelectorPresented = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: inputControlHeight, height: inputControlHeight)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(NSLocalizedString("切换模型", comment: ""))
                        .tint(.blue)
                    }
            )
        } else {
            bubbleWithLeadingSwipe = AnyView(
                bubbleWithTrailingSwipe
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            openSessionHistory()
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: inputControlHeight, height: inputControlHeight)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(NSLocalizedString("历史会话", comment: ""))
                        .tint(.blue)
                    }
            )
        }

        return bubbleWithLeadingSwipe
            .sheet(isPresented: $isQuickModelSelectorPresented) {
                NavigationStack {
                    WatchQuickModelSelectorView(
                        models: viewModel.activatedModels,
                        selectedModel: Binding(
                            get: { viewModel.selectedModel },
                            set: { newValue in
                                viewModel.selectedModel = newValue
                                ChatService.shared.setSelectedModel(newValue)
                            }
                        )
                    )
                }
            }
            .sheet(isPresented: $isAttachmentImportPresented) {
                NavigationStack {
                    WatchImportSourceView(
                        source: $attachmentSourceText,
                        history: importSourceHistory,
                        isImporting: viewModel.attachmentImportInProgress,
                        title: NSLocalizedString("添加附件", comment: ""),
                        placeholder: NSLocalizedString("链接或文件路径", comment: ""),
                        progressTitle: NSLocalizedString("正在导入...", comment: ""),
                        confirmTitle: NSLocalizedString("导入", comment: ""),
                        onImport: {
                            let trimmedSource = attachmentSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                            rememberAttachmentSource(trimmedSource)
                            viewModel.importAttachment(from: trimmedSource)
                            isAttachmentImportPresented = false
                        },
                        onCancel: {
                            isAttachmentImportPresented = false
                        }
                    )
                }
            }
            .sheet(isPresented: speechSheetBinding) {
                SpeechRecorderView(viewModel: viewModel)
            }
            .alert(NSLocalizedString("语音输入错误", comment: ""), isPresented: speechErrorBinding) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.speechErrorMessage ?? NSLocalizedString("发生未知错误，请稍后重试。", comment: ""))
            }
            .alert(NSLocalizedString("附件导入失败", comment: ""), isPresented: $viewModel.showAttachmentImportErrorAlert) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.attachmentImportErrorMessage ?? NSLocalizedString("附件导入失败，请稍后重试。", comment: ""))
            }
            .alert(NSLocalizedString("记忆系统需要更新", comment: ""), isPresented: $viewModel.showDimensionMismatchAlert) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(viewModel.dimensionMismatchMessage)
            }
            .alert(NSLocalizedString("数据库已自动恢复", comment: ""), isPresented: Binding(
                get: { launchRecoveryNoticeMessage != nil },
                set: { if !$0 { launchRecoveryNoticeMessage = nil } }
            )) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
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
                    case .achievementJournal:
                        openAchievementJournal()
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

    func openDailyPulse() {
        if isNativeNavigationEnabled {
            settingsDestination = nil
            nativeDestination = .settings
            DispatchQueue.main.async {
                settingsDestination = .dailyPulse
            }
            return
        }
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .dailyPulse
        }
    }

    func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    func openChatSessionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.consumePendingChatSessionID() else { return }
        openChatSession(sessionID: sessionID)
    }

    func openAchievementJournalFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openAchievementJournal()
    }

    func openChatSession(sessionID: UUID) {
        guard viewModel.setCurrentSessionIfExists(sessionID: sessionID) else { return }
        if isNativeNavigationEnabled {
            nativeDestination = .chat
            return
        }
        isSettingsPresented = false
        settingsDestination = nil
    }

    func openFeedback(issueNumber: Int?) {
        if isNativeNavigationEnabled {
            settingsDestination = nil
            nativeDestination = .settings
            DispatchQueue.main.async {
                if let issueNumber,
                   FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
                    settingsDestination = .feedbackIssue(issueNumber: issueNumber)
                } else {
                    settingsDestination = .feedbackCenter
                }
            }
            return
        }
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

    func openAchievementJournal() {
        if isNativeNavigationEnabled {
            settingsDestination = nil
            nativeDestination = .settings
            DispatchQueue.main.async {
                settingsDestination = .achievementJournal
            }
            return
        }
        isSettingsPresented = true
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .achievementJournal
        }
    }

    @discardableResult
    func applyDailyPulseContinuationIfNeeded() -> Bool {
        guard let continuation = notificationCenter.consumePendingDailyPulseContinuation() else {
            return false
        }
        viewModel.applyDailyPulseContinuation(
            sessionID: continuation.sessionID,
            prompt: continuation.prompt
        )
        if isNativeNavigationEnabled {
            nativeDestination = .chat
            return true
        }
        isSettingsPresented = false
        settingsDestination = nil
        return true
    }

    var inputPlaceholderText: String {
        return NSLocalizedString("输入...", comment: "Default input placeholder on watch")
    }

    func scheduleDailyPulsePreparation(after delayNanoseconds: UInt64) {
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

    func cancelDailyPulsePreparation() {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = nil
    }
}
