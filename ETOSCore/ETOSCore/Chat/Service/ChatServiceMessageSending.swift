// ============================================================================
// ChatServiceMessageSending.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的用户消息发送入口、附件落盘、临时会话转正与请求任务启动。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public func sendAndProcessMessage(
        content: String,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool = false,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true,
        audioAttachment: AudioAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        fileAttachments: [FileAttachment] = [],
        isRetry: Bool = false,
        targetSessionID: UUID? = nil,
        messageAuthorKind: ConversationMessageAuthorKind = .user,
        sourceSessionID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        conversationEventID: UUID? = nil,
        conversationRun: ConversationRun? = nil,
        existingInputMessageID: UUID? = nil
    ) async {
        await waitForInitialPersistenceStateIfNeeded()

        let resolvedTargetSessionID = targetSessionID ?? currentSessionSubject.value?.id
        let currentSessionSnapshot = currentSessionSubject.value
        guard let resolvedTargetSessionID,
              var currentSession = currentSessionSnapshot?.id == resolvedTargetSessionID
                ? currentSessionSnapshot
                : conversationSession(withID: resolvedTargetSessionID) else {
            addErrorMessage(
                NSLocalizedString("错误: 没有目标会话。", comment: "No target session error"),
                sessionID: resolvedTargetSessionID
            )
            requestStatusSubject.send(.error)
            return
        }

        if !isRetry {
            resetConsecutiveRetryTracking()
        }

        // 只有图像类型模型进入独立生图通道，聊天模型的图片输出由对话响应处理。
        // 已排队的 Run 必须使用入队时固化的模型；用户后来切换全局模型不能污染它。
        let runConfiguredModelIdentifier = conversationRun?.requestConfiguration.modelIdentifier
        let runConfiguredModel = runConfiguredModelIdentifier.flatMap { identifier in
            activatedConversationModels.first(where: { $0.id == identifier })
        }
        if let conversationRun, runConfiguredModelIdentifier != nil, runConfiguredModel == nil {
            let reason = NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error")
            addErrorMessage(reason, sessionID: currentSession.id)
            _ = Persistence.updateConversationRunStatus(
                id: conversationRun.id,
                status: .failed,
                errorMessage: reason
            )
            requestStatusSubject.send(.error)
            return
        }
        let selectedModel = runConfiguredModel ?? currentSession.preferredModelIdentifier.flatMap { identifier in
            activatedConversationModels.first(where: { $0.id == identifier })
        } ?? selectedModelSubject.value
        if let selectedModel,
           shouldRouteMessageToImageGeneration(using: selectedModel) {
            if audioAttachment != nil {
                let reason = NSLocalizedString("生图模式不支持语音附件。", comment: "Image mode does not support audio attachments")
                addErrorMessage(reason)
                requestStatusSubject.send(.error)
                return
            }
            if !fileAttachments.isEmpty {
                let reason = NSLocalizedString("生图模式仅支持文本提示词和图片参考图。", comment: "Image mode only supports text prompt and reference images")
                addErrorMessage(reason)
                requestStatusSubject.send(.error)
                return
            }

            await generateImageAndProcessMessage(
                prompt: content,
                imageAttachments: imageAttachments,
                runnableModel: selectedModel
            )
            return
        }

        // 准备用户消息和UI占位消息
        let audioPlaceholder = NSLocalizedString("[语音消息]", comment: "Audio message placeholder")
        let imagePlaceholder = NSLocalizedString("[图片]", comment: "Image message placeholder")
        let filePlaceholder = NSLocalizedString("[文件]", comment: "File message placeholder")
        let videoPlaceholder = NSLocalizedString("[视频]", comment: "Video message placeholder")
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let messageContent = messageRegexRules.isEmpty
            ? trimmedContent
            : applyMessageRegexRules(
                to: trimmedContent,
                rules: messageRegexRules,
                scope: .user,
                mode: .persist
            )
        var savedAudioFileName: String? = nil
        var savedImageFileNames: [String] = []
        var savedFiles: [(fileName: String, isVideo: Bool)] = []
        let requestTimestamp = Date()
        var userMessages: [ChatMessage] = []
        var primaryUserMessage: ChatMessage?

        if let audioAttachment {
            // 保存音频文件到持久化目录，使用时间戳命名
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let audioFileName = String(
                format: NSLocalizedString("语音_%@.%@", comment: "Generated audio attachment file name"),
                timestamp,
                audioAttachment.format
            )
            if Persistence.saveAudio(audioAttachment.data, fileName: audioFileName) != nil {
                savedAudioFileName = audioFileName
                logger.info("音频文件已保存: \(audioFileName)")
            }
        }

        // 保存图片附件
        for imageAttachment in imageAttachments {
            let imageFileName = imageAttachment.fileName
            if Persistence.saveImage(imageAttachment.data, fileName: imageFileName) != nil {
                savedImageFileNames.append(imageFileName)
                logger.info("图片文件已保存: \(imageFileName)")
            }
        }

        // 保存文件附件
        for fileAttachment in fileAttachments {
            let originalName = (fileAttachment.fileName as NSString).lastPathComponent
            let targetName = Persistence.saveFileDeduplicatingByName(
                fileAttachment.data,
                preferredFileName: originalName
            )
            if let targetName {
                savedFiles.append((
                    fileName: targetName,
                    isVideo: VideoAttachmentSupport.isVideo(fileAttachment)
                ))
                logger.info("文件附件已保存或复用: \(targetName)")
            }
        }

        let savedVideoFileNames = savedFiles
            .filter { $0.isVideo }
            .map { $0.fileName }

        if !messageContent.isEmpty {
            let textMessage = ChatMessage(
                role: .user,
                content: messageContent,
                requestedAt: requestTimestamp,
                audioFileName: nil,
                fileFileNames: savedVideoFileNames.isEmpty
                    ? nil
                    : savedVideoFileNames,
                authorKind: messageAuthorKind,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            userMessages.append(textMessage)
            primaryUserMessage = textMessage
        }

        if let savedAudioFileName {
            userMessages.append(ChatMessage(
                role: .user,
                content: audioPlaceholder,
                requestedAt: requestTimestamp,
                audioFileName: savedAudioFileName,
                authorKind: messageAuthorKind,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            ))
        }

        for imageFileName in savedImageFileNames {
            userMessages.append(ChatMessage(
                role: .user,
                content: imagePlaceholder,
                requestedAt: requestTimestamp,
                imageFileNames: [imageFileName],
                authorKind: messageAuthorKind,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            ))
        }

        if messageContent.isEmpty, !savedVideoFileNames.isEmpty {
            userMessages.append(ChatMessage(
                role: .user,
                content: videoPlaceholder,
                requestedAt: requestTimestamp,
                fileFileNames: savedVideoFileNames,
                authorKind: messageAuthorKind,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            ))
        }

        for savedFile in savedFiles where !savedFile.isVideo {
            userMessages.append(ChatMessage(
                role: .user,
                content: filePlaceholder,
                requestedAt: requestTimestamp,
                fileFileNames: [savedFile.fileName],
                authorKind: messageAuthorKind,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            ))
        }

        if let existingInputMessageID {
            guard let existingMessage = messagesSnapshot(for: currentSession.id).first(where: {
                $0.id == existingInputMessageID && $0.role == .user
            }) else {
                addErrorMessage(
                    NSLocalizedString("错误: 未找到待处理的会话输入。", comment: "Missing queued conversation input"),
                    sessionID: currentSession.id
                )
                requestStatusSubject.send(.error)
                return
            }
            userMessages = [existingMessage]
            primaryUserMessage = existingMessage
        }

        // 兜底：如果没有生成任何用户消息，直接报错返回
        guard !userMessages.isEmpty else {
            addErrorMessage(
                NSLocalizedString("错误: 待发送消息为空。", comment: "Empty message error"),
                sessionID: currentSession.id
            )
            requestStatusSubject.send(.error)
            return
        }

        // 用于命名会话/记忆检索的代表消息：优先用户正文，其次第一条附件消息。
        if primaryUserMessage == nil {
            primaryUserMessage = userMessages.first
        }

        if messageAuthorKind == .user,
           let waitingRun = Persistence.loadLatestConversationRun(sessionID: currentSession.id),
           waitingRun.status == .waitingConversation,
           !hasActiveRequestContext(for: currentSession.id) {
            for var wait in Persistence.loadConversationWaits(waitingRunID: waitingRun.id)
                where wait.status == .pending {
                wait.status = .cancelled
                _ = Persistence.saveConversationWait(wait)
            }
            _ = Persistence.updateConversationRunStatus(id: waitingRun.id, status: .cancelled)
        }

        // 供应商请求已经发出时，用户输入先作为 steering 原子落库；协调器会在
        // 当前请求结束的安全边界启动新 Run，绝不覆盖正在执行的请求上下文。
        if existingInputMessageID == nil,
           messageAuthorKind == .user,
           hasActiveRequestContext(for: currentSession.id) {
            let eventID = UUID()
            var storedMessages: [ChatMessage] = []
            for var message in userMessages {
                message.conversationEventID = eventID
                if let stored = try? await appendConversationMessage(message, to: currentSession.id) {
                    storedMessages.append(stored)
                }
            }
            guard let triggerMessage = storedMessages.last else {
                addErrorMessage(
                    NSLocalizedString("错误: 无法保存等待处理的用户消息。", comment: "Unable to persist steering input"),
                    sessionID: currentSession.id
                )
                return
            }
            let steeringConfiguration = ConversationRunRequestConfiguration(
                modelIdentifier: selectedModel?.id,
                temperature: aiTemperature,
                topP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession.enhancedPrompt ?? enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
            let steeringRun = ConversationRun(
                sessionID: currentSession.id,
                triggerEventID: eventID,
                status: .queued,
                requestConfiguration: steeringConfiguration
            )
            _ = Persistence.saveConversationRun(steeringRun)
            _ = Persistence.saveConversationEvent(
                ConversationEvent(
                    id: eventID,
                    destinationSessionID: currentSession.id,
                    messageID: triggerMessage.id,
                    kind: .incomingMessage,
                    deliveryPolicy: .respondWhenIdle,
                    payloadJSON: encodeConversationToolResult(["source": "user_steering"])
                )
            )
            publishParticipantActivityIfNeeded(
                sessionID: currentSession.id,
                messageID: triggerMessage.id
            )
            await ConversationRunCoordinator.shared.signal()
            return
        }

        let responseAttempt = ResponseAttemptMetadata(
            groupID: userMessages[userMessages.index(before: userMessages.endIndex)].id,
            attemptID: UUID(),
            attemptIndex: 0
        )
        if let anchorUserIndex = userMessages.indices.last {
            userMessages[anchorUserIndex].selectedResponseAttemptID = responseAttempt.attemptID
            if primaryUserMessage?.id == userMessages[anchorUserIndex].id {
                primaryUserMessage = userMessages[anchorUserIndex]
            }
        }
        let previousAssistantReply = latestAssistantReply(in: currentSession.id)
        let loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: requestTimestamp,
            responseGroupID: responseAttempt.groupID,
            responseAttemptID: responseAttempt.attemptID,
            responseAttemptIndex: responseAttempt.attemptIndex,
            selectedResponseAttemptID: responseAttempt.attemptID
        ) // 内容为空的助手消息作为加载占位符
        var wasTemporarySession = false

        do {
            if existingInputMessageID == nil {
                for message in userMessages {
                    _ = try await appendConversationMessage(message, to: currentSession.id)
                }
            }
            _ = try await appendConversationMessage(loadingMessage, to: currentSession.id)
        } catch {
            addErrorMessage(
                NSLocalizedString("错误: 无法保存会话消息。", comment: "Unable to persist conversation messages"),
                sessionID: currentSession.id
            )
            requestStatusSubject.send(.error)
            return
        }
        // 请求以原子追加完成后的数据库顺序为准；读取放到后台，避免陈旧内存缓存
        // 裁掉此前由邮箱、同步或其他持久化入口写入的消息。
        let requestSessionID = currentSession.id
        let messages = await Task.detached(priority: .userInitiated) {
            Persistence.loadMessages(for: requestSessionID)
        }.value
        storeRuntimeMessagesSnapshot(messages, for: currentSession.id)
        publishMessagesIfCurrentSession(messages, for: currentSession.id)
        await consumePendingUserSteeringEvents(
            in: currentSession.id,
            includedMessageIDs: Set(messages.map(\.id))
        )
        if messageAuthorKind == .user, let primaryUserMessage {
            publishParticipantActivityIfNeeded(
                sessionID: currentSession.id,
                messageID: primaryUserMessage.id
            )
        }
        scheduleUserMessageAchievementDetectionIfNeeded(
            content: messageContent,
            userMessageCount: messages.filter { $0.role == .user }.count,
            sentAt: requestTimestamp,
            previousAssistantReply: previousAssistantReply
        )

        // 注意：当音频作为附件直接发送给模型时，不再需要后台转文字
        // 因为每次发送消息都会重新加载音频文件并以 base64 发送
        // UI 上通过 audioFileName 属性标识这是一条语音消息

        // 处理临时会话的转换
        if currentSession.isTemporary,
           !isTemporaryChatEnabled(for: currentSession.id),
           let sessionTitleSource = primaryUserMessage {
            wasTemporarySession = true // 标记此为首次交互
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            currentSession.isTemporary = false
            if currentSessionSubject.value?.id == currentSession.id {
                currentSessionSubject.send(currentSession)
            }
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) { updatedSessions[index] = currentSession }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("临时会话已转为永久会话: \(currentSession.name)")

            // 用户发送第一条消息时，立即异步生成标题（无需等待AI响应）
            let trimmedTitleSource = sessionTitleSource.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholderTitle = trimmedTitleSource == audioPlaceholder
                || trimmedTitleSource == imagePlaceholder
                || trimmedTitleSource == filePlaceholder
                || trimmedTitleSource == videoPlaceholder
            if !trimmedTitleSource.isEmpty && !isPlaceholderTitle {
                let sessionIDForTitle = currentSession.id
                let userMessageForTitle = sessionTitleSource
                Task {
                    await self.generateAndApplySessionTitle(for: sessionIDForTitle, firstUserMessage: userMessageForTitle)
                }
            } else {
                logger.info("跳过自动标题生成：首条消息为空或仅包含附件占位。")
            }
        } else if !currentSession.isTemporary {
            // 老会话重新收到消息时，将其排到列表顶部
            promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        } else if let sessionTitleSource = primaryUserMessage,
                  currentSession.name == NSLocalizedString("新的对话", comment: "Default new chat session name") {
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            if currentSessionSubject.value?.id == currentSession.id {
                currentSessionSubject.send(currentSession)
            }
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) {
                updatedSessions[index] = currentSession
                chatSessionsSubject.send(updatedSessions)
            }
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let requestConfiguration = ConversationRunRequestConfiguration(
            modelIdentifier: selectedModel?.id,
            temperature: aiTemperature,
            topP: aiTopP,
            systemPrompt: systemPrompt,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            enhancedPrompt: currentSession.enhancedPrompt ?? enhancedPrompt,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            includeSystemTime: includeSystemTime,
            systemTimeInjectionPosition: systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
            enableResponseSpeedMetrics: enableResponseSpeedMetrics
        )
        let isNewRootRun = conversationRun == nil
        var runtimeRun = conversationRun ?? ConversationRun(
            sessionID: currentSession.id,
            requestConfiguration: requestConfiguration
        )
        runtimeRun.status = .running
        runtimeRun.startedAt = runtimeRun.startedAt ?? Date()
        runtimeRun.requestConfiguration = requestConfiguration
        runtimeRun.loadingMessageID = loadingMessage.id
        _ = Persistence.saveConversationRun(runtimeRun)
        if isNewRootRun {
            _ = Persistence.saveConversationExecutionBudget(
                ConversationExecutionBudget(
                    rootRunID: runtimeRun.rootRunID,
                    maximumExecutions: ConversationExecutionBudgetPolicy.configuredMaximumExecutions(),
                    usedExecutions: 1
                )
            )
        }

        let shouldPrepareLocalAgentRun = AppConfigStore.boolValue(for: .localLinuxEnabled)
            && Persistence.localAgentMode(sessionID: currentSession.id) == .agent
            && !currentSession.isWorldbookContextIsolationActive
        let selectedMCPServerIDs = shouldPrepareLocalAgentRun
            ? MCPServerStore.loadServers().filter(\.isSelectedForChat).map(\.id)
            : []
        let runtimeRunID = runtimeRun.id
        let rootRuntimeRunID = runtimeRun.rootRunID
        let parentRuntimeRunID = runtimeRun.parentRunID

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: nil,
                conversationRunID: runtimeRun.id,
                rootConversationRunID: runtimeRun.rootRunID
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            var localAgentContext: AgentRuntimeContext?
            if shouldPrepareLocalAgentRun {
                do {
                    let prepared = try await LocalAgentRuntimeContextManager.shared.beginRun(
                        sessionID: currentSession.id,
                        triggeringMessageID: responseAttempt.groupID,
                        runID: runtimeRunID,
                        rootRunID: rootRuntimeRunID,
                        parentRunID: parentRuntimeRunID,
                        selectedMCPServerIDs: selectedMCPServerIDs,
                        browserSessionID: currentSession.id
                    )
                    localAgentContext = prepared.context
                    _ = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .agentRequest)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await LocalAgentRuntimeContextManager.shared.finishRun(
                        id: runtimeRunID,
                        state: .failed
                    )
                    _ = Persistence.updateConversationRunStatus(
                        id: runtimeRunID,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    self.addErrorMessage(
                        String(
                            format: NSLocalizedString("错误: 无法准备 Agent Run：%@", comment: "Prepare local Agent run failure"),
                            error.localizedDescription
                        ),
                        sessionID: currentSession.id
                    )
                    self.emitSessionRequestStatus(.error, sessionID: currentSession.id)
                    return
                }
            }
            let requestTooling = await self.resolveRequestTooling(
                for: currentSession,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                localAgentContext: localAgentContext
            )
            await self.executeMessageRequest(
                messages: messages,
                loadingMessageID: loadingMessage.id,
                currentSessionID: currentSession.id,
                userMessage: primaryUserMessage,
                wasTemporarySession: wasTemporarySession,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: enhancedPrompt,
                tools: requestTooling.tools,
                localAgentPrompt: localAgentContext?.promptContent,
                enableMemory: requestTooling.policy.enableMemory,
                enableMemoryWrite: requestTooling.policy.enableMemoryWrite,
                enableMemoryActiveRetrieval: requestTooling.policy.enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                currentAudioAttachment: audioAttachment,
                currentImageAttachments: imageAttachments.filter {
                    savedImageFileNames.contains($0.fileName)
                },
                currentFileAttachments: fileAttachments
            )
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken)

        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }

        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("请求已被用户取消，将等待后续动作。")
        } catch {
            // URLError.cancelled 不会匹配 CancellationError，需要单独检测
            if isCancellationError(error) {
                logger.info("请求已被用户取消 (URLError)，将等待后续动作。")
            } else {
                logger.error("请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }

    private func publishParticipantActivityIfNeeded(sessionID: UUID, messageID: UUID) {
        guard let origin = Persistence.loadConversationOrigin(childSessionID: sessionID),
              let parentSessionID = origin.parentSessionID else {
            return
        }
        _ = Persistence.saveConversationEvent(
            ConversationEvent(
                destinationSessionID: parentSessionID,
                sourceSessionID: sessionID,
                messageID: messageID,
                kind: .participantActivity,
                deliveryPolicy: .deliverOnly,
                payloadJSON: encodeConversationToolResult([
                    "conversation_id": sessionID.uuidString,
                    "activity": "user_message"
                ])
            )
        )
    }
}
