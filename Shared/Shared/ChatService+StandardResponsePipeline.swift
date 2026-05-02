// ============================================================================
// ChatService+StandardResponsePipeline.swift
// ============================================================================
// ChatService 的非流式响应处理、后台转写与工具调用后续消息流水线。
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

    func streamData(for request: URLRequest, provider: Provider?) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await requestBytes(for: request, provider: provider)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            var capturedBody: Data?
            var buffer = Data()
            let limit = 64 * 1024
            do {
                for try await byte in bytes {
                    if buffer.count < limit {
                        buffer.append(byte)
                    }
                }
                if !buffer.isEmpty {
                    capturedBody = buffer
                }
            } catch {
                logger.error("  - 读取流式错误响应体失败: \(error.localizedDescription)")
            }
            if let capturedBody, let prettyBody = String(data: capturedBody, encoding: .utf8) {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体:\n---\n\(prettyBody)\n---")
            } else if let capturedBody, !capturedBody.isEmpty {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体包含 \(capturedBody.count) 字节的二进制数据。")
            } else {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体为空。")
            }
            logHTTPErrorBody(
                request: request,
                provider: provider,
                statusCode: statusCode,
                bodyData: capturedBody,
                transport: "stream"
            )
            throw NetworkError.badStatusCode(code: statusCode, responseBody: capturedBody)
        }
        return bytes
    }
    
    func handleBackgroundTranscription(audioAttachment: AudioAttachment, placeholder: String, messageID: UUID, sessionID: UUID) async {
        guard let speechModel = resolveSelectedSpeechModel() else {
            // 当开启直接发送音频给模型时，后台转文字是可选的增强功能
            // 没有配置语音模型时只记录日志，不显示错误打扰用户
            logger.info(" 后台语音转文字跳过: 未配置语音模型。消息将保持为 [语音消息] 显示。")
            return
        }
        
        logger.info("(后台) 正在使用 \(speechModel.model.displayName) 进行语音转文字...")
        
        do {
            let rawTranscript = try await transcribeAudio(
                using: speechModel,
                audioData: audioAttachment.data,
                fileName: audioAttachment.fileName,
                mimeType: audioAttachment.mimeType
            )
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !transcript.isEmpty else {
                // 转写结果为空时静默处理，不显示错误
                logger.warning("后台语音转文字返回空结果，消息将保持为 [语音消息] 显示。")
                return
            }
            
            await MainActor.run {
                self.applyTranscriptionResult(
                    transcript,
                    toMessageWithID: messageID,
                    in: sessionID,
                    placeholder: placeholder
                )
            }
        } catch {
            // 后台转文字失败时静默处理，不显示错误打扰用户
            // 因为音频已经成功发送给模型了，转文字只是可选的UI增强
            logger.warning("后台语音转文字失败: \(error.localizedDescription)。消息将保持为 [语音消息] 显示。")
        }
    }
    
    @MainActor
    func applyTranscriptionResult(_ transcript: String, toMessageWithID messageID: UUID, in sessionID: UUID, placeholder: String) {
        var messages: [ChatMessage]
        let isCurrentSession = currentSessionSubject.value?.id == sessionID
        
        if isCurrentSession {
            messages = messagesForSessionSubject.value
        } else {
            messages = Persistence.loadMessages(for: sessionID)
        }
        
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            logger.warning("未找到需要更新的语音消息（可能会话已被切换或删除）。")
            return
        }
        
        messages[index].content = transcript
        
        if isCurrentSession {
            publishMessages(messages)
        }
        persistMessages(messages, for: sessionID)
        
        // 如果是新建的会话且名称仍为占位符，则同步更新会话名称
        if isCurrentSession, var currentSession = currentSessionSubject.value, currentSession.name == placeholder {
            currentSession.name = String(transcript.prefix(20))
            currentSessionSubject.send(currentSession)
            var sessions = chatSessionsSubject.value
            if let sessionIndex = sessions.firstIndex(where: { $0.id == currentSession.id }) {
                sessions[sessionIndex] = currentSession
                chatSessionsSubject.send(sessions)
                Persistence.saveChatSessions(sessions)
            }
        } else {
            var sessions = chatSessionsSubject.value
            if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
                if sessions[sessionIndex].name == placeholder {
                    sessions[sessionIndex].name = String(transcript.prefix(20))
                    chatSessionsSubject.send(sessions)
                    Persistence.saveChatSessions(sessions)
                }
            }
        }
    }
    
    func handleStandardResponse(
        request: URLRequest,
        provider: Provider,
        adapter: APIAdapter,
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
        availableTools: [InternalToolDefinition]?,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition,
        enablePeriodicTimeLandmark: Bool,
        periodicTimeLandmarkIntervalMinutes: Int,
        enableResponseSpeedMetrics: Bool,
        requestStartedAt: Date,
        requestLogContext: RequestLogContext
    ) async {
        do {
            let data = try await fetchData(for: request, provider: provider)
            let rawResponse = String(data: data, encoding: .utf8) ?? NSLocalizedString("<二进制数据，无法以 UTF-8 解码>", comment: "Fallback for non-UTF8 response body")
            logger.log("[Log] 收到 AI 原始响应体:\n---\n\(rawResponse)\n---")
            
            do {
                var parsedMessage = try adapter.parseResponse(data: data)
                let responseCompletedAt = Date()
                let totalDuration = max(0, responseCompletedAt.timeIntervalSince(requestStartedAt))
                if enableResponseSpeedMetrics {
                    let completionTokens = parsedMessage.tokenUsage?.completionTokens
                    parsedMessage.responseMetrics = makeResponseMetrics(
                        requestStartedAt: requestStartedAt,
                        responseCompletedAt: responseCompletedAt,
                        totalResponseDuration: totalDuration,
                        timeToFirstToken: nil,
                        completionTokensForSpeed: completionTokens,
                        tokenPerSecond: tokenPerSecond(tokens: completionTokens, elapsed: totalDuration),
                        isEstimated: false
                    )
                }
                if !(parsedMessage.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ensureReasoningTimingIfNeeded(
                        for: &parsedMessage,
                        fallbackRequestStartedAt: requestStartedAt,
                        fallbackCompletedAt: responseCompletedAt
                    )
                }
                persistRequestLog(
                    context: requestLogContext,
                    status: .success,
                    tokenUsage: parsedMessage.tokenUsage,
                    finishedAt: Date()
                )
                await processResponseMessage(
                    responseMessage: parsedMessage,
                    loadingMessageID: loadingMessageID,
                    currentSessionID: currentSessionID,
                    userMessage: userMessage,
                    wasTemporarySession: wasTemporarySession,
                    availableTools: availableTools,
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
                    periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes
                )
            } catch is CancellationError {
                logger.info("请求在解析阶段被取消，已忽略后续处理。")
                persistRequestLog(
                    context: requestLogContext,
                    status: .cancelled,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "cancelled"
                )
            } catch {
                logger.error("解析响应失败: \(error.localizedDescription)")
                addErrorMessage(String(
                    format: NSLocalizedString("解析响应失败，请查看原始响应:\n%@", comment: "Response parse failed with raw response"),
                    rawResponse
                ), sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .failed,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "parse_response_failed"
                )
            }
        } catch is CancellationError {
            logger.info("请求在拉取数据时被取消。")
            persistRequestLog(
                context: requestLogContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            let bodyString: String
            if let bodyData, let utf8Text = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !utf8Text.isEmpty {
                bodyString = utf8Text
            } else if let bodyData, !bodyData.isEmpty {
                bodyString = String(
                    format: NSLocalizedString("响应体包含 %d 字节，无法以 UTF-8 解码。", comment: "Response body not UTF-8 with byte count"),
                    bodyData.count
                )
            } else {
                bodyString = NSLocalizedString("响应体为空。", comment: "Empty response body")
            }
            addErrorMessage(bodyString, sessionID: currentSessionID, httpStatusCode: code)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
        } catch {
            // 检测是否为取消错误（URLError.cancelled 不会匹配 CancellationError）
            if isCancellationError(error) {
                logger.info("请求在拉取数据时被取消 (URLError)。")
                persistRequestLog(
                    context: requestLogContext,
                    status: .cancelled,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "cancelled"
                )
            } else {
                addErrorMessage(String(
                    format: NSLocalizedString("网络错误: %@", comment: "Network error with description"),
                    error.localizedDescription
                ), sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .failed,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "network_error"
                )
            }
        }
    }
    
    /// 处理已解析的聊天消息，包含所有工具调用和UI更新的核心逻辑 (可测试)
    internal func processResponseMessage(responseMessage: ChatMessage, loadingMessageID: UUID, currentSessionID: UUID, userMessage: ChatMessage?, wasTemporarySession: Bool, availableTools: [InternalToolDefinition]?, aiTemperature: Double, aiTopP: Double, systemPrompt: String, maxChatHistory: Int, enableMemory: Bool, enableMemoryWrite: Bool, enableMemoryActiveRetrieval: Bool = false, includeSystemTime: Bool, systemTimeInjectionPosition: SystemTimeInjectionPosition = .front, enablePeriodicTimeLandmark: Bool = false, periodicTimeLandmarkIntervalMinutes: Int = 30) async {
        var responseMessage = responseMessage // Make mutable
        if let reasoning = responseMessage.reasoningContent {
            let normalized = normalizeEscapedNewlinesIfNeeded(reasoning)
            responseMessage.reasoningContent = normalized.isEmpty ? nil : normalized
        }

        // BUGFIX: 无论是否存在工具调用，都应首先解析并提取思考过程。
        let (finalContent, extractedReasoning) = parseThoughtTags(from: responseMessage.content)
        responseMessage.content = finalContent
        if !extractedReasoning.isEmpty {
            let normalizedExtracted = normalizeEscapedNewlinesIfNeeded(extractedReasoning)
            if !normalizedExtracted.isEmpty {
                if let existing = responseMessage.reasoningContent, !existing.isEmpty {
                    responseMessage.reasoningContent = existing + "\n" + normalizedExtracted
                } else {
                    responseMessage.reasoningContent = normalizedExtracted
                }
            }
        }
        ensureReasoningTimingIfNeeded(for: &responseMessage)

        let inlineImageExtraction = await extractInlineImagesFromMarkdown(responseMessage.content)
        if !inlineImageExtraction.imageFileNames.isEmpty {
            responseMessage.content = inlineImageExtraction.cleanedContent
            responseMessage.imageFileNames = (responseMessage.imageFileNames ?? []) + inlineImageExtraction.imageFileNames
        }

        scheduleAssistantReplyAchievementDetectionIfNeeded(responseMessage.content)

        if let toolCalls = responseMessage.toolCalls {
            let resolvedCalls = resolveToolCalls(toolCalls, availableTools: availableTools ?? [])
            let filteredCalls = resolvedCalls.filter { !sanitizedToolName($0.toolName).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if filteredCalls.count != resolvedCalls.count {
                logger.warning("检测到工具调用缺少有效名称，已忽略无效项。")
            }
            responseMessage.toolCalls = filteredCalls.isEmpty ? nil : filteredCalls
        }
        if responseMessage.toolCalls != nil, responseMessage.toolCallsPlacement == nil {
            responseMessage.toolCallsPlacement = inferredToolCallsPlacement(from: responseMessage.content)
        }
        // 保持 assistant 角色不变：工具调用消息仍应作为 assistant 消息发送给模型。

        // --- 检查是否存在工具调用 ---
        guard let toolCalls = responseMessage.toolCalls, !toolCalls.isEmpty else {
            // --- 无工具调用，标准流程 ---
            updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
            scheduleReasoningSummaryIfNeeded(for: loadingMessageID, in: currentSessionID)
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            // 标题已在用户发送消息时异步生成，无需等待AI响应
            return
        }

        // --- 有工具调用，进入 Agent 逻辑 ---

        // 1. 将当前 assistant 消息更新为“工具调用”气泡
        updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
        scheduleReasoningSummaryIfNeeded(for: loadingMessageID, in: currentSessionID)
        let toolCallMessageID = loadingMessageID
        ensureToolCallsVisible(toolCalls, in: toolCallMessageID, sessionID: currentSessionID)
        let activeAttemptMetadata = responseAttemptMetadata(for: toolCallMessageID, in: currentSessionID)
            ?? responseAttemptMetadata(from: responseMessage)

        // 2. 根据 isBlocking 标志将工具调用分类
        let toolDefs = availableTools ?? []
        if toolDefs.isEmpty {
            logger.info("当前未提供任何工具定义，忽略 AI 返回的 \(toolCalls.count) 个工具调用。")
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            // 标题已在用户发送消息时异步生成，无需等待AI响应
            return
        }
        let blockingCalls = toolCalls.filter { tc in
            toolDefs.first { $0.name == tc.toolName }?.isBlocking == true
        }
        let nonBlockingCalls = toolCalls.filter { tc in
            toolDefs.first { $0.name == tc.toolName }?.isBlocking != true // 默认视为非阻塞
        }

        // 3. 判断 AI 是否已经给出正文，如果正文为空，需要准备走二次调用
        let hasAssistantContent = !responseMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 4. 收集需要同步等待结果的工具调用
        var blockingResultMessages: [ChatMessage] = []
        var shouldAwaitUserSupplement = false
        if !blockingCalls.isEmpty {
            logger.info("正在执行 \(blockingCalls.count) 个阻塞式工具，即将进入二次调用流程...")
            for toolCall in blockingCalls {
                let outcome = await handleToolCall(toolCall)
                if let toolResult = outcome.toolResult {
                    await attachToolResult(toolResult, to: toolCall.id, toolName: toolCall.toolName, loadingMessageID: toolCallMessageID, sessionID: currentSessionID)
                }
                var outcomeMessage = outcome.message
                applyResponseAttemptMetadata(activeAttemptMetadata, to: &outcomeMessage)
                blockingResultMessages.append(outcomeMessage)
                if outcome.shouldAwaitUserSupplement {
                    shouldAwaitUserSupplement = true
                    break
                }
            }
        }

        if shouldAwaitUserSupplement {
            var updatedMessages = self.messagesSnapshot(for: currentSessionID)
            updatedMessages = insertingResponseAttemptMessages(
                blockingResultMessages,
                afterAttemptOf: toolCallMessageID,
                in: updatedMessages
            )
            self.persistAndPublishMessages(updatedMessages, for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            return
        }

        var nonBlockingResultsForFollowUp: [ChatMessage] = []
        if !nonBlockingCalls.isEmpty {
            if hasAssistantContent {
                // 仅当 AI 已经给出正文时，才异步执行非阻塞式工具，避免阻塞 UI
                logger.info("在后台启动 \(nonBlockingCalls.count) 个非阻塞式工具...")
                Task {
                    for toolCall in nonBlockingCalls {
                        let outcome = await handleToolCall(toolCall)
                        if let toolResult = outcome.toolResult {
                            await attachToolResult(toolResult, to: toolCall.id, toolName: toolCall.toolName, loadingMessageID: toolCallMessageID, sessionID: currentSessionID)
                        }
                        // 非阻塞工具也写入消息列表，便于 UI 直接展示结果
                        var outcomeMessage = outcome.message
                        self.applyResponseAttemptMetadata(activeAttemptMetadata, to: &outcomeMessage)
                        var messages = self.messagesSnapshot(for: currentSessionID)
                        messages = self.insertingResponseAttemptMessages(
                            [outcomeMessage],
                            afterAttemptOf: toolCallMessageID,
                            in: messages
                        )
                        self.persistAndPublishMessages(messages, for: currentSessionID)
                        logger.info("  - 非阻塞式工具 '\(toolCall.toolName)' 已在后台执行完毕并保存了结果。")
                    }
                }
            } else {
                // 没有正文时需要等待工具结果，再次回传给 AI 生成最终回答
                logger.info("非阻塞式工具返回但没有正文，将等待工具执行结果再发起二次调用。")
                for toolCall in nonBlockingCalls {
                    let outcome = await handleToolCall(toolCall)
                    if let toolResult = outcome.toolResult {
                        await attachToolResult(toolResult, to: toolCall.id, toolName: toolCall.toolName, loadingMessageID: toolCallMessageID, sessionID: currentSessionID)
                    }
                    var outcomeMessage = outcome.message
                    applyResponseAttemptMetadata(activeAttemptMetadata, to: &outcomeMessage)
                    nonBlockingResultsForFollowUp.append(outcomeMessage)
                    if outcome.shouldAwaitUserSupplement {
                        shouldAwaitUserSupplement = true
                        break
                    }
                }
            }
        }

        if shouldAwaitUserSupplement {
            var updatedMessages = self.messagesSnapshot(for: currentSessionID)
            updatedMessages = insertingResponseAttemptMessages(
                blockingResultMessages + nonBlockingResultsForFollowUp,
                afterAttemptOf: toolCallMessageID,
                in: updatedMessages
            )
            self.persistAndPublishMessages(updatedMessages, for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            return
        }

        let shouldTriggerFollowUp = !blockingResultMessages.isEmpty || !nonBlockingResultsForFollowUp.isEmpty

        if shouldTriggerFollowUp {
            var updatedMessages = self.messagesSnapshot(for: currentSessionID)

            // 新增一个独立的 loading assistant 气泡，用于最终回复
            var followUpLoadingMessage = ChatMessage(
                role: .assistant,
                content: "",
                requestedAt: Date()
            )
            applyResponseAttemptMetadata(activeAttemptMetadata, to: &followUpLoadingMessage)
            updatedMessages = insertingResponseAttemptMessages(
                blockingResultMessages + nonBlockingResultsForFollowUp + [followUpLoadingMessage],
                afterAttemptOf: toolCallMessageID,
                in: updatedMessages
            )
            self.persistAndPublishMessages(updatedMessages, for: currentSessionID)
            updateRequestLoadingMessageID(followUpLoadingMessage.id, for: currentSessionID)

            logger.info("正在将工具结果发回 AI 以生成最终回复...")
            await executeMessageRequest(
                messages: updatedMessages, loadingMessageID: followUpLoadingMessage.id, currentSessionID: currentSessionID,
                userMessage: userMessage, wasTemporarySession: wasTemporarySession, aiTemperature: aiTemperature,
                aiTopP: aiTopP, systemPrompt: systemPrompt, maxChatHistory: maxChatHistory,
                enableStreaming: false, enhancedPrompt: nil, tools: availableTools, enableMemory: enableMemory, enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: false,
                currentAudioAttachment: nil,
                currentFileAttachments: []
            )
        } else {
            // 5. 如果只有非阻塞式工具并且 AI 已经给出正文，则在这里结束请求
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            // 标题已在用户发送消息时异步生成，无需等待AI响应
        }
    }
}
