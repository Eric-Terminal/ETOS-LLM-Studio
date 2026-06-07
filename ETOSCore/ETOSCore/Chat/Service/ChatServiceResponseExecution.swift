// ============================================================================
// ChatServiceResponseExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的响应执行、消息发布与标准响应处理。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    /// 仅在内存中保留“最近一条助手消息”的流式速度采样，避免历史样本长期占用内存。
    private func normalizedMessagesForRuntime(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        let keepMessageID = preferredMessageID ?? messages.last(where: { $0.role == .assistant })?.id

        return messages.map { message in
            guard var metrics = message.responseMetrics, metrics.speedSamples != nil else {
                return message
            }
            if let keepMessageID, message.id == keepMessageID {
                return message
            }
            var trimmedMessage = message
            metrics.speedSamples = nil
            trimmedMessage.responseMetrics = metrics
            return trimmedMessage
        }
    }

    /// 将流式采样作为临时 UI 数据，不写入磁盘，避免会话文件膨胀。
    private func normalizedMessagesForPersistence(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard var metrics = message.responseMetrics, metrics.speedSamples != nil else {
                return message
            }
            var trimmedMessage = message
            metrics.speedSamples = nil
            trimmedMessage.responseMetrics = metrics
            return trimmedMessage
        }
    }

    func publishMessages(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        let normalized = normalizedMessagesForRuntime(messages, keepingSpeedSamplesFor: preferredMessageID)
        messagesForSessionSubject.send(normalized)
    }

    func messagesByMergingStreamingUpdate(
        _ streamingMessages: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID
    ) -> [ChatMessage] {
        guard let streamingIndex = streamingMessages.firstIndex(where: { $0.id == loadingMessageID }) else {
            return streamingMessages
        }
        var latestMessages = messagesSnapshot(for: sessionID)
        guard let latestIndex = latestMessages.firstIndex(where: { $0.id == loadingMessageID }) else {
            return latestMessages
        }
        latestMessages[latestIndex] = streamingMessages[streamingIndex]
        return latestMessages
    }

    func publishStreamingMessages(
        _ messages: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID
    ) -> [ChatMessage] {
        let merged = messagesByMergingStreamingUpdate(
            messages,
            loadingMessageID: loadingMessageID,
            sessionID: sessionID
        )
        publishMessagesIfCurrentSession(merged, for: sessionID, keepingSpeedSamplesFor: loadingMessageID)
        return merged
    }

    func publishStreamingMessages(
        _ messages: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID,
        coalescer: inout StreamingUIPublishCoalescer,
        force: Bool = false
    ) -> [ChatMessage] {
        let merged = messagesByMergingStreamingUpdate(
            messages,
            loadingMessageID: loadingMessageID,
            sessionID: sessionID
        )
        if coalescer.shouldPublish(force: force) {
            publishMessagesIfCurrentSession(merged, for: sessionID, keepingSpeedSamplesFor: loadingMessageID)
        }
        return merged
    }

    func flushPendingStreamingMessages(
        _ messages: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID,
        coalescer: inout StreamingUIPublishCoalescer
    ) -> [ChatMessage] {
        let merged = messagesByMergingStreamingUpdate(
            messages,
            loadingMessageID: loadingMessageID,
            sessionID: sessionID
        )
        if coalescer.shouldFlushPending() {
            publishMessagesIfCurrentSession(merged, for: sessionID, keepingSpeedSamplesFor: loadingMessageID)
        }
        return merged
    }

    func persistAndPublishStreamingMessages(
        _ messages: [ChatMessage],
        loadingMessageID: UUID,
        sessionID: UUID
    ) -> [ChatMessage] {
        let merged = messagesByMergingStreamingUpdate(
            messages,
            loadingMessageID: loadingMessageID,
            sessionID: sessionID
        )
        persistAndPublishMessages(merged, for: sessionID, keepingSpeedSamplesFor: loadingMessageID)
        return merged
    }

    func persistMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        let persisted = normalizedMessagesForPersistence(messages)
        Persistence.saveMessages(persisted, for: sessionID)
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
                attachCostEstimateIfPossible(to: &parsedMessage, using: requestLogContext)
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

    func scheduleAchievementUnlockIfNeeded(_ id: AchievementID) {
        Task.detached(priority: .utility) {
            let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: id)
        }
    }
}
