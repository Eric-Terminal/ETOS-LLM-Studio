// ============================================================================
// WatchInputBubbleView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 聊天输入栏、附件预览、模型控制、语音与角色脚本入口。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct WatchInputBubbleView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var resourceUsageMonitor = LocalResourceUsageMonitor.shared
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared

    let isLiquidGlassEnabled: Bool
    let inputControlHeight: CGFloat
    let inputFillColor: Color
    let inputStrokeColor: Color
    let inputPlaceholderText: String
    let inputBubbleVerticalPadding: CGFloat
    let isContextCompressionAvailable: Bool
    let isTemporaryChatActivationAvailable: Bool
    let onPerformQuickAction: (WatchInputQuickAction) -> Void
    let onShowTransientNotice: (WatchChatTransientNotice) -> Void
    let onHandleInputAction: (WatchChatInputActionState) -> Void
    let onSpeechInputLayoutWillChange: () -> Void
    let onRememberAttachmentSource: (String) -> Void
    let importSourceHistory: [String]
    let lastAttachmentSource: String
    @Binding var isRequestControlsPresented: Bool
    @Binding var isAttachmentImportPresented: Bool
    @Binding var attachmentSourceText: String
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var resourceUsageTask: Task<Void, Never>?
    @State private var speechPreviewFinalizeTask: Task<Void, Never>?
    @State private var isDraftEditorPresented = false
    @State private var roleplayScriptActions: [WatchRoleplayScriptButtonAction] = []
    @State private var roleplayScriptRevision = 0
    @State private var isRoleplayScriptActionMenuPresented = false
    @State private var presentedQuickActionEdge: WatchInputQuickActionEdge?
    @State private var pendingQuickAction: WatchInputQuickAction?
    @State private var isTemporaryChatEnabled = false
    @State private var visibleLeadingQuickActions: [WatchInputQuickAction] = []
    @State private var visibleTrailingQuickActions: [WatchInputQuickAction] = []

    private var hasPendingAttachments: Bool {
        viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty
    }

    private var inputLocalPresentationBlocked: Bool {
        isRequestControlsPresented
            || isAttachmentImportPresented
            || isDraftEditorPresented
            || isRoleplayScriptActionMenuPresented
            || presentedQuickActionEdge != nil
            || viewModel.showSpeechErrorAlert
            || viewModel.showAttachmentImportErrorAlert
            || viewModel.showDimensionMismatchAlert
            || viewModel.showMemoryEmbeddingErrorAlert
    }

    private var roleplayScriptPreparationKey: String {
        "\(viewModel.currentSession?.id.uuidString ?? "none")|\(roleplayScriptRevision)"
    }

    @ViewBuilder
    private var inputTextLink: some View {
        if WatchChatInputSubmission.shouldUseBoundEditor(for: viewModel.userInput) {
            Button {
                isDraftEditorPresented = true
            } label: {
                inputLinkLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("输入...", comment: ""))
            .accessibilityValue(Text(viewModel.userInput))
        } else {
            TextFieldLink(prompt: Text(inputPlaceholderText)) {
                inputLinkLabel
            } onSubmit: { submittedText in
                viewModel.userInput = WatchChatInputSubmission.normalizedText(from: submittedText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("输入...", comment: ""))
            .accessibilityValue(Text(viewModel.userInput))
        }
    }

    private var inputLinkLabel: some View {
        inputDisplayText
            .etFont(.body, sampleText: viewModel.userInput.isEmpty ? inputSampleText : viewModel.userInput)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: inputControlHeight, maxHeight: inputControlHeight, alignment: .leading)
            .layoutPriority(1)
            .contentShape(Capsule())
    }

    private var inputSampleText: String {
        if LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) {
            return resourceUsageMonitor.snapshot.displayText
        }
        return inputPlaceholderText
    }

    @ViewBuilder
    private var inputDisplayText: some View {
        if viewModel.userInput.isEmpty {
            if LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) {
                MarqueeText(
                    content: resourceUsageMonitor.snapshot.displayText,
                    uiFont: .preferredFont(forTextStyle: .body),
                    speed: 28,
                    delay: 0.8,
                    spacing: 24
                )
                .etFont(.body, sampleText: resourceUsageMonitor.snapshot.displayText)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(inputPlaceholderText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
                    .etFont(.body, sampleText: inputPlaceholderText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(viewModel.userInput)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
                .etFont(.body, sampleText: viewModel.userInput)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        let hasTrimmedText = !viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasTrimmedText || hasPendingAttachments
        let inputActionState = WatchChatInputActionState.resolve(
            isSending: viewModel.isSendingMessage || viewModel.isSendDelayPending,
            hasSendableContent: canSend,
            canQuickRetry: viewModel.canQuickRetryLatestMessage,
            isSpeechInputEnabled: viewModel.enableSpeechInput
        )

        let coreBubble = Group {
            VStack(spacing: 6) {
                if isInlineSpeechComposerPresented {
                    inlineSpeechComposer
                } else if isLiquidGlassEnabled {
                    HStack(spacing: 10) {
                        if #available(watchOS 26.0, *) {
                            inputTextLink
                                .glassEffect(.clear, in: Capsule())

                            Button {
                                onHandleInputAction(inputActionState)
                            } label: {
                                Image(systemName: inputActionState.systemImageName)
                                    .etFont(.system(size: 18, weight: .medium))
                                    .frame(width: inputControlHeight, height: inputControlHeight)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.clear, in: Circle())
                            .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
                        } else {
                            ZStack {
                                Capsule()
                                    .fill(inputFillColor)
                                    .overlay(
                                        Capsule()
                                            .stroke(inputStrokeColor, lineWidth: 0.6)
                                    )
                                inputTextLink
                            }

                            Button {
                                onHandleInputAction(inputActionState)
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
                            .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
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
                            inputTextLink
                        }

                        Button {
                            onHandleInputAction(inputActionState)
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
                        .disabled(inputActionState.isDisabled || viewModel.attachmentImportInProgress)
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
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isInlineSpeechComposerPresented)

        return coreBubble
            .onLongPressGesture(minimumDuration: 0.5) {
                if let model = viewModel.selectedModel,
                   !model.model.requestBodyControls.filter(\.isEnabled).isEmpty {
                    isRequestControlsPresented = true
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                quickActionButtons(for: .trailing)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                quickActionButtons(for: .leading)
            }
            .sheet(item: $presentedQuickActionEdge, onDismiss: performPendingQuickAction) { edge in
                NavigationStack {
                    quickActionFolder(for: edge)
                }
            }
            .sheet(isPresented: $isRequestControlsPresented) {
                if let selectedModel = viewModel.selectedModel {
                    NavigationStack {
                        WatchQuickRequestControlsView(
                            runnableModel: selectedModel,
                            onDone: { isRequestControlsPresented = false }
                        )
                    }
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
                            onRememberAttachmentSource(trimmedSource)
                            viewModel.importAttachment(from: trimmedSource)
                            isAttachmentImportPresented = false
                        },
                        onCancel: {
                            isAttachmentImportPresented = false
                        }
                    )
                }
            }
            .sheet(isPresented: $isDraftEditorPresented) {
                WatchChatDraftEditorView(
                    text: $viewModel.userInput,
                    placeholder: inputPlaceholderText
                )
            }
            .confirmationDialog(
                NSLocalizedString("助手脚本", comment: "Watch roleplay script action menu"),
                isPresented: $isRoleplayScriptActionMenuPresented,
                titleVisibility: .visible
            ) {
                ForEach(roleplayScriptActions) { action in
                    Button(action.name) {
                        performRoleplayScriptAction(action)
                    }
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
            }
            .alert(NSLocalizedString("语音输入错误", comment: ""), isPresented: Binding(
                get: { viewModel.showSpeechErrorAlert },
                set: { viewModel.showSpeechErrorAlert = $0 }
            )) {
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
            .alert(
                Text(NSLocalizedString("记忆嵌入失败", comment: "Memory embedding failure alert title")),
                isPresented: $viewModel.showMemoryEmbeddingErrorAlert
            ) {
                Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) { }
            } message: {
                Text(viewModel.memoryEmbeddingErrorMessage)
            }
            .onAppear {
                refreshTemporaryChatState()
                refreshVisibleQuickActions()
                updateResourceUsageSampling()
                refreshInputLocalPresentationBlocker()
            }
            .task(id: roleplayScriptPreparationKey) {
                await loadRoleplayScriptActions()
            }
            .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { notification in
                if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind {
                    roleplayScriptRevision &+= 1
                }
            }
            .onReceive(appConfig.$watchInputQuickActionSettings) { configuration in
                refreshVisibleQuickActions(using: configuration)
            }
            .onChange(of: viewModel.selectedModel?.id) { _, _ in
                updateResourceUsageSampling()
                refreshVisibleQuickActions()
            }
            .onChange(of: viewModel.currentSession?.id) { _, _ in
                refreshTemporaryChatState()
            }
            .onChange(of: viewModel.userInput.isEmpty) { _, _ in
                refreshVisibleQuickActions()
            }
            .onChange(of: hasPendingAttachments) { _, _ in
                refreshVisibleQuickActions()
            }
            .onChange(of: inputLocalPresentationBlocked) { _, _ in
                refreshInputLocalPresentationBlocker()
            }
            .onDisappear {
                stopResourceUsageSampling()
                speechPreviewFinalizeTask?.cancel()
                speechPreviewFinalizeTask = nil
                setInputLocalPresentationBlocked(false)
            }
    }

    @ViewBuilder
    private func quickActionButtons(for edge: WatchInputQuickActionEdge) -> some View {
        let actions = visibleQuickActions(for: edge)
        if actions.count > 3 {
            Button {
                presentedQuickActionEdge = edge
            } label: {
                Image(systemName: "ellipsis")
            }
            .tint(.gray)
            .accessibilityLabel(NSLocalizedString("更多快捷功能", comment: "Watch collapsed quick actions"))
        } else {
            ForEach(actions) { action in
                quickActionButton(action)
            }
        }
    }

    private func quickActionFolder(for edge: WatchInputQuickActionEdge) -> some View {
        List {
            ForEach(visibleQuickActions(for: edge)) { action in
                Button {
                    pendingQuickAction = action
                    presentedQuickActionEdge = nil
                } label: {
                    HStack {
                        Image(systemName: systemImage(for: action))
                            .foregroundStyle(action.tint)
                            .frame(width: 24)

                        VStack(alignment: .leading) {
                            Text(action.title)
                            if action == .temporaryChat && isQuickActionDisabled(action) {
                                Text(NSLocalizedString("仅可在对话开始前开启", comment: "Watch temporary chat availability"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isQuickActionDisabled(action))
            }
        }
        .navigationTitle(NSLocalizedString("快捷功能", comment: "Watch collapsed quick actions title"))
    }

    @ViewBuilder
    private func quickActionButton(_ action: WatchInputQuickAction) -> some View {
        if action == .clearInput {
            Button(role: .destructive) {
                performQuickAction(action)
            } label: {
                quickActionIcon(action)
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(action.title)
        } else {
            Button {
                performQuickAction(action)
            } label: {
                quickActionIcon(action)
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(action.title)
            .tint(action.tint)
            .disabled(isQuickActionDisabled(action))
        }
    }

    private func quickActionIcon(_ action: WatchInputQuickAction) -> some View {
        Image(systemName: systemImage(for: action))
            .etFont(.system(size: 16, weight: .semibold))
            .frame(width: inputControlHeight, height: inputControlHeight)
            .contentShape(Circle())
    }

    private func visibleQuickActions(for edge: WatchInputQuickActionEdge) -> [WatchInputQuickAction] {
        switch edge {
        case .leading:
            return visibleLeadingQuickActions
        case .trailing:
            return visibleTrailingQuickActions
        }
    }

    private func refreshVisibleQuickActions(
        using configuration: WatchInputQuickActionConfiguration? = nil
    ) {
        let configuration = configuration ?? appConfig.watchInputQuickActionSettings
        visibleLeadingQuickActions = configuration.leadingActions.filter(shouldShowQuickAction)
        visibleTrailingQuickActions = configuration.trailingActions.filter(shouldShowQuickAction)
    }

    private func systemImage(for action: WatchInputQuickAction) -> String {
        guard action == .temporaryChat else { return action.systemImage }
        return isTemporaryChatEnabled ? "eye.slash" : "eye"
    }

    private func shouldShowQuickAction(_ action: WatchInputQuickAction) -> Bool {
        switch action {
        case .requestControls:
            return viewModel.selectedModel?.model.requestBodyControls.contains(where: \.isEnabled) == true
        case .roleplayScripts:
            return !roleplayScriptActions.isEmpty
        case .clearInput:
            return !viewModel.userInput.isEmpty || hasPendingAttachments
        default:
            return true
        }
    }

    private func isQuickActionDisabled(_ action: WatchInputQuickAction) -> Bool {
        switch action {
        case .contextCompression:
            return !isContextCompressionAvailable
        case .addAttachment:
            return viewModel.attachmentImportInProgress
        case .temporaryChat:
            return !TemporaryChatToggleAvailability.isAvailable(
                isTemporaryChatEnabled: isTemporaryChatEnabled,
                hasConversationStarted: !isTemporaryChatActivationAvailable
            )
        default:
            return false
        }
    }

    private func performQuickAction(_ action: WatchInputQuickAction) {
        switch action {
        case .requestControls:
            isRequestControlsPresented = true
        case .roleplayScripts:
            isRoleplayScriptActionMenuPresented = true
        case .temporaryChat:
            setTemporaryChatEnabled(!isTemporaryChatEnabled)
        case .addAttachment:
            attachmentSourceText = importSourceHistory.first ?? lastAttachmentSource
            isAttachmentImportPresented = true
        case .clearInput:
            viewModel.clearUserInput()
            viewModel.clearAllAttachments()
        case .sessionHistory,
             .contextCompression,
             .settings,
             .toolCenter,
             .dailyPulse,
             .usageAnalytics,
             .imageGallery,
             .memory,
             .mcp,
             .agentSkills,
             .shortcuts,
             .roleplay,
             .worldbook,
             .extendedFeatures:
            onPerformQuickAction(action)
        }
    }

    private func performPendingQuickAction() {
        guard let action = pendingQuickAction else { return }
        pendingQuickAction = nil
        performQuickAction(action)
    }

    private func setTemporaryChatEnabled(_ isEnabled: Bool) {
        guard TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: isTemporaryChatEnabled,
            hasConversationStarted: !isTemporaryChatActivationAvailable
        ) else { return }

        if isEnabled {
            viewModel.enableTemporaryChat()
        } else {
            viewModel.saveCurrentTemporarySession()
        }
        isTemporaryChatEnabled = isEnabled
        onShowTransientNotice(
            WatchChatTransientNotice(
                message: isEnabled
                    ? NSLocalizedString("临时对话已开启", comment: "Watch temporary chat status")
                    : NSLocalizedString("临时对话已关闭", comment: "Watch temporary chat status"),
                systemImage: isEnabled ? "eye.slash" : "eye",
                tint: isEnabled ? .accentColor : .secondary
            )
        )
    }

    private func refreshTemporaryChatState() {
        isTemporaryChatEnabled = viewModel.isTemporaryChatEnabled(for: viewModel.currentSession?.id)
    }

    private var isInlineSpeechComposerPresented: Bool {
        viewModel.isSpeechRecorderPresented
            || viewModel.isSpeechRecordingPreparing
            || viewModel.isRecordingSpeech
            || viewModel.speechTranscriptionInProgress
    }

    private var inlineSpeechComposer: some View {
        WatchInlineSpeechComposerView(
            viewModel: viewModel,
            inputControlHeight: inputControlHeight,
            inputFillColor: inputFillColor,
            inputStrokeColor: inputStrokeColor,
            onCancel: cancelInlineSpeechRecording,
            onStop: stopInlineSpeechRecording,
            onConfirm: confirmInlineSpeechRecording
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func stopInlineSpeechRecording() {
        onSpeechInputLayoutWillChange()
        viewModel.stopSpeechRecordingForPreview()
        if viewModel.sendSpeechAsAudio {
            scheduleInlineAudioAttachment()
        } else {
            viewModel.prepareSpeechTranscriptPreview()
        }
    }

    private func confirmInlineSpeechRecording() {
        onSpeechInputLayoutWillChange()
        speechPreviewFinalizeTask?.cancel()
        speechPreviewFinalizeTask = nil
        viewModel.finishSpeechRecording()
    }

    private func cancelInlineSpeechRecording() {
        onSpeechInputLayoutWillChange()
        speechPreviewFinalizeTask?.cancel()
        speechPreviewFinalizeTask = nil
        viewModel.cancelSpeechRecording()
    }

    @MainActor
    private func loadRoleplayScriptActions() async {
        guard let sessionID = viewModel.currentSession?.id else {
            roleplayScriptActions = []
            refreshVisibleQuickActions()
            return
        }
        roleplayScriptActions = await Task.detached(priority: .utility) { () -> [WatchRoleplayScriptButtonAction] in
            let store = RoleplayStore.shared
            guard let binding = store.binding(sessionID: sessionID), binding.helperScriptsEnabled else { return [] }
            return binding.characterIDs.compactMap(store.character(id:)).flatMap { character in
                character.helperScripts.filter(\.enabled).flatMap { script in
                    script.buttons.filter(\.visible).map {
                        WatchRoleplayScriptButtonAction(
                            sessionID: sessionID,
                            scriptID: script.id,
                            buttonID: $0.id,
                            name: $0.name
                        )
                    }
                }
            }
        }.value
        refreshVisibleQuickActions()
    }

    private func performRoleplayScriptAction(_ action: WatchRoleplayScriptButtonAction) {
        NotificationCenter.default.post(
            name: RoleplayScriptButtonNotification.requested,
            object: nil,
            userInfo: [
                RoleplayScriptButtonNotification.sessionIDKey: action.sessionID,
                RoleplayScriptButtonNotification.scriptIDKey: action.scriptID,
                RoleplayScriptButtonNotification.buttonNameKey: action.name
            ]
        )
    }

    private func scheduleInlineAudioAttachment() {
        speechPreviewFinalizeTask?.cancel()
        speechPreviewFinalizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            viewModel.finishSpeechRecording()
        }
    }

    private func setInputLocalPresentationBlocked(_ blocked: Bool) {
        toolPermissionCenter.setAutoPresentationBlocked(blocked, reason: "watch.input.presentation")
    }

    private func refreshInputLocalPresentationBlocker() {
        setInputLocalPresentationBlocked(inputLocalPresentationBlocked)
    }

    private func updateResourceUsageSampling() {
        guard LocalModelProviderBridge.isLocalRunnableModel(viewModel.selectedModel) else {
            stopResourceUsageSampling()
            return
        }
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

    private func stopResourceUsageSampling() {
        resourceUsageTask?.cancel()
        resourceUsageTask = nil
    }
}

private struct WatchRoleplayScriptButtonAction: Identifiable, Sendable {
    var id: String { "\(scriptID.uuidString):\(buttonID.uuidString)" }
    let sessionID: UUID
    let scriptID: UUID
    let buttonID: UUID
    let name: String
}

struct WatchPendingAttachmentRowView: View {
    let systemImage: String
    let title: String
    let fileName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .etFont(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .etFont(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(fileName)
                    .etFont(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct WatchAttachmentImportProgressRowView: View {
    let progress: WatchAttachmentImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .etFont(.system(size: 13))
                    .foregroundStyle(.blue)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("正在下载附件", comment: "Watch attachment import progress title"))
                        .etFont(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(progress.sourceName)
                        .etFont(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: 4)

                if progress.isDeterminate {
                    Text(String(format: "%d%%", progress.displayPercentage))
                        .etFont(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                } else {
                    ProgressView()
                }
            }

            if progress.isDeterminate {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: "Watch attachment import downloaded bytes"),
                        StorageUtility.formatTransferSize(progress.bytesReceived),
                        StorageUtility.formatTransferSize(progress.totalBytes)
                    )
                )
                .etFont(.system(size: 9))
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct WatchChatDraftEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let placeholder: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $text.watchKeyboardNewlineBinding(), axis: .vertical)
                } footer: {
                    Text(NSLocalizedString("继续编辑当前聊天草稿。", comment: "Watch chat draft editor footer"))
                }
            }
            .navigationTitle(NSLocalizedString("输入", comment: "Watch chat draft editor title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "Done button")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
