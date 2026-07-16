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
    /// 在请求真正进入本地或远程执行器前，将当次发送的全部 system 消息保存到对应回复。
    func persistSentSystemPromptSnapshot(
        from messagesToSend: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID
    ) {
        let snapshot = messagesToSend
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        var persistedMessages = messagesSnapshot(for: sessionID)
        guard let index = persistedMessages.firstIndex(where: { $0.id == loadingMessageID }) else {
            logger.warning("无法记录系统提示词快照：未找到回复占位消息 \(loadingMessageID)。")
            return
        }
        persistedMessages[index].sentSystemPromptSnapshot = snapshot
        persistAndPublishMessages(persistedMessages, for: sessionID)
    }

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
        let continuationMessages: [ChatMessage]
        do {
            continuationMessages = try await Task.detached(priority: .userInitiated) {
                try Persistence.loadConversationContinuationContext(for: currentSessionID)
            }.value.map(ContextCompressionPromptBuilder.continuationRequestMessages) ?? []
        } catch {
            addErrorMessage(
                String(
                    format: NSLocalizedString("错误: 无法读取续聊上下文：%@", comment: "Continuation context load error"),
                    error.localizedDescription
                ),
                sessionID: currentSessionID
            )
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            return
        }
        let preparedRequestMessages = preparedMessagesForRequest(
            from: messages,
            loadingMessageID: loadingMessageID,
            session: sessionForRequest
        )
        var resolvedRoleplay = RoleplayRuntime.resolve(
            sessionID: currentSessionID,
            messages: preparedRequestMessages,
            store: roleplayStore
        )
        var requestMessages = preparedRequestMessages
        if var resolved = resolvedRoleplay {
            requestMessages = RoleplayRuntime.transformedRequestMessages(
                preparedRequestMessages,
                resolved: &resolved
            )
            if resolved.variables != roleplayStore.variableSnapshot(sessionID: currentSessionID) {
                roleplayStore.saveVariableSnapshot(resolved.variables, sessionID: currentSessionID)
            }
            resolvedRoleplay = resolved
        }
        let helperScriptIDs = resolvedRoleplay.map { resolved -> [UUID] in
            guard resolved.binding.helperScriptsEnabled else { return [] }
            return resolved.characters.flatMap { character in
                character.helperScripts.filter(\.enabled).map(\.id)
            }
        } ?? []
        if !helperScriptIDs.isEmpty {
            for index in requestMessages.indices where requestMessages[index].content.contains("{{") {
                requestMessages[index].content = await RoleplayMacroExpansionBridge.shared.expand(
                    requestMessages[index].content,
                    sessionID: currentSessionID,
                    scriptIDs: helperScriptIDs
                )
            }
        }

        var memories: [MemoryItem] = []
        if enableMemory {
            let topK = resolvedMemoryTopK()
            if topK == 0 {
                memories = await self.memoryManager.getActiveMemories()
            } else {
                let queryText = buildMemoryQueryContext(from: requestMessages, fallbackUserMessage: userMessage)
                if let queryText {
                    memories = await self.memoryManager.searchMemoriesHybrid(query: queryText, topK: topK)
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

        let effectiveStreaming = resolvedRequestStreamingEnabled(
            preference: enableStreaming,
            overrides: runnableModel.effectiveOverrideParameters
        )

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
            isStreaming: effectiveStreaming,
            requestedAt: requestStartedAt,
            modelReference: modelReference,
            modelPricing: runnableModel.model.pricing
        )

        var boundWorldbookIDs = sessionForRequest?.lorebookIDs ?? []
        if let resolvedRoleplay {
            boundWorldbookIDs.append(contentsOf: resolvedRoleplay.worldbookIDs)
        }
        var seenWorldbookIDs = Set<UUID>()
        boundWorldbookIDs = boundWorldbookIDs.filter { seenWorldbookIDs.insert($0).inserted }
        var boundWorldbooks = worldbookStore.resolveWorldbooks(ids: boundWorldbookIDs)
        if let resolvedRoleplay {
            boundWorldbooks = RoleplayRuntime.resolvedWorldbooks(
                boundWorldbooks,
                macroContext: resolvedRoleplay.macroContext
            )
        }
        var promptTemplateMacroContext = resolvedRoleplay?.macroContext ?? RoleplayMacroContext(
            variables: roleplayStore.variableSnapshot(sessionID: currentSessionID),
            lastMessage: requestMessages.last?.content ?? "",
            lastUserMessage: requestMessages.last(where: { $0.role == .user })?.content ?? "",
            lastCharacterMessage: requestMessages.last(where: { $0.role == .assistant })?.content ?? "",
            messageCount: requestMessages.count,
            chatSeed: currentSessionID.uuidString
        )
        boundWorldbooks = await RoleplayPromptTemplateRenderer.preprocessWorldbooks(
            boundWorldbooks,
            messages: requestMessages,
            regexRules: resolvedRoleplay?.regexRules ?? [],
            macroContext: &promptTemplateMacroContext
        )
        var worldbookResult = await worldbookEngine.evaluateAsync(
            .init(
                sessionID: currentSessionID,
                worldbooks: boundWorldbooks,
                messages: requestMessages,
                topicPrompt: sessionForRequest?.topicPrompt,
                enhancedPrompt: enhancedPrompt,
                personaDescription: resolvedRoleplay?.persona?.description,
                characterDescription: resolvedRoleplay?.characters.first?.description,
                characterPersonality: resolvedRoleplay?.characters.first?.personality,
                characterDepthPrompt: resolvedRoleplay?.characters.first?.postHistoryInstructions,
                scenario: resolvedRoleplay?.characters.first?.scenario,
                creatorNotes: resolvedRoleplay?.characters.first?.creatorNotes
            )
        )
        worldbookResult = await RoleplayPromptTemplateRenderer.renderWorldbookEvaluation(
            worldbookResult,
            worldbooks: boundWorldbooks,
            chatHistory: requestMessages,
            regexRules: resolvedRoleplay?.regexRules ?? [],
            macroContext: &promptTemplateMacroContext
        )

        var messagesToSend: [ChatMessage] = []
        var finalSystemPrompt = buildFinalSystemPrompt(
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
            roleplayPrompt: resolvedRoleplay.map(RoleplayRuntime.roleplaySystemPrompt)
        )
        if !helperScriptIDs.isEmpty, finalSystemPrompt.contains("{{") {
            finalSystemPrompt = await RoleplayMacroExpansionBridge.shared.expand(
                finalSystemPrompt,
                sessionID: currentSessionID,
                scriptIDs: helperScriptIDs
            )
        }

        if !finalSystemPrompt.isEmpty {
            messagesToSend.append(ChatMessage(role: .system, content: finalSystemPrompt))
        }

        var chatHistory = requestMessages
        if maxChatHistory > 0 && chatHistory.count > maxChatHistory {
            chatHistory = limitedChatHistory(chatHistory, maxMessages: maxChatHistory)
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

        if let resolvedRoleplay,
           let postHistoryPrompt = RoleplayRuntime.postHistoryPrompt(resolvedRoleplay) {
            messagesToSend.append(ChatMessage(role: .system, content: postHistoryPrompt))
        }

        if let enhancedPromptMessage = makeEnhancedPromptSystemMessage(enhancedPrompt) {
            messagesToSend.append(enhancedPromptMessage)
        }

        if includeSystemTime && systemTimeInjectionPosition == .tail {
            messagesToSend.append(makeTailSystemTimeMessage(apiFormat: runnableModel.provider.apiFormat))
        }

        messagesToSend = await RoleplayPromptTemplateRenderer.renderMessages(
            messagesToSend,
            worldbooks: boundWorldbooks,
            chatHistory: requestMessages,
            regexRules: resolvedRoleplay?.regexRules ?? [],
            macroContext: &promptTemplateMacroContext
        )
        let storedPromptTemplateVariables = roleplayStore.variableSnapshot(sessionID: currentSessionID)
        if promptTemplateMacroContext.variables != storedPromptTemplateVariables {
            roleplayStore.saveVariableSnapshot(
                promptTemplateMacroContext.variables,
                sessionID: currentSessionID
            )
        }
        let worldbookOutlets = makeWorldbookOutletValues(entries: worldbookResult.outlet)
        for index in messagesToSend.indices {
            messagesToSend[index].content = RoleplayMacroResolver.resolveWorldbookOutlets(
                messagesToSend[index].content,
                outlets: worldbookOutlets
            )
        }

        // 续聊上下文是已持久化的固定交接，不参与角色模板、正则和宏替换。
        // 将它放在首个系统提示词之后，也确保 maxChatHistory 永远不会裁掉这段上下文。
        if !continuationMessages.isEmpty {
            let insertionIndex = messagesToSend.first?.role == .system ? 1 : 0
            messagesToSend.insert(contentsOf: continuationMessages, at: insertionIndex)
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

        if !helperScriptIDs.isEmpty {
            if continuationMessages.isEmpty {
                messagesToSend = await RoleplayPromptMutationBridge.shared.mutate(
                    messagesToSend,
                    sessionID: currentSessionID,
                    scriptIDs: helperScriptIDs
                )
            } else {
                let protectedMessageIDs = Set(continuationMessages.map(\.id))
                let firstProtectedIndex = messagesToSend.firstIndex {
                    protectedMessageIDs.contains($0.id)
                }
                let lastProtectedIndex = messagesToSend.lastIndex {
                    protectedMessageIDs.contains($0.id)
                }
                if let firstProtectedIndex, let lastProtectedIndex {
                    let prefixSource = Array(messagesToSend[..<firstProtectedIndex])
                    let prefix = prefixSource.isEmpty
                        ? []
                        : await RoleplayPromptMutationBridge.shared.mutate(
                            prefixSource,
                            sessionID: currentSessionID,
                            scriptIDs: helperScriptIDs
                        )
                    let protectedMessages = Array(messagesToSend[firstProtectedIndex...lastProtectedIndex])
                    let suffixStartIndex = messagesToSend.index(after: lastProtectedIndex)
                    let suffixSource = Array(messagesToSend[suffixStartIndex...])
                    let suffix = suffixSource.isEmpty
                        ? []
                        : await RoleplayPromptMutationBridge.shared.mutate(
                            suffixSource,
                            sessionID: currentSessionID,
                            scriptIDs: helperScriptIDs
                        )
                    messagesToSend = prefix + protectedMessages + suffix
                }
            }
        }

        if LocalModelProviderBridge.isLocalRunnableModel(runnableModel) {
            persistSentSystemPromptSnapshot(
                from: messagesToSend,
                loadingMessageID: loadingMessageID,
                sessionID: currentSessionID
            )
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
                requestLogContext: requestLogContext,
                availableTools: nil,
                imageAttachments: imageAttachments
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
        var commonPayload: [String: Any] = ["stream": effectiveStreaming]
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

        persistSentSystemPromptSnapshot(
            from: messagesToSend,
            loadingMessageID: loadingMessageID,
            sessionID: currentSessionID
        )

        let responsesFullInputFallbackRequest: URLRequest? = {
            guard openAIResponsesRequestUsesPreviousResponseID(request) else { return nil }
            var fallbackPayload = commonPayload
            fallbackPayload[OpenAIAdapter.responsesForceFullInputControlKey] = true
            return adapter.buildChatRequest(
                for: runnableModel,
                commonPayload: fallbackPayload,
                messages: messagesToSend,
                tools: effectiveTools,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
        }()

        if effectiveStreaming {
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
                requestLogContext: requestLogContext,
                responsesFullInputFallbackRequest: responsesFullInputFallbackRequest
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
                requestLogContext: requestLogContext,
                messagesBeforeResponse: messagesToSend,
                responsesFullInputFallbackRequest: responsesFullInputFallbackRequest
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
            var fileBlocks: [(fileName: String, text: String)] = []
            for attachment in attachments {
                do {
                    let text = try fileAttachmentTextExtractor.extractText(from: attachment)
                    fileBlocks.append((fileName: attachment.fileName, text: text))
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

    private func makeFileAttachmentAppendixText(_ blocks: [(fileName: String, text: String)]) -> String {
        let joinedBlocks = blocks.map { block in
            """
            <file name="\(xmlEscapedAttribute(block.fileName))">
            \(block.text)
            </file>
            """
        }.joined(separator: "\n\n")
        return BuiltInPromptStore.render(
            .fileAttachmentAppendix,
            variables: ["attachments": joinedBlocks]
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
            var ocrBlocks: [(fileName: String, text: String)] = []
            for attachment in attachments {
                do {
                    let text = try await recognizeImageText(
                        attachment,
                        using: ocrModel,
                        sessionID: sessionID
                    )
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    ocrBlocks.append((fileName: attachment.fileName, text: trimmed))
                } catch {
                    logger.error("图片 OCR 失败: \(error.localizedDescription)")
                    let fallback = String(
                        format: NSLocalizedString("OCR 失败：%@", comment: "OCR failed image block content"),
                        error.localizedDescription
                    )
                    ocrBlocks.append((fileName: attachment.fileName, text: fallback))
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

    private func makeOCRAppendixText(_ blocks: [(fileName: String, text: String)]) -> String {
        let joinedBlocks = blocks.map { block in
            """
            <image name="\(xmlEscapedAttribute(block.fileName))">
            \(block.text)
            </image>
            """
        }.joined(separator: "\n\n")
        return BuiltInPromptStore.render(
            .imageOCRAppendix,
            variables: ["attachments": joinedBlocks]
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

        let prompt = BuiltInPromptStore.render(.remoteOCR)
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
