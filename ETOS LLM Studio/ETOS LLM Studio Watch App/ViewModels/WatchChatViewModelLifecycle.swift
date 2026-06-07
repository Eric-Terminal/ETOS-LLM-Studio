// ============================================================================
// WatchChatViewModelLifecycle.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的初始化后订阅、恢复与生命周期入口。
// ============================================================================

import Foundation
import Combine
import os.log
import Shared
import WatchKit

extension ChatViewModel {
    func applyAppConfigSnapshotToLocalState() {
        let appConfig = AppConfigStore.shared
        enableMarkdown = appConfig.enableMarkdown
        enableAdvancedRenderer = appConfig.enableAdvancedRenderer
        enableExperimentalToolResultDisplay = appConfig.enableExperimentalToolResultDisplay
        enableAutoReasoningPreview = appConfig.enableAutoReasoningPreview
        enableBackground = appConfig.enableBackground
        backgroundBlur = appConfig.backgroundBlur
        backgroundOpacity = appConfig.backgroundOpacity
        backgroundContentMode = appConfig.backgroundContentMode
        aiTemperature = appConfig.aiTemperature
        aiTopP = appConfig.aiTopP
        aiTemperatureEnabled = appConfig.aiTemperatureEnabled
        aiTopPEnabled = appConfig.aiTopPEnabled
        systemPrompt = appConfig.systemPrompt
        maxChatHistory = appConfig.maxChatHistory
        enableStreaming = appConfig.enableStreaming
        enableResponseSpeedMetrics = appConfig.enableResponseSpeedMetrics
        enableOpenAIStreamIncludeUsage = appConfig.enableOpenAIStreamIncludeUsage
        lazyLoadMessageCount = appConfig.lazyLoadMessageCount
        currentBackgroundImage = appConfig.currentBackgroundImage
        enableAutoRotateBackground = appConfig.enableAutoRotateBackground
        enableAutoSessionNaming = appConfig.enableAutoSessionNaming
        enableMemory = appConfig.enableMemory
        enableMemoryWrite = appConfig.enableMemoryWrite
        enableMemoryActiveRetrieval = appConfig.enableMemoryActiveRetrieval
        enableConversationMemoryAsync = appConfig.enableConversationMemoryAsync
        conversationMemoryRecentLimit = appConfig.conversationMemoryRecentLimit
        conversationMemoryRoundThreshold = appConfig.conversationMemoryRoundThreshold
        conversationMemorySummaryMinIntervalMinutes = appConfig.conversationMemorySummaryMinIntervalMinutes
        enableConversationProfileDailyUpdate = appConfig.enableConversationProfileDailyUpdate
        enableReasoningSummary = appConfig.enableReasoningSummary
        enableLiquidGlass = appConfig.enableLiquidGlass
        enableNoBubbleUI = appConfig.enableNoBubbleUI
        sendSpeechAsAudio = appConfig.sendSpeechAsAudio
        enableSpeechInput = appConfig.enableSpeechInput
        userInput = appConfig.chatComposerDraft
        speechModelIdentifier = appConfig.speechModelIdentifier
        ttsModelIdentifier = appConfig.ttsModelIdentifier
        memoryEmbeddingModelIdentifier = appConfig.memoryEmbeddingModelIdentifier
        titleGenerationModelIdentifier = appConfig.titleGenerationModelIdentifier
        dailyPulseModelIdentifier = appConfig.dailyPulseModelIdentifier
        conversationSummaryModelIdentifier = appConfig.conversationSummaryModelIdentifier
        reasoningSummaryModelIdentifier = appConfig.reasoningSummaryModelIdentifier
        ocrModelIdentifier = appConfig.ocrModelIdentifier
        includeSystemTimeInPrompt = appConfig.includeSystemTimeInPrompt
        systemTimeInjectionPositionRawValue = appConfig.systemTimeInjectionPosition
        enablePeriodicTimeLandmark = appConfig.enablePeriodicTimeLandmark
        periodicTimeLandmarkIntervalMinutes = appConfig.periodicTimeLandmarkIntervalMinutes
        audioRecordingFormatRaw = appConfig.audioRecordingFormat
        enableBackgroundReplyNotification = appConfig.enableBackgroundReplyNotification
        hasRequestedBackgroundReplyNotificationPermission = appConfig.hasRequestedBackgroundReplyNotificationPermissionWatch
    }

    func refreshAfterAppConfigPersistentStoreLoad() {
        applyAppConfigSnapshotToLocalState()
        MessageRegexRuleStore.shared.reload()
        refreshVisualMessagesAfterRegexRulesChange()
        syncSpeechModelSelection()
        syncTTSModelSelection()
        syncEmbeddingModelSelection()
        syncTitleGenerationModelSelection()
        syncDailyPulseModelSelection()
        syncConversationSummaryModelSelection()
        syncReasoningSummaryModelSelection()
        syncOCRModelSelection()
        rotateBackgroundImageIfNeeded()
        reloadGlobalSystemPromptEntries()
        reloadConversationMemoryState()
    }

    func reloadAfterSnapshotRestore() {
        AppConfigStore.shared.reloadFromPersistentStore()
        chatService.reloadProviders()
        chatService.reloadSessionStateFromPersistenceAfterMigration()
        MemoryManager.shared.reloadFromPersistenceAfterSnapshotRestore()
        DailyPulseManager.shared.reloadPersistedRuns()
        DailyPulseDeliveryCoordinator.shared.reloadFromStorage()
        reloadGlobalSystemPromptEntries()
        reloadConversationMemoryState()
    }

    func reloadGlobalSystemPromptEntries() {
        guard !isPersistingGlobalSystemPrompts else { return }
        globalSystemPromptReloadTask?.cancel()
        globalSystemPromptReloadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                GlobalSystemPromptStore.load()
            }.value

            guard let self, !Task.isCancelled, !self.isPersistingGlobalSystemPrompts else { return }
            self.applyGlobalSystemPromptSnapshot(snapshot)
        }
    }

    func persistGlobalSystemPromptEntries(selectedEntryID: UUID?) {
        globalSystemPromptReloadTask?.cancel()
        isPersistingGlobalSystemPrompts = true
        let snapshot = GlobalSystemPromptStore.save(
            entries: globalSystemPromptEntries,
            selectedEntryID: selectedEntryID
        )
        applyGlobalSystemPromptSnapshot(snapshot)
        isPersistingGlobalSystemPrompts = false
    }

    func applyGlobalSystemPromptSnapshot(_ snapshot: GlobalSystemPromptSnapshot) {
        if globalSystemPromptEntries != snapshot.entries {
            globalSystemPromptEntries = snapshot.entries
        }
        if selectedGlobalSystemPromptEntryID != snapshot.selectedEntryID {
            selectedGlobalSystemPromptEntryID = snapshot.selectedEntryID
        }
        if systemPrompt != snapshot.activeSystemPrompt {
            systemPrompt = snapshot.activeSystemPrompt
        }
    }

    @objc func handleDidBecomeActive() {
        logger.info("App became active, checking for interrupted state.")
    }

    func setupSubscriptions() {
        NotificationCenter.default.publisher(for: AppConfigStore.persistentStoreDidLoadNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAfterAppConfigPersistentStoreLoad()
            }
            .store(in: &cancellables)
        if AppConfigStore.shared.didLoadPersistentStore {
            refreshAfterAppConfigPersistentStoreLoad()
        }

        NotificationCenter.default.publisher(for: .snapshotRestoreDidFinish)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadAfterSnapshotRestore()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: MessageRegexRuleStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisualMessagesAfterRegexRulesChange()
            }
            .store(in: &cancellables)

        chatService.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.applyChatSessions(sessions)
            }
            .store(in: &cancellables)

        chatService.sessionFoldersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] folders in
                self?.applySessionFolders(folders)
            }
            .store(in: &cancellables)

        chatService.sessionTagsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tags in
                self?.applySessionTags(tags)
            }
            .store(in: &cancellables)

        chatService.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                currentSession = session
                imageGenerationFeedback = .idle
                refreshCurrentSessionSendingState()
            }
            .store(in: &cancellables)

        chatService.messagesForSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.applyMessagesUpdate(messages)
            }
            .store(in: &cancellables)

        chatService.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                guard let self = self else { return }
                self.providers = providers
                self.configuredModels = self.chatService.configuredRunnableModels
                self.applyActivatedModels(self.chatService.activatedRunnableModels)
                self.applyActivatedConversationModels(self.chatService.activatedConversationModels)
                self.applyActivatedChatModels(self.chatService.activatedChatModels)
                self.speechModels = self.chatService.activatedSpeechModels
                self.ttsModels = self.chatService.activatedTTSModels
                self.syncSpeechModelSelection()
                self.syncTTSModelSelection()
                self.syncEmbeddingModelSelection()
                self.syncTitleGenerationModelSelection()
                self.syncDailyPulseModelSelection()
                self.syncConversationSummaryModelSelection()
                self.syncReasoningSummaryModelSelection()
                self.syncOCRModelSelection()
            }
            .store(in: &cancellables)

        chatService.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self else { return }
                selectedModel = model
            }
            .store(in: &cancellables)

        chatService.runningSessionIDsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runningSessionIDs in
                guard let self else { return }
                self.runningSessionIDs = runningSessionIDs
                refreshCurrentSessionSendingState()
                if runningSessionIDs.isEmpty {
                    stopExtendedSession()
                } else {
                    startExtendedSession()
                }
                updateAutoReasoningPreviewState(with: allMessagesForSession)
            }
            .store(in: &cancellables)

        chatService.sessionRequestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event.status {
                case .started:
                    prepareBackgroundReplyNotificationContext(for: event.sessionID)
                case .finished:
                    if event.sessionID == currentSession?.id {
                        notifyIfAssistantReplyFinishedInBackground(for: event.sessionID)
                        autoPlayLatestAssistantMessageIfNeeded()
                    } else {
                        notifyIfAssistantReplyFinishedFromOffscreenSession(event.sessionID)
                    }
                case .error, .cancelled:
                    pendingReplyNotificationContextBySessionID.removeValue(forKey: event.sessionID)
                @unknown default:
                    pendingReplyNotificationContextBySessionID.removeValue(forKey: event.sessionID)
                }
            }
            .store(in: &cancellables)

        chatService.imageGenerationStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyImageGenerationStatus(status)
            }
            .store(in: &cancellables)

        MemoryManager.shared.memoriesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.memories, on: self)
            .store(in: &cancellables)

        MemoryManager.shared.dimensionMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (queryDim, indexDim) in
                self?.dimensionMismatchMessage = String(
                    format: NSLocalizedString("嵌入维度不匹配！\n查询维度: %d\n索引维度: %d\n\n请前往记忆库管理页面，点击“重新生成全部嵌入”按钮。", comment: ""),
                    queryDim,
                    indexDim
                )
                self?.showDimensionMismatchAlert = true
            }
            .store(in: &cancellables)

        MemoryManager.shared.embeddingProgressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.memoryEmbeddingProgress = progress
            }
            .store(in: &cancellables)

        MemoryManager.shared.embeddingErrorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                let message = String(
                    format: NSLocalizedString(
                        "记忆已保存，但向量嵌入失败：%@",
                        comment: "Message shown when memory text is stored but embedding generation failed."
                    ),
                    error.localizedDescription
                )
                self.presentMemoryRetryStoppedNotice()
                guard self.shouldPresentMemoryEmbeddingErrorAlert(message: message) else { return }
                self.memoryEmbeddingErrorMessage = message
                self.showMemoryEmbeddingErrorAlert = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBackgroundImages()
            }
            .store(in: &cancellables)

        ttsManager.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self else { return }
                if !speaking {
                    self.ttsManager.updateSelectedModel(self.selectedTTSModel)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .globalSystemPromptStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadGlobalSystemPromptEntries()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appToolFillUserInputRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let request = AppToolInputDraftRequest.decode(from: notification.userInfo) else { return }
                self?.applyToolInputDraftRequest(request)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appToolAskUserInputRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let request = AppToolAskUserInputRequest.decode(from: notification.userInfo) else { return }
                self?.activeAskUserInputRequest = request
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .conversationMemoryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadConversationMemoryState()
            }
            .store(in: &cancellables)

        syncSpeechModelSelection()
        syncTTSModelSelection()
        syncEmbeddingModelSelection()
        syncTitleGenerationModelSelection()
        syncDailyPulseModelSelection()
        syncConversationSummaryModelSelection()
        syncReasoningSummaryModelSelection()
        syncOCRModelSelection()
        reloadConversationMemoryState()
    }

    func applyChatSessions(_ sessions: [ChatSession]) {
        guard chatSessions != sessions else { return }
        chatSessions = sessions
        chatSessionListVersion &+= 1
    }

    func applySessionFolders(_ folders: [SessionFolder]) {
        guard sessionFolders != folders else { return }
        sessionFolders = folders
        sessionFolderListVersion &+= 1
    }

    func applySessionTags(_ tags: [SessionTag]) {
        guard sessionTags != tags else { return }
        sessionTags = tags
        chatSessionListVersion &+= 1
    }

    func applyActivatedModels(_ models: [RunnableModel]) {
        let ids = models.map(\.id)
        let identityChanged = activatedModelIDs != ids
        if activatedModels != models {
            activatedModels = models
        }
        if identityChanged {
            activatedModelIDs = ids
            activatedModelListVersion &+= 1
        }
    }

    func applyActivatedConversationModels(_ models: [RunnableModel]) {
        if activatedConversationModels != models {
            activatedConversationModels = models
        }
    }

    func applyActivatedChatModels(_ models: [RunnableModel]) {
        if activatedChatModels != models {
            activatedChatModels = models
        }
    }

}
