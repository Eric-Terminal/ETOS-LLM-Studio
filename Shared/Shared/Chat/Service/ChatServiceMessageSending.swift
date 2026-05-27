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
        isRetry: Bool = false
    ) async {
        await waitForInitialPersistenceStateIfNeeded()

        guard var currentSession = currentSessionSubject.value else {
            addErrorMessage(NSLocalizedString("错误: 没有当前会话。", comment: "No current session error"))
            requestStatusSubject.send(.error)
            return
        }

        if !isRetry {
            resetConsecutiveRetryTracking()
        }

        // 若当前模型具备图像输出能力，则主聊天输入直接切到生图请求通道。
        if let selectedModel = selectedModelSubject.value,
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
        let messageContent = applyMessageRegexRules(
            to: content.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: .user,
            mode: .persist
        )
        var savedAudioFileName: String? = nil
        var savedImageFileNames: [String] = []
        var savedFileNames: [String] = []
        let requestTimestamp = Date()
        var userMessages: [ChatMessage] = []
        var primaryUserMessage: ChatMessage?

        if let audioAttachment {
            // 保存音频文件到持久化目录，使用时间戳命名
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let audioFileName = "语音_\(timestamp).\(audioAttachment.format)"
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
                savedFileNames.append(targetName)
                logger.info("文件附件已保存或复用: \(targetName)")
            }
        }

        if !messageContent.isEmpty {
            let textMessage = ChatMessage(
                role: .user,
                content: messageContent,
                requestedAt: requestTimestamp,
                audioFileName: nil
            )
            userMessages.append(textMessage)
        }

        if let savedAudioFileName {
            userMessages.append(ChatMessage(
                role: .user,
                content: audioPlaceholder,
                requestedAt: requestTimestamp,
                audioFileName: savedAudioFileName
            ))
        }

        for imageFileName in savedImageFileNames {
            userMessages.append(ChatMessage(
                role: .user,
                content: imagePlaceholder,
                requestedAt: requestTimestamp,
                imageFileNames: [imageFileName]
            ))
        }

        for fileName in savedFileNames {
            userMessages.append(ChatMessage(
                role: .user,
                content: filePlaceholder,
                requestedAt: requestTimestamp,
                fileFileNames: [fileName]
            ))
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
        if let textMessage = userMessages.first(where: {
            $0.audioFileName == nil
                && ($0.imageFileNames?.isEmpty ?? true)
                && ($0.fileFileNames?.isEmpty ?? true)
                && !$0.content.isEmpty
        }) {
            primaryUserMessage = textMessage
        } else {
            primaryUserMessage = userMessages.first
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

        var messages = messagesSnapshot(for: currentSession.id)
        messages.append(contentsOf: userMessages)
        messages.append(loadingMessage)
        persistAndPublishMessages(messages, for: currentSession.id)
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
        if currentSession.isTemporary, let sessionTitleSource = primaryUserMessage {
            wasTemporarySession = true // 标记此为首次交互
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            currentSession.isTemporary = false
            currentSessionSubject.send(currentSession)
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) { updatedSessions[index] = currentSession }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("临时会话已转为永久会话: \(currentSession.name)")

            // 用户发送第一条消息时，立即异步生成标题（无需等待AI响应）
            let trimmedTitleSource = sessionTitleSource.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholderTitle = trimmedTitleSource == audioPlaceholder || trimmedTitleSource == imagePlaceholder || trimmedTitleSource == filePlaceholder
            if !trimmedTitleSource.isEmpty && !isPlaceholderTitle {
                let sessionIDForTitle = currentSession.id
                let userMessageForTitle = sessionTitleSource
                Task {
                    await self.generateAndApplySessionTitle(for: sessionIDForTitle, firstUserMessage: userMessageForTitle)
                }
            } else {
                logger.info("跳过自动标题生成：首条消息为空或仅包含附件占位。")
            }
        } else {
            // 老会话重新收到消息时，将其排到列表顶部
            promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
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
                enableMemory: requestTooling.policy.enableMemory,
                enableMemoryWrite: requestTooling.policy.enableMemoryWrite,
                enableMemoryActiveRetrieval: requestTooling.policy.enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                currentAudioAttachment: audioAttachment,
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
}
