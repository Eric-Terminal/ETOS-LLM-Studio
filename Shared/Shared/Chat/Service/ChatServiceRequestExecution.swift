// ============================================================================
// ChatServiceRequestExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的聊天请求组装、附件预处理、OCR 降级与请求分发。
// ============================================================================

import Foundation
import Combine
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension ChatService {
    func openAIReasoningContentEchoModeControlValue() async -> String {
        await MainActor.run {
            ReasoningContentEchoMode.normalized(AppConfigStore.shared.reasoningContentEchoMode).rawValue
        }
    }

    func executeMessageRequest(
        messages: [ChatMessage],
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        tools: [InternalToolDefinition]?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition,
        enablePeriodicTimeLandmark: Bool,
        periodicTimeLandmarkIntervalMinutes: Int,
        enableResponseSpeedMetrics: Bool,
        currentAudioAttachment: AudioAttachment?,
        currentFileAttachments _: [FileAttachment]
    ) async {
        let currentSessionSnapshot = currentSessionSubject.value
        let sessionForRequest = currentSessionSnapshot?.id == currentSessionID
            ? currentSessionSnapshot
            : chatSessionsSubject.value.first(where: { $0.id == currentSessionID })
        let requestMessages = preparedMessagesForRequest(
            from: messages,
            loadingMessageID: loadingMessageID,
            session: sessionForRequest
        )

        var memories: [MemoryItem] = []
        if enableMemory {
            let topK = resolvedMemoryTopK()
            if topK == 0 {
                memories = await self.memoryManager.getActiveMemories()
            } else {
                let queryText = buildMemoryQueryContext(from: requestMessages, fallbackUserMessage: userMessage)
                if let queryText {
                    memories = await self.memoryManager.searchMemories(query: queryText, topK: topK)
                }
            }
            if !memories.isEmpty {
                logger.info("已检索到 \(memories.count) 条相关记忆。")
            }
        }

        let isWorldbookIsolationActive = sessionForRequest?.isWorldbookContextIsolationActive ?? false
        let conversationMemoryEnabled = enableMemory && isConversationMemoryEnabled() && !isWorldbookIsolationActive
        let recentConversationSummaries: [ConversationSessionSummary]
        let conversationUserProfile: ConversationUserProfile?
        if conversationMemoryEnabled {
            await deduplicateConversationUserProfileIfNeeded(sessionID: currentSessionID)
            recentConversationSummaries = ConversationMemoryManager.loadRecentSessionSummaries(
                limit: resolvedConversationMemoryRecentLimit(),
                excludingSessionID: currentSessionID
            )
            conversationUserProfile = ConversationMemoryManager.loadUserProfile()
        } else {
            recentConversationSummaries = []
            conversationUserProfile = nil
        }

        guard let runnableModel = selectedModelSubject.value else {
            addErrorMessage(
                NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error"),
                sessionID: currentSessionID
            )
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            return
        }

        let requestStartedAt = Date()
        let modelReference = MessageModelReference(
            providerID: runnableModel.provider.id,
            providerName: runnableModel.provider.name,
            modelUUID: runnableModel.model.id,
            modelName: runnableModel.model.modelName,
            modelDisplayName: runnableModel.model.displayName
        )
        let requestLogContext = RequestLogContext(
            requestID: UUID(),
            sessionID: currentSessionID,
            providerID: runnableModel.provider.id,
            providerName: runnableModel.provider.name,
            modelID: runnableModel.model.modelName,
            requestSource: .chat,
            isStreaming: enableStreaming,
            requestedAt: requestStartedAt,
            modelReference: modelReference,
            modelPricing: runnableModel.model.pricing
        )

        let boundWorldbooks = worldbookStore.resolveWorldbooks(ids: sessionForRequest?.lorebookIDs ?? [])
        let worldbookResult = worldbookEngine.evaluate(
            .init(
                sessionID: currentSessionID,
                worldbooks: boundWorldbooks,
                messages: requestMessages,
                topicPrompt: sessionForRequest?.topicPrompt,
                enhancedPrompt: enhancedPrompt
            )
        )

        var messagesToSend: [ChatMessage] = []
        let finalSystemPrompt = buildFinalSystemPrompt(
            global: systemPrompt,
            topic: sessionForRequest?.topicPrompt,
            memories: memories,
            recentConversationSummaries: recentConversationSummaries,
            conversationProfile: conversationUserProfile,
            includeSystemTime: includeSystemTime && systemTimeInjectionPosition == .front,
            worldbookBefore: worldbookResult.before,
            worldbookAfter: worldbookResult.after,
            worldbookANTop: worldbookResult.anTop,
            worldbookANBottom: worldbookResult.anBottom,
            worldbookOutlet: worldbookResult.outlet
        )

        if !finalSystemPrompt.isEmpty {
            messagesToSend.append(ChatMessage(role: .system, content: finalSystemPrompt))
        }

        var chatHistory = requestMessages
        if maxChatHistory > 0 && chatHistory.count > maxChatHistory {
            chatHistory = Array(chatHistory.suffix(maxChatHistory))
        }

        if enablePeriodicTimeLandmark {
            chatHistory = injectPeriodicTimeLandmarkIfNeeded(
                into: chatHistory,
                sessionID: currentSessionID,
                now: Date(),
                intervalMinutes: periodicTimeLandmarkIntervalMinutes
            )
        } else {
            periodicTimeLandmarkLastInjectedAtBySessionID.removeValue(forKey: currentSessionID)
        }

        if !worldbookResult.atDepth.isEmpty {
            chatHistory = injectAtDepthMessages(worldbookResult.atDepth, into: chatHistory)
        }

        let emTopMessages = makeWorldbookRoleMessages(worldbookResult.emTop, tag: "worldbook_em_top")
        let emBottomMessages = makeWorldbookRoleMessages(worldbookResult.emBottom, tag: "worldbook_em_bottom")

        messagesToSend.append(contentsOf: emTopMessages)
        messagesToSend.append(contentsOf: chatHistory)
        messagesToSend.append(contentsOf: emBottomMessages)

        if let enhancedPromptMessage = makeEnhancedPromptSystemMessage(enhancedPrompt) {
            messagesToSend.append(enhancedPromptMessage)
        }

        if includeSystemTime && systemTimeInjectionPosition == .tail {
            messagesToSend.append(makeSystemTimeSystemMessage())
        }

        var audioAttachments: [UUID: AudioAttachment] = [:]
        for msg in messagesToSend {
            if let currentAudio = currentAudioAttachment,
               msg.id == userMessage?.id,
               msg.audioFileName != nil {
                audioAttachments[msg.id] = currentAudio
            } else if let audioFileName = msg.audioFileName,
                      let attachment = loadAudioAttachmentFromStorage(fileName: audioFileName) {
                audioAttachments[msg.id] = attachment
                logger.info("已加载历史音频: \(audioFileName) 用于消息 \(msg.id)")
            }
        }

        var imageAttachments: [UUID: [ImageAttachment]] = [:]
        for msg in messagesToSend {
            guard let imageFileNames = msg.imageFileNames, !imageFileNames.isEmpty else { continue }
            var attachments: [ImageAttachment] = []
            for fileName in imageFileNames {
                if let attachment = loadImageAttachmentFromStorage(fileName: fileName) {
                    attachments.append(attachment)
                    logger.info("已加载历史图片: \(fileName) 用于消息 \(msg.id)")
                }
            }
            if !attachments.isEmpty {
                imageAttachments[msg.id] = attachments
            }
        }

        let imagePreprocessing = await preprocessImageAttachmentsIfNeeded(
            messages: messagesToSend,
            imageAttachments: imageAttachments,
            targetModel: runnableModel,
            sessionID: currentSessionID
        )
        if let errorMessage = imagePreprocessing.errorMessage {
            addErrorMessage(errorMessage, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "ocr_model_missing"
            )
            return
        }
        messagesToSend = imagePreprocessing.messages
        imageAttachments = imagePreprocessing.imageAttachments

        var fileAttachments: [UUID: [FileAttachment]] = [:]
        for msg in messagesToSend {
            guard let fileFileNames = msg.fileFileNames, !fileFileNames.isEmpty else { continue }
            var attachments: [FileAttachment] = []
            for fileName in fileFileNames {
                if let attachment = loadFileAttachmentFromStorage(fileName: fileName) {
                    attachments.append(attachment)
                    logger.info("已加载历史文件附件: \(fileName) 用于消息 \(msg.id)")
                }
            }
            if !attachments.isEmpty {
                fileAttachments[msg.id] = attachments
            }
        }

        let filePreprocessing = preprocessFileAttachmentsForText(
            messages: messagesToSend,
            fileAttachments: fileAttachments
        )
        if let errorMessage = filePreprocessing.errorMessage {
            addErrorMessage(errorMessage, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "file_attachment_text_extraction_failed"
            )
            return
        }
        messagesToSend = filePreprocessing.messages
        fileAttachments = filePreprocessing.fileAttachments

        if LocalModelProviderBridge.isLocalRunnableModel(runnableModel) {
            await handleLocalLLMResponse(
                runnableModel: runnableModel,
                messagesToSend: messagesToSend,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                requestStartedAt: requestStartedAt,
                requestLogContext: requestLogContext
            )
            return
        }

        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            addErrorMessage(String(
                format: NSLocalizedString("错误: 找不到适用于 '%@' 格式的 API 适配器。", comment: "Missing API adapter error"),
                runnableModel.provider.apiFormat
            ), sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "missing_adapter"
            )
            return
        }

        if let configurationError = providerConfigurationValidationErrorMessage(
            for: runnableModel.provider,
            action: NSLocalizedString("发送聊天请求", comment: "Send chat request action")
        ) {
            addErrorMessage(configurationError, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false
            )
            return
        }

        let temperatureEnabled = await MainActor.run { AppConfigStore.shared.aiTemperatureEnabled }
        let topPEnabled = await MainActor.run { AppConfigStore.shared.aiTopPEnabled }
        var commonPayload: [String: Any] = ["stream": enableStreaming]
        if temperatureEnabled { commonPayload["temperature"] = aiTemperature }
        if topPEnabled { commonPayload["top_p"] = aiTopP }
        commonPayload[ReasoningContentEchoPayload.key] = await openAIReasoningContentEchoModeControlValue()
        if adapter is OpenAIAdapter {
            let includeUsageInStream = await MainActor.run { AppConfigStore.shared.enableOpenAIStreamIncludeUsage }
            commonPayload[OpenAIAdapter.streamIncludeUsageControlKey] = includeUsageInStream
        }
        let effectiveTools = runnableModel.model.supportsToolCalling ? tools : nil
        if tools != nil, effectiveTools == nil {
            logger.info("当前模型未启用工具能力，本次请求不会附带工具定义。")
        }

        guard let request = adapter.buildChatRequest(for: runnableModel, commonPayload: commonPayload, messages: messagesToSend, tools: effectiveTools, audioAttachments: audioAttachments, imageAttachments: imageAttachments, fileAttachments: fileAttachments) else {
            let reason = providerConfigurationValidationErrorMessage(
                for: runnableModel.provider,
                action: NSLocalizedString("发送聊天请求", comment: "Send chat request action")
            ) ?? NSLocalizedString("错误: 无法构建 API 请求。", comment: "Failed to build API request error")
            addErrorMessage(reason, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false
            )
            return
        }

        if enableStreaming {
            await handleStreamedResponse(
                request: request,
                provider: runnableModel.provider,
                adapter: adapter,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                availableTools: effectiveTools,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                requestStartedAt: requestStartedAt,
                requestLogContext: requestLogContext
            )
        } else {
            await handleStandardResponse(
                request: request,
                provider: runnableModel.provider,
                adapter: adapter,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                availableTools: effectiveTools,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                requestStartedAt: requestStartedAt,
                requestLogContext: requestLogContext
            )
        }
    }

    func resolvedMimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            return "application/octet-stream"
        }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        return "application/octet-stream"
    }

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

    private func localizedFileExtractionErrorDescription(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    private func makeFileAttachmentAppendixText(_ blocks: [String]) -> String {
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

    private func makeOCRAppendixText(_ blocks: [String]) -> String {
        let joinedBlocks = blocks.joined(separator: "\n\n")
        return String(
            format: NSLocalizedString("以下内容来自图片 OCR 提取：\n\n%@", comment: "OCR appendix sent to chat model"),
            joinedBlocks
        )
    }

    func resolveSelectedOCRModel() -> RunnableModel? {
        let identifier = Persistence.readAppConfigText(key: AppConfigKey.ocrModelIdentifier.rawValue) ?? ""
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

    private func recognizeImageText(
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

    private func recognizeImageTextWithRemoteModel(
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
}
