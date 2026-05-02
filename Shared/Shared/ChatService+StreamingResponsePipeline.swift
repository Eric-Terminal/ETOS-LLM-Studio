// ============================================================================
// ChatService+StreamingResponsePipeline.swift
// ============================================================================
// ChatService 的流式响应处理、加载消息更新、内联图片提取与成就触发。
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

            // 保存流式过程中逐步构建的工具调用，用于后续二次调用
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
                        // 记录工具调用的增量信息
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
                        // 将当前已知的工具调用更新到消息，便于 UI 显示“正在调用工具”
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
            // 检测是否为取消错误（URLError.cancelled 不会匹配 CancellationError）
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
    
    /// 在取消请求时，只有占位消息无内容时才移除，避免丢失已接收的部分回复。
    func removeMessage(withID messageID: UUID, in sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages.remove(at: index)
            persistAndPublishMessages(messages, for: sessionID)
            logger.info("已移除占位消息 \(messageID.uuidString)。")
        }
    }

    func shouldRemoveLoadingMessageOnCancel(loadingMessageID: UUID, in sessionID: UUID) -> Bool {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == loadingMessageID }) else {
            return false
        }
        return !messageHasDisplayablePayload(message)
    }

    func finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: UUID, in sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        let finalizedMessage = finalizeInterruptedReasoningMessage(messages[index])
        guard finalizedMessage != messages[index] else { return }
        messages[index] = finalizedMessage
        persistAndPublishMessages(messages, for: sessionID)
    }

    func restoreRetryTargetMessageIfNeeded(loadingMessageID: UUID, in sessionID: UUID) -> Bool {
        guard retryTargetMessageID == loadingMessageID,
              let originalAssistant = retryTargetOriginalAssistantMessage else {
            return false
        }
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == loadingMessageID }) else {
            retryTargetMessageID = nil
            retryTargetOriginalAssistantMessage = nil
            return false
        }
        if messageHasDisplayablePayload(messages[index]) {
            return false
        }
        messages[index] = originalAssistant
        persistAndPublishMessages(messages, for: sessionID)
        retryTargetMessageID = nil
        retryTargetOriginalAssistantMessage = nil
        return true
    }

    func messageHasDisplayablePayload(_ message: ChatMessage) -> Bool {
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !(message.toolCalls ?? []).isEmpty
        let hasImages = !(message.imageFileNames ?? []).isEmpty
        let hasAudio = message.audioFileName != nil
        let hasFiles = !(message.fileFileNames ?? []).isEmpty
        return hasContent || hasReasoning || hasToolCalls || hasImages || hasAudio || hasFiles
    }
    
    /// 将最终确定的消息更新到消息列表中
    func updateMessage(with newMessage: ChatMessage, for loadingMessageID: UUID, in sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        
        // 检查是否是重试场景，需要添加新版本
        if let targetID = retryTargetMessageID,
           let targetIndex = messages.firstIndex(where: { $0.id == targetID }) {
            // 找到目标assistant消息（此时它应该处于 loading 状态，已经有一个空版本）
            var targetMessage = messages[targetIndex]
            
            // 【重要】直接更新当前版本（即 loading 时添加的空版本），而不是再添加新版本
            // 因为在 retryGenerating 中已经调用了 addVersion("") 创建了新版本
            targetMessage.content = newMessage.content
            
            // 如果有推理内容，也添加到新版本
            if let newReasoning = newMessage.reasoningContent, !newReasoning.isEmpty {
                targetMessage.reasoningContent = newReasoning
            }
            if let newReasoningFields = newMessage.reasoningProviderSpecificFields {
                targetMessage.reasoningProviderSpecificFields = newReasoningFields
            }
            targetMessage.audioFileName = newMessage.audioFileName
            targetMessage.imageFileNames = newMessage.imageFileNames
            targetMessage.fileFileNames = newMessage.fileFileNames
            
            // 更新 token 使用情况
            if let newUsage = newMessage.tokenUsage {
                targetMessage.tokenUsage = newUsage
            }
            
            // 如果新消息有工具调用，也要更新
            if let newToolCalls = newMessage.toolCalls {
                targetMessage.toolCalls = newToolCalls
            }
            if let newPlacement = newMessage.toolCallsPlacement {
                targetMessage.toolCallsPlacement = newPlacement
            }
            if let newMetrics = newMessage.responseMetrics {
                targetMessage.responseMetrics = newMetrics
            }
            targetMessage.responseGroupID = newMessage.responseGroupID ?? targetMessage.responseGroupID
            targetMessage.responseAttemptID = newMessage.responseAttemptID ?? targetMessage.responseAttemptID
            targetMessage.responseAttemptIndex = newMessage.responseAttemptIndex ?? targetMessage.responseAttemptIndex
            
            messages[targetIndex] = targetMessage
            
            // 注意：这里不需要移除 loading message，因为 targetID 就是 loadingMessageID
            // 我们已经在原位置更新了消息
            
            // 清除重试标记
            retryTargetMessageID = nil
            retryTargetOriginalAssistantMessage = nil
            
            persistAndPublishMessages(messages, for: sessionID, keepingSpeedSamplesFor: loadingMessageID)
            
            logger.info("已将新内容追加到消息历史: \(targetID)")
        } else if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
            // 正常流程：替换loading message
            let preservedToolCalls = messages[index].toolCalls
            let mergedToolCalls: [InternalToolCall]? = {
                if let newCalls = newMessage.toolCalls, !newCalls.isEmpty {
                    return newCalls
                }
                // 如果新消息没有附带工具调用，则沿用之前的记录，方便在最终答案中回顾工具使用详情。
                return preservedToolCalls
            }()
            messages[index] = ChatMessage(
                id: loadingMessageID, // 保持ID不变
                role: newMessage.role,
                content: newMessage.content,
                requestedAt: messages[index].requestedAt ?? newMessage.requestedAt,
                reasoningContent: newMessage.reasoningContent,
                reasoningProviderSpecificFields: newMessage.reasoningProviderSpecificFields ?? messages[index].reasoningProviderSpecificFields,
                toolCalls: mergedToolCalls, // 确保 toolCalls 保持最新或沿用历史数据
                toolCallsPlacement: newMessage.toolCallsPlacement ?? messages[index].toolCallsPlacement,
                tokenUsage: newMessage.tokenUsage ?? messages[index].tokenUsage,
                audioFileName: newMessage.audioFileName ?? messages[index].audioFileName,
                imageFileNames: newMessage.imageFileNames ?? messages[index].imageFileNames,
                fileFileNames: newMessage.fileFileNames ?? messages[index].fileFileNames,
                fullErrorContent: newMessage.fullErrorContent ?? messages[index].fullErrorContent,
                responseMetrics: newMessage.responseMetrics ?? messages[index].responseMetrics,
                responseGroupID: newMessage.responseGroupID ?? messages[index].responseGroupID,
                responseAttemptID: newMessage.responseAttemptID ?? messages[index].responseAttemptID,
                responseAttemptIndex: newMessage.responseAttemptIndex ?? messages[index].responseAttemptIndex,
                selectedResponseAttemptID: newMessage.selectedResponseAttemptID ?? messages[index].selectedResponseAttemptID
            )
            persistAndPublishMessages(messages, for: sessionID)
        }
    }

    func scheduleAssistantReplyAchievementDetectionIfNeeded(_ content: String) {
        Task.detached(priority: .utility) {
            guard !content.isEmpty else { return }

            let hasUnlockedSteadyCatch = await AchievementCenter.shared.hasUnlocked(id: .steadyCatch)
            if !hasUnlockedSteadyCatch,
               AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: content) {
                await AchievementCenter.shared.unlock(id: .steadyCatch)
            }

            let hasUnlockedLanguageLubrication = await AchievementCenter.shared.hasUnlocked(id: .languageLubrication)
            if !hasUnlockedLanguageLubrication,
               AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: content) {
                await AchievementCenter.shared.unlock(id: .languageLubrication)
            }
        }
    }

    func scheduleUserMessageAchievementDetectionIfNeeded(
        content: String,
        userMessageCount: Int,
        sentAt: Date,
        previousAssistantReply: String?
    ) {
        Task.detached(priority: .utility) {
            let hasUnlockedPoliteHuman = await AchievementCenter.shared.hasUnlocked(id: .politeHuman)
            let ids = AchievementTriggerEvaluator.userMessageAchievementIDs(
                for: content,
                userMessageCount: userMessageCount,
                sentAt: sentAt,
                previousAssistantReply: previousAssistantReply,
                includePoliteHuman: !hasUnlockedPoliteHuman
            )
            guard !ids.isEmpty else { return }

            for id in ids {
                let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
                guard !hasUnlocked else { continue }
                await AchievementCenter.shared.unlock(id: id)
            }
        }
    }

    func latestAssistantReply(in sessionID: UUID) -> String? {
        messagesSnapshot(for: sessionID).last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
    }

    func scheduleAchievementUnlockIfNeeded(_ id: AchievementID) {
        Task.detached(priority: .utility) {
            let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: id)
        }
    }

    func registerRetryAchievementAttempt(sessionID: UUID, content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            resetConsecutiveRetryTracking()
            return
        }

        let signature = RetryAchievementSignature(sessionID: sessionID, content: trimmedContent)
        if consecutiveRetrySignature == signature {
            consecutiveRetryCount += 1
        } else {
            consecutiveRetrySignature = signature
            consecutiveRetryCount = 1
        }

        if AchievementTriggerEvaluator.shouldUnlockSchrodingerQuestion(consecutiveRetryCount: consecutiveRetryCount) {
            scheduleAchievementUnlockIfNeeded(.schrodingerQuestion)
        }
    }

    func resetConsecutiveRetryTracking() {
        consecutiveRetrySignature = nil
        consecutiveRetryCount = 0
    }

    struct InlineImageExtractionResult {
        let cleanedContent: String
        let imageFileNames: [String]
    }

    struct InlineImagePayload {
        let data: Data
        let mimeType: String
    }

    func extractInlineImagesFromMarkdown(_ content: String) async -> InlineImageExtractionResult {
        guard !content.isEmpty else {
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)", options: [])
        } catch {
            logger.error("解析 markdown 图片正则失败: \(error.localizedDescription)")
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        var workingContent = content
        var savedFileNamesInReverse: [String] = []
        var extractedCount = 0

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: content),
                  let sourceRange = Range(match.range(at: 1), in: content) else { continue }

            let rawSource = String(content[sourceRange])
            guard let normalizedSource = normalizeMarkdownImageSource(rawSource) else { continue }
            guard let payload = await resolveInlineImagePayload(from: normalizedSource) else { continue }
            guard let savedFileName = saveInlineImage(payload) else { continue }

            if let replaceRange = Range(match.range(at: 0), in: workingContent) {
                workingContent.replaceSubrange(replaceRange, with: "")
            } else {
                // 退化处理：范围映射失败时保持原文，避免误删
                logger.warning("图片标记替换失败，已跳过该标记: \(String(content[fullRange]))")
            }

            savedFileNamesInReverse.append(savedFileName)
            extractedCount += 1
        }

        if extractedCount > 0 {
            logger.info("已从 markdown 正文提取并保存 \(extractedCount) 张图片附件。")
        }

        return InlineImageExtractionResult(
            cleanedContent: normalizeContentAfterImageExtraction(workingContent),
            imageFileNames: savedFileNamesInReverse.reversed()
        )
    }

    func normalizeMarkdownImageSource(_ rawSource: String) -> String? {
        var source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("<"), source.hasSuffix(">"), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        if let firstWhitespace = source.firstIndex(where: { $0.isWhitespace }) {
            source = String(source[..<firstWhitespace])
        }
        if source.hasPrefix("\""), source.hasSuffix("\""), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        if source.hasPrefix("'"), source.hasSuffix("'"), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        return source.isEmpty ? nil : source
    }
}
