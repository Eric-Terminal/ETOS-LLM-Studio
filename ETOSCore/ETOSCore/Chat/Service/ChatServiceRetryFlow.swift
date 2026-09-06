// ============================================================================
// ChatServiceRetryFlow.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的消息重试、续写重试、附件恢复与重试请求任务启动。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    /// 重试指定消息，支持任意位置的消息重试
    /// 普通气泡从选中位置分叉整轮回复；轮尾工具链中断则在当前版本原地续接。
    public func retryMessage(
        _ message: ChatMessage,
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
        enableResponseSpeedMetrics: Bool = true
    ) async {
        guard let currentSession = currentSessionSubject.value else { return }

        // 先获取当前消息列表，避免取消请求时状态变化
        let messagesBeforeCancellation = messagesForSessionSubject.value

        guard let selectedMessage = ChatResponseAttemptSupport.visibleMessages(from: messagesBeforeCancellation)
            .first(where: { $0.id == message.id }) else {
            logger.warning("未找到要重试的消息")
            return
        }

        logger.info("重试消息: \(String(describing: selectedMessage.role)) - \(selectedMessage.id.uuidString)")
        let shouldRetryAsImageGeneration = shouldRetryMessageAsImageGeneration()

        // 【重要】必须先取消旧请求，再创建新的会话级请求上下文
        // 否则取消流程会把刚创建的请求上下文提前清理
        await cancelOngoingRequest()

        let messages = messagesForSessionSubject.value
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let currentMessage = visibleMessages.first(where: { $0.id == selectedMessage.id })
            ?? (selectedMessage.role == .assistant ? visibleMessages.last : nil)
        guard let currentMessage else {
            logger.warning("取消旧请求后已无可重试的消息。")
            return
        }

        guard let preparedRetry = prepareMessageRetry(
            targetMessage: currentMessage,
            in: messages
        ) else {
            logger.warning("无法为目标消息建立轮次级重试计划。")
            return
        }
        registerRetryAchievementAttempt(
            sessionID: currentSession.id,
            content: preparedRetry.representativeUserMessage?.content ?? currentMessage.content
        )
        persistAndPublishMessages(preparedRetry.storedMessages, for: currentSession.id)

        if shouldRetryAsImageGeneration {
            await retryImageGenerationMessage(
                preparedRetry: preparedRetry,
                currentSession: currentSession
            )
            return
        }

        let retryInputMessages = currentTurnUserMessages(
            containing: preparedRetry.representativeUserMessage?.id,
            in: preparedRetry.requestMessages
        )
        let imageAttachments = retryInputMessages.flatMap { requestMessage in
            requestMessage.modelVisibleImageFileNames.compactMap { fileName in
                loadImageAttachmentFromStorage(fileName: fileName)
            }
        }
        let fileAttachments = retryInputMessages.flatMap { requestMessage in
            (requestMessage.fileFileNames ?? []).compactMap { fileName in
                loadFileAttachmentFromStorage(fileName: fileName)
            }
        }

        // 请求只使用当前选中分支中截止到占位回复的内容；其他轮次和旧版本继续留在本地。
        await startRequestWithPresetMessages(
            messages: preparedRetry.requestMessages,
            loadingMessageID: preparedRetry.loadingMessage.id,
            currentSession: currentSession,
            userMessage: preparedRetry.representativeUserMessage,
            aiTemperature: aiTemperature,
            aiTopP: aiTopP,
            systemPrompt: systemPrompt,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            enhancedPrompt: enhancedPrompt,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            includeSystemTime: includeSystemTime,
            systemTimeInjectionPosition: systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
            enableResponseSpeedMetrics: enableResponseSpeedMetrics,
            currentAudioAttachment: nil,
            currentImageAttachments: imageAttachments,
            currentFileAttachments: fileAttachments,
            pendingToolCallMessageID: preparedRetry.pendingToolCallMessageID
        )
    }

    /// 在重试场景下复用现有消息列表发起请求，避免移除尾部对话
    private func startRequestWithPresetMessages(
        messages: [ChatMessage],
        loadingMessageID: UUID,
        currentSession: ChatSession,
        userMessage: ChatMessage?,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition,
        enablePeriodicTimeLandmark: Bool,
        periodicTimeLandmarkIntervalMinutes: Int,
        enableResponseSpeedMetrics: Bool,
        currentAudioAttachment: AudioAttachment?,
        currentImageAttachments: [ImageAttachment],
        currentFileAttachments: [FileAttachment],
        pendingToolCallMessageID: UUID? = nil
    ) async {
        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let agentCapabilities = AgentToolCapabilityPolicy.resolve(
            mode: Persistence.localAgentMode(sessionID: currentSession.id),
            isToolContextIsolated: currentSession.isToolContextIsolationActive,
            localLinuxEnabled: AppConfigStore.boolValue(for: .localLinuxEnabled)
        )
        let shouldPrepareAgentRun = agentCapabilities.preparesAgentRun
        let includeLocalLinuxCapability = agentCapabilities.includesLocalLinuxTools
        let selectedMCPServerIDs = shouldPrepareAgentRun
            ? MCPServerStore.loadServers().filter(\.isSelectedForChat).map(\.id)
            : []
        let requestConfiguration = ConversationRunRequestConfiguration(
            modelIdentifier: selectedModelSubject.value?.id,
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
            enableResponseSpeedMetrics: enableResponseSpeedMetrics,
            browserDataProfile: Persistence.browserAgentDataProfile(sessionID: currentSession.id),
            agentToolsEnabled: shouldPrepareAgentRun,
            localLinuxToolsEnabled: includeLocalLinuxCapability,
            selectedAgentMCPServerIDs: selectedMCPServerIDs
        )
        var runtimeRun = ConversationRun(
            sessionID: currentSession.id,
            requestConfiguration: requestConfiguration
        )
        runtimeRun.status = .running
        runtimeRun.startedAt = Date()
        runtimeRun.loadingMessageID = loadingMessageID
        _ = Persistence.saveConversationRun(runtimeRun)
        _ = Persistence.saveConversationExecutionBudget(
            ConversationExecutionBudget(
                rootRunID: runtimeRun.rootRunID,
                maximumExecutions: ConversationExecutionBudgetPolicy.configuredMaximumExecutions(),
                usedExecutions: 1
            )
        )

        let runtimeRunID = runtimeRun.id
        let rootRuntimeRunID = runtimeRun.rootRunID
        let parentRuntimeRunID = runtimeRun.parentRunID

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessageID,
                imageGenerationContext: nil,
                conversationRunID: runtimeRunID,
                rootConversationRunID: rootRuntimeRunID
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            var localAgentContext: AgentRuntimeContext?
            if includeLocalLinuxCapability {
                do {
                    let prepared = try await LocalAgentRuntimeContextManager.shared.beginRun(
                        sessionID: currentSession.id,
                        triggeringMessageID: userMessage?.id,
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
                    await LocalAgentRuntimeContextManager.shared.finishRun(id: runtimeRunID, state: .failed)
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
                localAgentContext: localAgentContext,
                agentCapabilities: agentCapabilities,
                selectedAgentMCPServerIDs: Set(selectedMCPServerIDs)
            )
            let resumedRequest: ResumedToolCallRequest
            if let pendingToolCallMessageID {
                resumedRequest = await self.resumePendingToolCalls(
                    sourceMessageID: pendingToolCallMessageID,
                    loadingMessageID: loadingMessageID,
                    sessionID: currentSession.id,
                    agentRunID: runtimeRunID
                )
                guard resumedRequest.shouldContinueRequest else {
                    await self.finishSessionRequestAndCleanupFileHistory(sessionID: currentSession.id)
                    return
                }
            } else {
                resumedRequest = ResumedToolCallRequest(
                    messages: messages,
                    shouldContinueRequest: true
                )
            }

            await self.executeMessageRequest(
                messages: resumedRequest.messages,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSession.id,
                userMessage: userMessage,
                wasTemporarySession: false,
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
                currentAudioAttachment: currentAudioAttachment,
                currentImageAttachments: currentImageAttachments,
                currentFileAttachments: currentFileAttachments
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

    private func shouldRetryMessageAsImageGeneration() -> Bool {
        guard let runnableModel = selectedModelSubject.value else { return false }
        return shouldRouteMessageToImageGeneration(using: runnableModel)
    }

    private func retryImageGenerationMessage(
        preparedRetry: PreparedMessageRetry,
        currentSession: ChatSession
    ) async {
        guard let runnableModel = selectedModelSubject.value else {
            addErrorMessage(
                NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error"),
                sessionID: currentSession.id
            )
            emitSessionRequestStatus(.error, sessionID: currentSession.id)
            return
        }

        guard shouldRouteMessageToImageGeneration(using: runnableModel) else {
            let reason = NSLocalizedString("当前模型不可用于独立生图，请在模型设置中将模型类型设为图像。", comment: "模型不是图像类型提示")
            addErrorMessage(reason, sessionID: currentSession.id)
            emitSessionRequestStatus(.error, sessionID: currentSession.id)
            return
        }

        guard let adapter = adapters[runnableModel.effectiveAPIFormat] else {
            let reason = String(
                format: NSLocalizedString("错误: 找不到适用于 '%@' 格式的 API 适配器。", comment: "Missing API adapter error"),
                runnableModel.effectiveAPIFormat
            )
            addErrorMessage(reason, sessionID: currentSession.id)
            emitSessionRequestStatus(.error, sessionID: currentSession.id)
            return
        }

        let visibleRequestMessages = ChatResponseAttemptSupport.visibleMessages(
            from: preparedRetry.requestMessages
        )
        let prompt = preparedRetry.representativeUserMessage?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            let reason = NSLocalizedString("错误: 生图提示词不能为空。", comment: "Image generation prompt empty")
            addErrorMessage(reason, sessionID: currentSession.id)
            emitSessionRequestStatus(.error, sessionID: currentSession.id)
            return
        }

        let explicitReferenceImages = currentTurnUserMessages(
            containing: preparedRetry.representativeUserMessage?.id,
            in: visibleRequestMessages
        ).flatMap(\.modelVisibleImageFileNames).compactMap { fileName in
            let attachment = loadImageAttachmentFromStorage(fileName: fileName)
            if attachment != nil {
                logger.info("重试生图时恢复参考图: \(fileName)")
            }
            return attachment
        }
        let referenceImages: [ImageAttachment]
        if explicitReferenceImages.isEmpty, runnableModel.model.supportsVisionInput {
            let userMessageID = preparedRetry.representativeUserMessage?.id
            let historyPrefix = userMessageID.flatMap { messageID in
                visibleRequestMessages.firstIndex(where: { $0.id == messageID })
            }.map { Array(visibleRequestMessages[..<$0]) } ?? visibleRequestMessages
            referenceImages = latestAssistantImageReference(
                in: historyPrefix
            ).map { [$0] } ?? []
        } else {
            referenceImages = explicitReferenceImages
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)
        imageGenerationStatusSubject.send(
            .started(
                sessionID: currentSession.id,
                loadingMessageID: preparedRetry.loadingMessage.id,
                prompt: prompt,
                startedAt: Date(),
                referenceCount: referenceImages.count
            )
        )

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: preparedRetry.loadingMessage.id,
                imageGenerationContext: ImageGenerationContext(
                    sessionID: currentSession.id,
                    loadingMessageID: preparedRetry.loadingMessage.id,
                    prompt: prompt
                )
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let modelReference = MessageModelReference(
                providerID: runnableModel.provider.id,
                providerName: runnableModel.provider.name,
                modelUUID: runnableModel.model.id,
                modelName: runnableModel.model.modelName,
                modelDisplayName: runnableModel.model.displayName
            )
            let requestLogContext = RequestLogContext(
                requestID: UUID(),
                sessionID: currentSession.id,
                providerID: runnableModel.provider.id,
                providerName: runnableModel.provider.name,
                modelID: runnableModel.model.modelName,
                requestSource: .imageGeneration,
                isStreaming: false,
                requestedAt: Date(),
                modelReference: modelReference,
                modelPricing: runnableModel.model.pricing
            )
            await self.executeImageGenerationRequest(
                adapter: adapter,
                runnableModel: runnableModel,
                prompt: prompt,
                referenceImages: referenceImages,
                loadingMessageID: preparedRetry.loadingMessage.id,
                currentSessionID: currentSession.id,
                requestLogContext: requestLogContext
            )
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken)

        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }

        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("生图重试请求已被用户取消。")
        } catch {
            if isCancellationError(error) {
                logger.info("生图重试请求已被用户取消 (URLError)。")
            } else {
                logger.error("生图重试请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }

    private func currentTurnUserMessages(
        containing messageID: UUID?,
        in messages: [ChatMessage]
    ) -> [ChatMessage] {
        guard let messageID,
              let turn = ChatConversationTurnSupport.turn(
                containingMessageID: messageID,
                in: messages
              ),
              let userRange = turn.userRange else {
            return []
        }
        return Array(messages[userRange])
    }

    public func retryLastMessage(
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
        enableResponseSpeedMetrics: Bool = true
    ) async {
        let messages = messagesForSessionSubject.value
        guard let lastMessage = ChatResponseAttemptSupport.visibleMessages(from: messages).last else { return }
        await retryMessage(
            lastMessage,
            aiTemperature: aiTemperature,
            aiTopP: aiTopP,
            systemPrompt: systemPrompt,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            enhancedPrompt: enhancedPrompt,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
            includeSystemTime: includeSystemTime,
            systemTimeInjectionPosition: systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
            enableResponseSpeedMetrics: enableResponseSpeedMetrics
        )
    }
}
