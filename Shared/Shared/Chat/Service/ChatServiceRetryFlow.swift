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
    /// - 对于 user 消息：保留下游对话，在该 user 对应回复位置插入新版本，重新发送该 user。
    /// - 对于 assistant/error 消息：回溯到上一个 user 重新生成回复，并保留后续对话。
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
        let messages = messagesForSessionSubject.value

        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            logger.warning("未找到要重试的消息")
            return
        }

        logger.info("重试消息: \(String(describing: message.role)) - 索引 \(messageIndex)")

        // 决定重试时要重发的 user 消息，以及保留下来的前缀/后缀
        // 核心逻辑：无论重试什么消息，都找到对应的 user 消息重新发送
        let anchorUserIndex: Int
        var messageToSend: ChatMessage

        switch message.role {
        case .user:
            // user 重试：直接重试该 user 消息
            anchorUserIndex = messageIndex
            messageToSend = message
        case .assistant, .error:
            // assistant/error 重试：回到上一个 user，本质等同于重试那个 user
            guard let previousUserIndex = messages[..<messageIndex].lastIndex(where: { $0.role == .user }) else {
                logger.warning("未找到该 \(message.role.rawValue) 消息之前的 user 消息，无法重试")
                return
            }
            anchorUserIndex = previousUserIndex
            messageToSend = messages[previousUserIndex]
        default:
            logger.warning("不支持重试 \(String(describing: message.role)) 类型的消息")
            return
        }
        registerRetryAchievementAttempt(sessionID: currentSession.id, content: messageToSend.content)
        let shouldContinueFromTail = isTailContinuationRetryTarget(message, in: messages)

        // 【重要】必须先取消旧请求，再创建新的会话级请求上下文
        // 否则取消流程会把刚创建的请求上下文提前清理
        await cancelOngoingRequest()

        var updatedMessages = messages
        let retryRequestedAt = Date()
        let loadingMessage: ChatMessage
        let insertionIndex: Int
        if shouldContinueFromTail {
            let metadata = continuationAttemptMetadata(
                for: message,
                in: updatedMessages,
                anchorUserIndex: anchorUserIndex,
                targetIndex: messageIndex
            )
            if message.role == .error {
                updatedMessages.remove(at: messageIndex)
            }
            let referenceIndex = min(message.role == .error ? messageIndex - 1 : messageIndex, updatedMessages.index(before: updatedMessages.endIndex))
            var continuationLoadingMessage = ChatMessage(
                role: .assistant,
                content: "",
                requestedAt: retryRequestedAt
            )
            applyResponseAttemptMetadata(metadata, to: &continuationLoadingMessage)
            if let metadata,
               let anchorIndex = updatedMessages.firstIndex(where: { $0.id == metadata.groupID && $0.role == .user }) {
                updatedMessages[anchorIndex].selectedResponseAttemptID = metadata.attemptID
            }
            loadingMessage = continuationLoadingMessage
            insertionIndex = continuationInsertionIndex(
                in: updatedMessages,
                referenceIndex: max(anchorUserIndex, referenceIndex),
                metadata: metadata
            )
        } else {
            let responseAttempt = prepareRetryAttemptMetadata(
                in: &updatedMessages,
                anchorUserIndex: anchorUserIndex
            )
            loadingMessage = ChatMessage(
                role: .assistant,
                content: "",
                requestedAt: retryRequestedAt,
                responseGroupID: responseAttempt.groupID,
                responseAttemptID: responseAttempt.attemptID,
                responseAttemptIndex: responseAttempt.attemptIndex
            )
            insertionIndex = responseRoundEndIndex(in: updatedMessages, anchorUserIndex: anchorUserIndex)
        }
        updatedMessages.insert(loadingMessage, at: insertionIndex)
        messageToSend = updatedMessages[anchorUserIndex]
        retryTargetMessageID = nil
        retryTargetOriginalAssistantMessage = nil

        persistAndPublishMessages(updatedMessages, for: currentSession.id)
        let actualLoadingMessageID = loadingMessage.id
        // 保留尾部只用于本地消息列表，请求上下文截止到新占位回复。
        let requestMessages = Array(updatedMessages.prefix(through: insertionIndex))

        // 恢复原消息的音频附件（如果有）
        var audioAttachment: AudioAttachment? = nil
        if let audioFileName = messageToSend.audioFileName,
           let restoredAudioAttachment = loadAudioAttachmentFromStorage(fileName: audioFileName) {
            audioAttachment = restoredAudioAttachment
            logger.info("重试时恢复音频附件: \(audioFileName)")
        }

        // 恢复原消息的文件附件（如果有）
        var fileAttachments: [FileAttachment] = []
        if let fileFileNames = messageToSend.fileFileNames {
            for fileName in fileFileNames {
                if let attachment = loadFileAttachmentFromStorage(fileName: fileName) {
                    fileAttachments.append(attachment)
                    logger.info("重试时恢复文件附件: \(fileName)")
                }
            }
        }

        // 使用原消息内容和附件发起请求，尾部对话已在本地保留但不参与本次请求。
        await startRequestWithPresetMessages(
            messages: requestMessages,
            loadingMessageID: actualLoadingMessageID,  // 使用局部变量，避免强制解包可能导致的崩溃
            currentSession: currentSession,
            userMessage: messageToSend,
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
            currentAudioAttachment: audioAttachment,
            currentFileAttachments: fileAttachments
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
        currentFileAttachments: [FileAttachment]
    ) async {
        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessageID,
                imageGenerationContext: nil
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let requestTooling = await self.resolveRequestTooling(
                for: currentSession,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval
            )

            await self.executeMessageRequest(
                messages: messages,
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
                enableMemory: requestTooling.policy.enableMemory,
                enableMemoryWrite: requestTooling.policy.enableMemoryWrite,
                enableMemoryActiveRetrieval: requestTooling.policy.enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                currentAudioAttachment: currentAudioAttachment,
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
        guard let lastUserMessageIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let lastUserMessage = messages[lastUserMessageIndex]
        await retryMessage(
            lastUserMessage,
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
