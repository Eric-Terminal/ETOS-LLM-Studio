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
        requestLogContext: RequestLogContext,
        responsesFullInputFallbackRequest: URLRequest? = nil
    ) async {
        var latestTokenUsage: MessageTokenUsage?
        var trailingUnparsedResponseBody = ""
        var trailingUnparsedHTTPStatusCode: Int?
        var messages = messagesSnapshot(for: currentSessionID)
        var streamingPublishCoalescer = StreamingUIPublishCoalescer.platformDefault()
        let shouldCaptureResponseBody = AppConfigStore.boolValue(for: .requestLogEnabled)
        var rawStreamingResponseLines: [String] = []

        func rawStreamingResponseBody() -> String {
            rawStreamingResponseLines.joined(separator: "\n")
        }

        func logCapturedStreamingResponse(isPartial: Bool = false, httpStatusCode: Int? = nil) {
            guard shouldCaptureResponseBody, !rawStreamingResponseLines.isEmpty else { return }
            logResponseBodySnapshot(
                context: requestLogContext,
                request: request,
                body: rawStreamingResponseBody(),
                httpStatusCode: httpStatusCode,
                isPartial: isPartial
            )
        }

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
            var finalResponseCompletedAtForLog: Date?

            for try await line in bytes.lines {
                if shouldCaptureResponseBody {
                    rawStreamingResponseLines.append(line)
                }

                guard let part = adapter.parseStreamingResponse(line: line) else {
                    updateTrailingUnparsedStreamingResponse(
                        with: line,
                        body: &trailingUnparsedResponseBody,
                        httpStatusCode: &trailingUnparsedHTTPStatusCode
                    )
                    continue
                }
                trailingUnparsedResponseBody = ""
                trailingUnparsedHTTPStatusCode = nil
                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    let previousStreamingMessage = messages[index]
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
                    var shouldForceStreamingPublish = false
                    if let contentPart = part.content {
                        messages[index].content += contentPart
                        if !contentPart.isEmpty {
                            accumulatedOutputText += contentPart
                            didReceiveTextDelta = true
                            didReceiveGeneratedDelta = true
                            if previousStreamingMessage.content.isEmpty {
                                shouldForceStreamingPublish = true
                            }
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
                                shouldForceStreamingPublish = true
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
                            if (previousStreamingMessage.reasoningContent ?? "").isEmpty {
                                shouldForceStreamingPublish = true
                            }
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
                                shouldForceStreamingPublish = true
                            }
                        }
                    }
                    if let reasoningProviderSpecificFields = part.reasoningProviderSpecificFields {
                        messages[index].reasoningProviderSpecificFields = mergeReasoningProviderSpecificFields(
                            existing: messages[index].reasoningProviderSpecificFields,
                            incoming: reasoningProviderSpecificFields
                        )
                    }
                    if let providerResponseMetadata = part.providerResponseMetadata {
                        messages[index].providerResponseMetadata = mergeProviderResponseMetadata(
                            existing: messages[index].providerResponseMetadata,
                            incoming: providerResponseMetadata
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
                            if let argumentsReplacement = delta.argumentsReplacement {
                                builder.arguments = argumentsReplacement
                            } else if let argsFragment = delta.argumentsFragment, !argsFragment.isEmpty {
                                builder.arguments += argsFragment
                            }
                            if let providerSpecificFields = delta.providerSpecificFields, !providerSpecificFields.isEmpty {
                                builder.providerSpecificFields = mergeProviderResponseMetadata(
                                    existing: builder.providerSpecificFields,
                                    incoming: providerSpecificFields
                                )
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
                            let previousToolSignature = (previousStreamingMessage.toolCalls ?? []).map { "\($0.id)|\($0.toolName)" }
                            let currentToolSignature = partialToolCalls.map { "\($0.id)|\($0.toolName)" }
                            if previousToolSignature != currentToolSignature {
                                shouldForceStreamingPublish = true
                            }
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
                    messages = publishStreamingMessages(
                        messages,
                        loadingMessageID: loadingMessageID,
                        sessionID: currentSessionID,
                        coalescer: &streamingPublishCoalescer,
                        force: shouldForceStreamingPublish
                    )
                }
            }

            if let unparsedError = makeUnparsedStreamingResponseError(
                body: trailingUnparsedResponseBody,
                fallbackHTTPStatusCode: trailingUnparsedHTTPStatusCode
            ) {
                logCapturedStreamingResponse(isPartial: true, httpStatusCode: unparsedError.httpStatusCode)
                messages = flushPendingStreamingMessages(
                    messages,
                    loadingMessageID: loadingMessageID,
                    sessionID: currentSessionID,
                    coalescer: &streamingPublishCoalescer
                )
                addErrorMessage(
                    unparsedError.body,
                    sessionID: currentSessionID,
                    httpStatusCode: unparsedError.httpStatusCode
                )
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .failed,
                    tokenUsage: latestTokenUsage,
                    finishedAt: Date(),
                    httpStatusCode: unparsedError.httpStatusCode,
                    errorKind: "streaming_unparsed_error_response"
                )
                return
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
                attachOpenAIResponsesRequestMetadata(
                    to: &messages[index],
                    request: request,
                    messagesBeforeResponse: messages
                )
                attachCostEstimateIfPossible(to: &messages[index], using: requestLogContext)
                finalAssistantMessage = messages[index]
                messages = persistAndPublishStreamingMessages(
                    messages,
                    loadingMessageID: loadingMessageID,
                    sessionID: currentSessionID
                )
            }

            if let finalAssistantMessage = finalAssistantMessage {
                let finishedAt = finalResponseCompletedAtForLog ?? finalAssistantMessage.responseMetrics?.responseCompletedAt ?? Date()
                logCapturedStreamingResponse()
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
                    enableStreaming: true,
                    enableMemory: enableMemory,
                    enableMemoryWrite: enableMemoryWrite,
                    enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                    includeSystemTime: includeSystemTime,
                    systemTimeInjectionPosition: systemTimeInjectionPosition,
                    enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                    periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes
                )
            } else {
                logCapturedStreamingResponse()
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
            logCapturedStreamingResponse(isPartial: true)
            messages = flushPendingStreamingMessages(
                messages,
                loadingMessageID: loadingMessageID,
                sessionID: currentSessionID,
                coalescer: &streamingPublishCoalescer
            )
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
            logResponseBodySnapshot(
                context: requestLogContext,
                request: request,
                bodyData: bodyData,
                httpStatusCode: code
            )
            if let fallbackRequest = responsesFullInputFallbackRequest,
               isOpenAIResponsesPreviousResponseMissing(statusCode: code, bodyData: bodyData) {
                logger.info("Responses previous_response_id 已失效，正在改用完整 input 重试。")
                await handleStreamedResponse(
                    request: fallbackRequest,
                    provider: provider,
                    adapter: adapter,
                    loadingMessageID: loadingMessageID,
                    currentSessionID: currentSessionID,
                    userMessage: userMessage,
                    wasTemporarySession: wasTemporarySession,
                    aiTemperature: aiTemperature,
                    aiTopP: aiTopP,
                    systemPrompt: systemPrompt,
                    maxChatHistory: maxChatHistory,
                    availableTools: availableTools,
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
                    responsesFullInputFallbackRequest: nil
                )
                return
            }
            messages = flushPendingStreamingMessages(
                messages,
                loadingMessageID: loadingMessageID,
                sessionID: currentSessionID,
                coalescer: &streamingPublishCoalescer
            )
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
                logCapturedStreamingResponse(isPartial: true)
                messages = flushPendingStreamingMessages(
                    messages,
                    loadingMessageID: loadingMessageID,
                    sessionID: currentSessionID,
                    coalescer: &streamingPublishCoalescer
                )
                finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingMessageID, in: currentSessionID)
                persistRequestLog(
                    context: requestLogContext,
                    status: .cancelled,
                    tokenUsage: latestTokenUsage,
                    finishedAt: Date(),
                    errorKind: "cancelled"
                )
            } else {
                if let unparsedError = makeUnparsedStreamingResponseError(
                    body: trailingUnparsedResponseBody,
                    fallbackHTTPStatusCode: trailingUnparsedHTTPStatusCode
                ) {
                    logCapturedStreamingResponse(isPartial: true, httpStatusCode: unparsedError.httpStatusCode)
                    messages = flushPendingStreamingMessages(
                        messages,
                        loadingMessageID: loadingMessageID,
                        sessionID: currentSessionID,
                        coalescer: &streamingPublishCoalescer
                    )
                    addErrorMessage(
                        unparsedError.body,
                        sessionID: currentSessionID,
                        httpStatusCode: unparsedError.httpStatusCode
                    )
                    emitSessionRequestStatus(.error, sessionID: currentSessionID)
                    persistRequestLog(
                        context: requestLogContext,
                        status: .failed,
                        tokenUsage: latestTokenUsage,
                        finishedAt: Date(),
                        httpStatusCode: unparsedError.httpStatusCode,
                        errorKind: "streaming_unparsed_error_response"
                    )
                } else {
                    logCapturedStreamingResponse(isPartial: true)
                    messages = flushPendingStreamingMessages(
                        messages,
                        loadingMessageID: loadingMessageID,
                        sessionID: currentSessionID,
                        coalescer: &streamingPublishCoalescer
                    )
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
        enableStreaming: Bool = false,
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

        if enableStreaming {
            let generatedImageFileNames = extractGeneratedImagesFromProviderResponseMetadata(responseMessage.providerResponseMetadata)
            if !generatedImageFileNames.isEmpty {
                responseMessage.imageFileNames = (responseMessage.imageFileNames ?? []) + generatedImageFileNames
            }
        }

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
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID, enableMemory: enableMemory)
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
                let outcome = await handleToolCall(toolCall, sessionID: currentSessionID)
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
                        let outcome = await handleToolCall(toolCall, sessionID: currentSessionID)
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
                    let outcome = await handleToolCall(toolCall, sessionID: currentSessionID)
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
                enableStreaming: enableStreaming, enhancedPrompt: nil, tools: availableTools, enableMemory: enableMemory, enableMemoryWrite: enableMemoryWrite,
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
            scheduleConversationMemoryUpdateIfNeeded(for: currentSessionID, enableMemory: enableMemory)
            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
        }
    }

    private func updateTrailingUnparsedStreamingResponse(
        with line: String,
        body: inout String,
        httpStatusCode: inout Int?
    ) {
        switch classifyUnparsedStreamingLine(line, isCapturingBody: !body.isEmpty) {
        case .append(let payload):
            appendUnparsedStreamingPayload(payload, to: &body)
            if httpStatusCode == nil {
                httpStatusCode = inferredHTTPStatusCode(from: body)
            }
        case .reset:
            body = ""
            httpStatusCode = nil
        case .ignore:
            break
        }
    }

    private func makeUnparsedStreamingResponseError(
        body: String,
        fallbackHTTPStatusCode: Int?
    ) -> (body: String, httpStatusCode: Int?)? {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty, looksLikeStreamingErrorResponse(trimmedBody) else {
            return nil
        }
        return (trimmedBody, fallbackHTTPStatusCode ?? inferredHTTPStatusCode(from: trimmedBody))
    }

    private enum UnparsedStreamingLineAction {
        case append(String)
        case reset
        case ignore
    }

    private func classifyUnparsedStreamingLine(
        _ line: String,
        isCapturingBody: Bool
    ) -> UnparsedStreamingLineAction {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return isCapturingBody ? .append("") : .ignore
        }

        if trimmedLine == "[DONE]" {
            return .reset
        }

        if trimmedLine.hasPrefix("data:") {
            let payload = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                return .reset
            }
            guard !payload.isEmpty else { return .ignore }
            if looksLikeStreamingErrorResponse(payload) || isCapturingBody {
                return .append(payload)
            }
            return .ignore
        }

        if trimmedLine.hasPrefix(":")
            || trimmedLine.hasPrefix("event:")
            || trimmedLine.hasPrefix("id:")
            || trimmedLine.hasPrefix("retry:") {
            return .ignore
        }

        if looksLikeStreamingErrorResponse(trimmedLine) || isCapturingBody {
            return .append(line)
        }

        return .ignore
    }

    private func appendUnparsedStreamingPayload(_ payload: String, to body: inout String) {
        let maxLength = 64 * 1024
        if body.isEmpty {
            body = payload
        } else if payload.isEmpty {
            body += "\n"
        } else {
            body += "\n\(payload)"
        }
        if body.count > maxLength {
            body = String(body.suffix(maxLength))
        }
    }

    private func looksLikeStreamingErrorResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
           jsonPayloadLooksLikeError(json) {
            return true
        }

        let lowercased = trimmed.lowercased()
        if trimmed.hasPrefix("HTTP/") || trimmed.hasPrefix("<!DOCTYPE") || lowercased.hasPrefix("<html") {
            return true
        }

        let errorMarkers = [
            "bad gateway",
            "gateway timeout",
            "gateway time-out",
            "service unavailable",
            "internal server error",
            "upstream timed out",
            "nginx",
            "cloudflare",
            "error",
            "错误",
            "失败",
            "无法解析流式响应",
            "无法解析流失响应"
        ]
        return errorMarkers.contains { lowercased.contains($0) }
    }

    private func jsonPayloadLooksLikeError(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String, type.lowercased() == "error" {
                return true
            }
            if let errorValue = dictionary["error"], !(errorValue is NSNull) {
                return true
            }
            if let statusCode = httpStatusCode(fromJSONObject: dictionary), statusCode >= 400 {
                return true
            }
            return dictionary.values.contains { jsonPayloadLooksLikeError($0) }
        }

        if let array = value as? [Any] {
            return array.contains { jsonPayloadLooksLikeError($0) }
        }

        return false
    }

    private func inferredHTTPStatusCode(from text: String) -> Int? {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let code = httpStatusCode(fromJSONObject: json) {
            return code
        }

        let patterns = [
            #"HTTP/\d(?:\.\d)?\s+([1-5]\d{2})"#,
            #"\b([1-5]\d{2})\s+(?:Bad Gateway|Gateway Timeout|Gateway Time-out|Service Unavailable|Internal Server Error|Not Found|Forbidden|Unauthorized|Too Many Requests)\b"#
        ]
        for pattern in patterns {
            if let code = firstHTTPStatusCode(in: text, pattern: pattern) {
                return code
            }
        }

        let lowercased = text.lowercased()
        if lowercased.contains("gateway timeout") || lowercased.contains("gateway time-out") {
            return 504
        }
        if lowercased.contains("bad gateway") {
            return 502
        }
        if lowercased.contains("service unavailable") {
            return 503
        }
        if lowercased.contains("internal server error") {
            return 500
        }
        if lowercased.contains("too many requests") {
            return 429
        }
        if lowercased.contains("unauthorized") {
            return 401
        }
        if lowercased.contains("forbidden") {
            return 403
        }
        if lowercased.contains("not found") {
            return 404
        }
        return nil
    }

    private func httpStatusCode(fromJSONObject value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            for key in ["status", "status_code", "statusCode", "code"] {
                if let code = normalizedHTTPStatusCode(from: dictionary[key]) {
                    return code
                }
            }
            for key in ["error", "response"] {
                if let nested = dictionary[key],
                   let code = httpStatusCode(fromJSONObject: nested) {
                    return code
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let code = httpStatusCode(fromJSONObject: item) {
                    return code
                }
            }
        }
        return nil
    }

    private func normalizedHTTPStatusCode(from value: Any?) -> Int? {
        if let intValue = value as? Int, (100...599).contains(intValue) {
            return intValue
        }
        if let stringValue = value as? String,
           let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           (100...599).contains(intValue) {
            return intValue
        }
        return nil
    }

    private func firstHTTPStatusCode(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let codeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[codeRange])
    }
}
