// ============================================================================
// ChatServiceResponsePipeline.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的流式响应接收、已解析消息收敛与工具调用编排。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    func handleStreamedResponse(
        request: URLRequest,
        provider: Provider,
        adapter: APIAdapter,
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        availableTools: [InternalToolDefinition]?,
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
        var latestTokenUsage: MessageTokenUsage?
        do {
            let bytes = try await streamData(for: request, provider: provider)

            var toolCallBuilders: [Int: (id: String?, name: String?, arguments: String, providerSpecificFields: [String: JSONValue]?)] = [:]
            var toolCallOrder: [Int] = []
            var toolCallIndexByID: [String: Int] = [:]
            var latestOfficialCompletionTokens: Int?
            var accumulatedOutputText = ""
            var firstTokenAt: Date?
            var lastStreamPartReceivedAt: Date?
            var lastGeneratedDeltaAt: Date?
            var reasoningStartedAt: Date?
            var reasoningLastDeltaAt: Date?
            var reasoningCompletedAt: Date?
            var receivedDedicatedReasoning = false
            var isInsideInlineReasoning = false
            var inlineReasoningMayStartAtContentStart = true
            var inlineReasoningDetectionTail = ""
            var speedSamples: [MessageResponseMetrics.SpeedSample] = []
            var messages = messagesSnapshot(for: currentSessionID)
            var finalResponseCompletedAtForLog: Date?

            for try await line in bytes.lines {
                guard let part = adapter.parseStreamingResponse(line: line) else { continue }
                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    let partReceivedAt = Date()
                    lastStreamPartReceivedAt = partReceivedAt
                    if let usage = part.tokenUsage {
                        let mergedUsage = mergeTokenUsage(existing: latestTokenUsage, incoming: usage)
                        latestTokenUsage = mergedUsage
                        messages[index].tokenUsage = mergedUsage
                        if let completionTokens = mergedUsage.completionTokens, completionTokens > 0 {
                            latestOfficialCompletionTokens = completionTokens
                        }
                    }
                    var didReceiveTextDelta = false
                    var didReceiveGeneratedDelta = false
                    if let contentPart = part.content {
                        messages[index].content += contentPart
                        if !contentPart.isEmpty {
                            accumulatedOutputText += contentPart
                            didReceiveTextDelta = true
                            didReceiveGeneratedDelta = true
                            updateReasoningTimingFromInlineThoughtTags(
                                in: contentPart,
                                receivedAt: partReceivedAt,
                                reasoningStartedAt: &reasoningStartedAt,
                                reasoningLastDeltaAt: &reasoningLastDeltaAt,
                                reasoningCompletedAt: &reasoningCompletedAt,
                                isInsideInlineReasoning: &isInsideInlineReasoning,
                                mayStartAtContentStart: &inlineReasoningMayStartAtContentStart,
                                detectionTail: &inlineReasoningDetectionTail
                            )
                            if receivedDedicatedReasoning && reasoningCompletedAt == nil {
                                reasoningCompletedAt = reasoningLastDeltaAt
                            }
                        }
                        if messages[index].role == .tool {
                            let trimmedContent = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmedContent.isEmpty {
                                messages[index].role = .assistant
                            }
                        }
                    }
                    if let reasoningPart = part.reasoningContent {
                        if messages[index].reasoningContent == nil { messages[index].reasoningContent = "" }
                        messages[index].reasoningContent! += reasoningPart
                        if !reasoningPart.isEmpty {
                            accumulatedOutputText += reasoningPart
                            didReceiveTextDelta = true
                            didReceiveGeneratedDelta = true
                            receivedDedicatedReasoning = true
                            if reasoningStartedAt == nil {
                                reasoningStartedAt = partReceivedAt
                            }
                            reasoningLastDeltaAt = partReceivedAt
                            reasoningCompletedAt = nil
                        }
                        if messages[index].role == .tool {
                            let trimmedReasoning = messages[index].reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !trimmedReasoning.isEmpty {
                                messages[index].role = .assistant
                            }
                        }
                    }
                    if let reasoningProviderSpecificFields = part.reasoningProviderSpecificFields {
                        messages[index].reasoningProviderSpecificFields = mergeReasoningProviderSpecificFields(
                            existing: messages[index].reasoningProviderSpecificFields,
                            incoming: reasoningProviderSpecificFields
                        )
                    }
                    if let toolDeltas = part.toolCallDeltas, !toolDeltas.isEmpty {
                        didReceiveGeneratedDelta = true
                        for delta in toolDeltas {
                            let resolvedIndex: Int
                            if let id = delta.id, let existed = toolCallIndexByID[id] {
                                resolvedIndex = existed
                            } else if let explicitIndex = delta.index {
                                resolvedIndex = explicitIndex
                                if let id = delta.id {
                                    toolCallIndexByID[id] = explicitIndex
                                }
                            } else {
                                resolvedIndex = (toolCallOrder.last ?? -1) + 1
                                if let id = delta.id {
                                    toolCallIndexByID[id] = resolvedIndex
                                }
                            }
                            var builder = toolCallBuilders[resolvedIndex] ?? (id: nil, name: nil, arguments: "", providerSpecificFields: nil)
                            if let id = delta.id { builder.id = id }
                            if let nameFragment = delta.nameFragment, !nameFragment.isEmpty { builder.name = nameFragment }
                            if let argsFragment = delta.argumentsFragment, !argsFragment.isEmpty { builder.arguments += argsFragment }
                            if let providerSpecificFields = delta.providerSpecificFields, !providerSpecificFields.isEmpty {
                                builder.providerSpecificFields = providerSpecificFields
                            }
                            toolCallBuilders[resolvedIndex] = builder
                            if !toolCallOrder.contains(resolvedIndex) {
                                toolCallOrder.append(resolvedIndex)
                            }
                        }
                        let partialToolCalls: [InternalToolCall] = toolCallOrder.compactMap { orderIdx in
                            guard let builder = toolCallBuilders[orderIdx], let name = builder.name else { return nil }
                            let id = builder.id ?? "tool-\(orderIdx)"
                            let resolvedName = resolveToolName(name, availableTools: availableTools ?? [])
                            return InternalToolCall(
                                id: id,
                                toolName: resolvedName,
                                arguments: builder.arguments,
                                providerSpecificFields: builder.providerSpecificFields
                            )
                        }
                        if !partialToolCalls.isEmpty {
                            if messages[index].toolCallsPlacement == nil {
                                messages[index].toolCallsPlacement = inferredToolCallsPlacement(from: messages[index].content)
                            }
                            messages[index].toolCalls = partialToolCalls
                            if receivedDedicatedReasoning && reasoningCompletedAt == nil {
                                reasoningCompletedAt = reasoningLastDeltaAt
                            }
                        }
                    }
                    if didReceiveGeneratedDelta {
                        lastGeneratedDeltaAt = partReceivedAt
                    }
                    if enableResponseSpeedMetrics || reasoningStartedAt != nil {
                        if didReceiveTextDelta, firstTokenAt == nil {
                            firstTokenAt = partReceivedAt
                        }
                        let metricsSnapshotAt = lastGeneratedDeltaAt ?? partReceivedAt
                        let estimatedTokens = estimatedCompletionTokens(from: accumulatedOutputText)
                        let completionTokensForSpeed = latestOfficialCompletionTokens ?? (estimatedTokens > 0 ? estimatedTokens : nil)
                        let speed: Double?
                        if enableResponseSpeedMetrics {
                            speed = streamingTokenPerSecond(
                                tokens: completionTokensForSpeed,
                                requestStartedAt: requestStartedAt,
                                firstTokenAt: firstTokenAt,
                                snapshotAt: metricsSnapshotAt
                            )
                            appendSpeedSample(
                                to: &speedSamples,
                                elapsed: max(0, metricsSnapshotAt.timeIntervalSince(requestStartedAt)),
                                speed: speed
                            )
                        } else {
                            speed = nil
                        }
                        messages[index].responseMetrics = makeResponseMetrics(
                            requestStartedAt: requestStartedAt,
                            responseCompletedAt: nil,
                            totalResponseDuration: nil,
                            timeToFirstToken: enableResponseSpeedMetrics ? firstTokenAt.map { max(0, $0.timeIntervalSince(requestStartedAt)) } : nil,
                            reasoningStartedAt: reasoningStartedAt,
                            reasoningCompletedAt: reasoningCompletedAt,
                            completionTokensForSpeed: enableResponseSpeedMetrics ? completionTokensForSpeed : nil,
                            tokenPerSecond: speed,
                            isEstimated: enableResponseSpeedMetrics && latestOfficialCompletionTokens == nil && completionTokensForSpeed != nil,
                            speedSamples: enableResponseSpeedMetrics && !speedSamples.isEmpty ? speedSamples : nil
                        )
                    }
                    publishMessagesIfCurrentSession(messages, for: currentSessionID, keepingSpeedSamplesFor: loadingMessageID)
                }
            }

            var finalAssistantMessage: ChatMessage?
            if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                let (finalContent, extractedReasoning) = parseThoughtTags(from: messages[index].content)
                messages[index].content = finalContent
                if !extractedReasoning.isEmpty {
                    if messages[index].reasoningContent == nil { messages[index].reasoningContent = "" }
                    messages[index].reasoningContent! += "\n" + extractedReasoning
                }
                if messages[index].toolCalls == nil && !toolCallOrder.isEmpty {
                    let finalToolCalls: [InternalToolCall] = toolCallOrder.compactMap { orderIdx in
                        guard let builder = toolCallBuilders[orderIdx], let name = builder.name else {
                            logger.error("流式响应中检测到未完成的工具调用 (index: \(orderIdx))，缺少名称。")
                            return nil
                        }
                        let id = builder.id ?? "tool-\(orderIdx)"
                        let resolvedName = resolveToolName(name, availableTools: availableTools ?? [])
                        return InternalToolCall(
                            id: id,
                            toolName: resolvedName,
                            arguments: builder.arguments,
                            providerSpecificFields: builder.providerSpecificFields
                        )
                    }
                    if !finalToolCalls.isEmpty {
                        if messages[index].toolCallsPlacement == nil {
                            messages[index].toolCallsPlacement = inferredToolCallsPlacement(from: messages[index].content)
                        }
                        messages[index].toolCalls = finalToolCalls
                    }
                }
                if let latestTokenUsage {
                    messages[index].tokenUsage = latestTokenUsage
                    if let completionTokens = latestTokenUsage.completionTokens, completionTokens > 0 {
                        latestOfficialCompletionTokens = completionTokens
                    }
                }
                let responseCompletedAt = effectiveStreamResponseCompletedAt(
                    lastGeneratedDeltaAt: lastGeneratedDeltaAt,
                    lastStreamPartReceivedAt: lastStreamPartReceivedAt,
                    fallbackCompletedAt: Date()
                )
                finalResponseCompletedAtForLog = responseCompletedAt
                if reasoningStartedAt == nil,
                   !extractedReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reasoningStartedAt = requestStartedAt
                    reasoningLastDeltaAt = lastGeneratedDeltaAt ?? responseCompletedAt
                    reasoningCompletedAt = responseCompletedAt
                }
                if reasoningStartedAt != nil && reasoningCompletedAt == nil {
                    reasoningCompletedAt = reasoningLastDeltaAt ?? responseCompletedAt
                }
                if enableResponseSpeedMetrics || reasoningStartedAt != nil {
                    let totalDuration = max(0, responseCompletedAt.timeIntervalSince(requestStartedAt))
                    let estimatedTokens = estimatedCompletionTokens(from: accumulatedOutputText)
                    let completionTokensForSpeed = latestOfficialCompletionTokens ?? (estimatedTokens > 0 ? estimatedTokens : nil)
                    let finalSpeed: Double?
                    if enableResponseSpeedMetrics {
                        finalSpeed = streamingTokenPerSecond(
                            tokens: completionTokensForSpeed,
                            requestStartedAt: requestStartedAt,
                            firstTokenAt: firstTokenAt,
                            snapshotAt: responseCompletedAt
                        )
                        appendSpeedSample(
                            to: &speedSamples,
                            elapsed: totalDuration,
                            speed: finalSpeed
                        )
                    } else {
                        finalSpeed = nil
                    }
                    messages[index].responseMetrics = makeResponseMetrics(
                        requestStartedAt: requestStartedAt,
                        responseCompletedAt: enableResponseSpeedMetrics ? responseCompletedAt : nil,
                        totalResponseDuration: enableResponseSpeedMetrics ? totalDuration : nil,
                        timeToFirstToken: enableResponseSpeedMetrics ? firstTokenAt.map { max(0, $0.timeIntervalSince(requestStartedAt)) } : nil,
                        reasoningStartedAt: reasoningStartedAt,
                        reasoningCompletedAt: reasoningCompletedAt,
                        completionTokensForSpeed: enableResponseSpeedMetrics ? completionTokensForSpeed : nil,
                        tokenPerSecond: finalSpeed,
                        isEstimated: enableResponseSpeedMetrics && latestOfficialCompletionTokens == nil && completionTokensForSpeed != nil,
                        speedSamples: enableResponseSpeedMetrics && !speedSamples.isEmpty ? speedSamples : nil
                    )
                }
                finalAssistantMessage = messages[index]
                persistAndPublishMessages(messages, for: currentSessionID, keepingSpeedSamplesFor: loadingMessageID)
            }

            if let finalAssistantMessage = finalAssistantMessage {
                let finishedAt = finalResponseCompletedAtForLog ?? finalAssistantMessage.responseMetrics?.responseCompletedAt ?? Date()
                persistRequestLog(
                    context: requestLogContext,
                    status: .success,
                    tokenUsage: finalAssistantMessage.tokenUsage,
                    finishedAt: finishedAt
                )
                await processResponseMessage(
                    responseMessage: finalAssistantMessage,
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
            } else {
                persistRequestLog(
                    context: requestLogContext,
                    status: .success,
                    tokenUsage: nil,
                    finishedAt: Date()
                )
                emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            }
        } catch is CancellationError {
            logger.info("流式请求在处理中被取消。")
            finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingMessageID, in: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .cancelled,
                tokenUsage: latestTokenUsage,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            let bodySnippet: String
            if let bodyData, let text = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                bodySnippet = text
            } else if let bodyData, !bodyData.isEmpty {
                bodySnippet = String(
                    format: NSLocalizedString("响应体包含 %d 字节，无法以 UTF-8 解码。", comment: "Response body not UTF-8 with byte count"),
                    bodyData.count
                )
            } else {
                bodySnippet = NSLocalizedString("响应体为空。", comment: "Empty response body")
            }
            addErrorMessage(bodySnippet, sessionID: currentSessionID, httpStatusCode: code)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: latestTokenUsage,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
        } catch {
            if isCancellationError(error) {
                logger.info("流式请求在处理中被取消 (URLError)。")
                finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingMessageID, in: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .cancelled,
                    tokenUsage: latestTokenUsage,
                    finishedAt: Date(),
                    errorKind: "cancelled"
                )
            } else {
                addErrorMessage(String(
                    format: NSLocalizedString("流式传输错误: %@", comment: "Streaming error with description"),
                    error.localizedDescription
                ), sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .failed,
                    tokenUsage: latestTokenUsage,
                    finishedAt: Date(),
                    errorKind: "streaming_error"
                )
            }
        }
    }

    /// 处理已解析的聊天消息，包含所有工具调用和 UI 更新的核心逻辑。
    func processResponseMessage(
        responseMessage: ChatMessage,
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
        enableMemoryActiveRetrieval: Bool = false,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30
    ) async {
        var responseMessage = responseMessage
        if let reasoning = responseMessage.reasoningContent {
            let normalized = normalizeEscapedNewlinesIfNeeded(reasoning)
            responseMessage.reasoningContent = normalized.isEmpty ? nil : normalized
        }

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

        guard let toolCalls = responseMessage.toolCalls, !toolCalls.isEmpty else {
            updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
            scheduleReasoningSummaryIfNeeded(for: loadingMessageID, in: currentSessionID)
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            return
        }

        updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
        scheduleReasoningSummaryIfNeeded(for: loadingMessageID, in: currentSessionID)
        let toolCallMessageID = loadingMessageID
        ensureToolCallsVisible(toolCalls, in: toolCallMessageID, sessionID: currentSessionID)
        let activeAttemptMetadata = responseAttemptMetadata(for: toolCallMessageID, in: currentSessionID)
            ?? responseAttemptMetadata(from: responseMessage)

        let toolDefs = availableTools ?? []
        if toolDefs.isEmpty {
            logger.info("当前未提供任何工具定义，忽略 AI 返回的 \(toolCalls.count) 个工具调用。")
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            return
        }
        let blockingCalls = toolCalls.filter { tc in
            toolDefs.first { $0.name == tc.toolName }?.isBlocking == true
        }
        let nonBlockingCalls = toolCalls.filter { tc in
            toolDefs.first { $0.name == tc.toolName }?.isBlocking != true
        }

        let hasAssistantContent = !responseMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
                logger.info("在后台启动 \(nonBlockingCalls.count) 个非阻塞式工具...")
                Task {
                    for toolCall in nonBlockingCalls {
                        let outcome = await handleToolCall(toolCall)
                        if let toolResult = outcome.toolResult {
                            await attachToolResult(toolResult, to: toolCall.id, toolName: toolCall.toolName, loadingMessageID: toolCallMessageID, sessionID: currentSessionID)
                        }
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
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
        }
    }
}
