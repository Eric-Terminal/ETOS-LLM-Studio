// ============================================================================
// ChatService+AttachmentsAndRetry.swift
// ============================================================================
// ChatService 的附件文本化、OCR、消息重试与图片生成执行逻辑。
// ============================================================================

import Foundation
import Combine
import CryptoKit
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
extension ChatService {

    func preprocessFileAttachmentsForText(
        messages: [ChatMessage],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> FileAttachmentTextPreprocessingResult {
        guard !fileAttachments.isEmpty else {
            return FileAttachmentTextPreprocessingResult(messages: messages, fileAttachments: fileAttachments, errorMessage: nil)
        }

        var updatedMessages = messages
        let orderedMessageIDs = updatedMessages.map(\.id)
        let sortedPairs = fileAttachments.sorted { lhs, rhs in
            let lhsIndex = orderedMessageIDs.firstIndex(of: lhs.key) ?? Int.max
            let rhsIndex = orderedMessageIDs.firstIndex(of: rhs.key) ?? Int.max
            return lhsIndex < rhsIndex
        }

        for (messageID, attachments) in sortedPairs {
            guard let messageIndex = updatedMessages.firstIndex(where: { $0.id == messageID }) else { continue }
            var fileBlocks: [String] = []
            for attachment in attachments {
                do {
                    let text = try fileAttachmentTextExtractor.extractText(from: attachment)
                    let title = String(
                        format: NSLocalizedString("文件：%@", comment: "Extracted file attachment block title"),
                        attachment.fileName
                    )
                    fileBlocks.append("\(title)\n\(text)")
                } catch {
                    logger.error("文件附件文本提取失败: \(error.localizedDescription)")
                    let reason = localizedFileExtractionErrorDescription(error)
                    let errorMessage = String(
                        format: NSLocalizedString("附件“%@”文本提取失败：%@", comment: "File attachment extraction failed"),
                        attachment.fileName,
                        reason
                    )
                    return FileAttachmentTextPreprocessingResult(messages: messages, fileAttachments: fileAttachments, errorMessage: errorMessage)
                }
            }

            guard !fileBlocks.isEmpty else { continue }
            let appendixText = makeFileAttachmentAppendixText(fileBlocks)
            if updatedMessages[messageIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedMessages[messageIndex].content = appendixText
            } else {
                updatedMessages[messageIndex].content += "\n\n\(appendixText)"
            }
        }

        logger.info("已将文件附件转换为纯文本并附加到消息正文。")
        return FileAttachmentTextPreprocessingResult(messages: updatedMessages, fileAttachments: [:], errorMessage: nil)
    }

    func localizedFileExtractionErrorDescription(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    func makeFileAttachmentAppendixText(_ blocks: [String]) -> String {
        let joinedBlocks = blocks.joined(separator: "\n\n")
        return String(
            format: NSLocalizedString("以下内容来自文件附件文本提取：\n\n%@", comment: "File attachment text appendix sent to chat model"),
            joinedBlocks
        )
    }

    func preprocessImageAttachmentsIfNeeded(
        messages: [ChatMessage],
        imageAttachments: [UUID: [ImageAttachment]],
        targetModel: RunnableModel,
        sessionID: UUID
    ) async -> ImageOCRPreprocessingResult {
        guard !imageAttachments.isEmpty else {
            return ImageOCRPreprocessingResult(messages: messages, imageAttachments: imageAttachments, errorMessage: nil)
        }
        guard !targetModel.model.supportsVisionInput else {
            return ImageOCRPreprocessingResult(messages: messages, imageAttachments: imageAttachments, errorMessage: nil)
        }

        guard let ocrModel = resolveSelectedOCRModel() else {
            let errorMessage = NSLocalizedString("当前模型不支持图片输入，请先在专用模型里选择 OCR 模型。", comment: "Missing OCR model error")
            logger.warning("当前模型不支持图片输入，且未选择 OCR 模型。")
            return ImageOCRPreprocessingResult(messages: messages, imageAttachments: imageAttachments, errorMessage: errorMessage)
        }

        var updatedMessages = messages
        let orderedMessageIDs = updatedMessages.map(\.id)
        let sortedPairs = imageAttachments.sorted { lhs, rhs in
            let lhsIndex = orderedMessageIDs.firstIndex(of: lhs.key) ?? Int.max
            let rhsIndex = orderedMessageIDs.firstIndex(of: rhs.key) ?? Int.max
            return lhsIndex < rhsIndex
        }

        for (messageID, attachments) in sortedPairs {
            guard let messageIndex = updatedMessages.firstIndex(where: { $0.id == messageID }) else { continue }
            var ocrBlocks: [String] = []
            for (index, attachment) in attachments.enumerated() {
                do {
                    let text = try await recognizeImageText(
                        attachment,
                        using: ocrModel,
                        sessionID: sessionID
                    )
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let title = String(
                        format: NSLocalizedString("图片 %d（%@）", comment: "OCR extracted image block title"),
                        index + 1,
                        attachment.fileName
                    )
                    ocrBlocks.append("\(title)：\n\(trimmed)")
                } catch {
                    logger.error("图片 OCR 失败: \(error.localizedDescription)")
                    let title = String(
                        format: NSLocalizedString("图片 %d（%@）", comment: "OCR failed image block title"),
                        index + 1,
                        attachment.fileName
                    )
                    let fallback = String(
                        format: NSLocalizedString("%@：\nOCR 失败：%@", comment: "OCR failed block"),
                        title,
                        error.localizedDescription
                    )
                    ocrBlocks.append(fallback)
                }
            }

            guard !ocrBlocks.isEmpty else { continue }
            let ocrText = makeOCRAppendixText(ocrBlocks)
            if updatedMessages[messageIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedMessages[messageIndex].content = ocrText
            } else {
                updatedMessages[messageIndex].content += "\n\n\(ocrText)"
            }
        }

        logger.info("当前模型不支持图片输入，已将图片附件转换为 OCR 文本。")
        return ImageOCRPreprocessingResult(messages: updatedMessages, imageAttachments: [:], errorMessage: nil)
    }

    func makeOCRAppendixText(_ blocks: [String]) -> String {
        let joinedBlocks = blocks.joined(separator: "\n\n")
        return String(
            format: NSLocalizedString("以下内容来自图片 OCR 提取：\n\n%@", comment: "OCR appendix sent to chat model"),
            joinedBlocks
        )
    }

    func resolveSelectedOCRModel() -> RunnableModel? {
        let identifier = UserDefaults.standard.string(forKey: Self.ocrModelStorageKey) ?? ""
#if canImport(Vision) && !os(watchOS)
        guard !identifier.isEmpty else {
            return Self.systemOCRRunnableModel
        }
        if identifier == Self.systemOCRRunnableModel.id {
            return Self.systemOCRRunnableModel
        }
#else
        if identifier == Self.systemOCRRunnableModel.id {
            return nil
        }
#endif
        guard !identifier.isEmpty else { return nil }
        return activatedOCRModels.first(where: { $0.id == identifier })
    }

    func recognizeImageText(
        _ attachment: ImageAttachment,
        using ocrModel: RunnableModel,
        sessionID: UUID
    ) async throws -> String {
        if Self.isSystemOCRModel(ocrModel) {
            return try await SystemImageOCRService.recognizeText(in: attachment.data)
        }
        return try await recognizeImageTextWithRemoteModel(
            attachment,
            using: ocrModel,
            sessionID: sessionID
        )
    }

    func recognizeImageTextWithRemoteModel(
        _ attachment: ImageAttachment,
        using ocrModel: RunnableModel,
        sessionID: UUID
    ) async throws -> String {
        guard let adapter = adapters[ocrModel.provider.apiFormat] else {
            throw DetachedCompletionError.unsupportedAdapter
        }
        if let configurationError = providerConfigurationValidationErrorMessage(
            for: ocrModel.provider,
            action: NSLocalizedString("执行图片 OCR", comment: "Execute image OCR action")
        ) {
            throw NetworkError.invalidProviderConfiguration(message: configurationError)
        }

        let prompt = NSLocalizedString(
            "请识别这张图片中的所有可见文字，并只返回识别到的文字。不要解释、不要总结、不要使用 Markdown；如果没有可识别文字，请返回“未识别到文字”。",
            comment: "Remote OCR prompt"
        )
        let message = ChatMessage(role: .user, content: prompt)
        let payload: [String: Any] = [
            "temperature": 0,
            "stream": false
        ]
        guard let request = adapter.buildChatRequest(
            for: ocrModel,
            commonPayload: payload,
            messages: [message],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [message.id: [attachment]],
            fileAttachments: [:]
        ) else {
            throw DetachedCompletionError.buildRequestFailed
        }

        let requestContext = RequestLogContext(
            requestID: UUID(),
            sessionID: sessionID,
            providerID: ocrModel.provider.id,
            providerName: ocrModel.provider.name,
            modelID: ocrModel.model.modelName,
            requestSource: .imageOCR,
            isStreaming: false,
            requestedAt: Date()
        )

        do {
            let data = try await fetchData(for: request, provider: ocrModel.provider)
            let responseMessage = try adapter.parseResponse(data: data)
            persistRequestLog(
                context: requestContext,
                status: .success,
                tokenUsage: responseMessage.tokenUsage,
                finishedAt: Date()
            )
            return responseMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            persistRequestLog(
                context: requestContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
            throw CancellationError()
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
            throw NetworkError.badStatusCode(code: code, responseBody: bodyData)
        } catch {
            persistRequestLog(
                context: requestContext,
                status: isCancellationError(error) ? .cancelled : .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: isCancellationError(error) ? "cancelled" : "ocr_failed"
            )
            throw error
        }
    }

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
    func startRequestWithPresetMessages(
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

    func shouldRouteMessageToImageGeneration(using runnableModel: RunnableModel) -> Bool {
        runnableModel.model.supportsImageGeneration
    }

    func executeImageGenerationRequest(
        adapter: APIAdapter,
        runnableModel: RunnableModel,
        prompt: String,
        referenceImages: [ImageAttachment],
        loadingMessageID: UUID,
        currentSessionID: UUID
    ) async {
        logger.info(
            "构建生图请求: session=\(currentSessionID.uuidString), model=\(runnableModel.model.modelName), referenceCount=\(referenceImages.count)"
        )
        if let configurationError = providerConfigurationValidationErrorMessage(
            for: runnableModel.provider,
            action: NSLocalizedString("发送生图请求", comment: "Send image generation request action")
        ) {
            addErrorMessage(configurationError, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: configurationError,
                    finishedAt: Date()
                )
            )
            return
        }

        guard let request = adapter.buildImageGenerationRequest(
            for: runnableModel,
            prompt: prompt,
            referenceImages: referenceImages
        ) else {
            logger.error("生图请求构建失败: session=\(currentSessionID.uuidString)")
            let reason = NSLocalizedString("错误: 无法构建生图请求。", comment: "Failed to build image generation request")
            addErrorMessage(reason, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        logger.info("生图请求构建成功: method=\(request.httpMethod ?? "POST"), url=\(request.url?.absoluteString ?? "unknown")")

        do {
            logger.info("生图请求发送中: session=\(currentSessionID.uuidString)")
            let data = try await fetchData(for: request, provider: runnableModel.provider)
            logger.info("生图响应已返回: session=\(currentSessionID.uuidString), bytes=\(data.count)")
            let imageResults = try adapter.parseImageGenerationResponse(data: data)
            logger.info("生图响应解析完成: session=\(currentSessionID.uuidString), results=\(imageResults.count)")

            var generatedImageFileNames: [String] = []
            var revisedPrompts: [String] = []

            for (index, result) in imageResults.enumerated() {
                if let revised = result.revisedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !revised.isEmpty {
                    revisedPrompts.append(revised)
                    logger.info("生图结果[\(index)] 包含 revised prompt: length=\(revised.count)")
                }

                guard let payload = try await resolveGeneratedImagePayload(from: result, provider: runnableModel.provider) else {
                    logger.warning("生图结果[\(index)] 未解析到有效图片数据，已跳过。")
                    continue
                }

                logger.info("生图结果[\(index)] 图片负载就绪: mime=\(payload.mimeType), bytes=\(payload.data.count)")

                let ext = imageFileExtension(for: payload.mimeType)
                let fileName = "\(UUID().uuidString).\(ext)"
                if Persistence.saveImage(payload.data, fileName: fileName) != nil {
                    generatedImageFileNames.append(fileName)
                    logger.info("生图结果[\(index)] 已保存图片: \(fileName)")
                } else {
                    logger.error("生图结果[\(index)] 保存图片失败: \(fileName)")
                }
            }

            guard !generatedImageFileNames.isEmpty else {
                logger.error("生图响应中没有可保存图片: session=\(currentSessionID.uuidString)")
                let reason = NSLocalizedString("生图响应中没有可保存的图片。", comment: "No generated image could be saved")
                addErrorMessage(reason, sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                imageGenerationStatusSubject.send(
                    .failed(
                        sessionID: currentSessionID,
                        loadingMessageID: loadingMessageID,
                        prompt: prompt,
                        reason: reason,
                        finishedAt: Date()
                    )
                )
                return
            }

            let revisedPrompt = revisedPrompts.first(where: { !$0.isEmpty })
            let content = revisedPrompt ?? NSLocalizedString("[图片]", comment: "Image message placeholder")

            var messages = messagesSnapshot(for: currentSessionID)
            if let loadingIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                messages[loadingIndex] = ChatMessage(
                    id: messages[loadingIndex].id,
                    role: .assistant,
                    content: content,
                    imageFileNames: generatedImageFileNames
                )
                persistAndPublishMessages(messages, for: currentSessionID)
                logger.info(
                    "生图消息已落盘: session=\(currentSessionID.uuidString), loadingMessageID=\(loadingMessageID.uuidString), imageCount=\(generatedImageFileNames.count)"
                )
            } else {
                logger.warning("未找到生图占位消息，无法替换: loadingMessageID=\(loadingMessageID.uuidString)")
            }

            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .succeeded(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    imageFileNames: generatedImageFileNames,
                    finishedAt: Date()
                )
            )
            logger.info("生图流程完成: session=\(currentSessionID.uuidString), imageCount=\(generatedImageFileNames.count)")
        } catch is CancellationError {
            logger.info("生图请求在处理中被取消。")
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            let snippet = responseBodySnippet(from: bodyData)
            logger.error("生图请求失败(HTTP \(code)): \(snippet)")
            addErrorMessage(snippet, sessionID: currentSessionID, httpStatusCode: code)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: snippet,
                    finishedAt: Date()
                )
            )
        } catch {
            if isCancellationError(error) {
                logger.info("生图请求在处理中被取消 (URLError)。")
            } else {
                logger.error("生图请求失败: \(error.localizedDescription)")
                let reason = String(
                    format: NSLocalizedString("生图请求失败: %@", comment: "Image generation request failed with reason"),
                    error.localizedDescription
                )
                addErrorMessage(reason, sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                imageGenerationStatusSubject.send(
                    .failed(
                        sessionID: currentSessionID,
                        loadingMessageID: loadingMessageID,
                        prompt: prompt,
                        reason: reason,
                        finishedAt: Date()
                    )
                )
            }
        }
    }
}
