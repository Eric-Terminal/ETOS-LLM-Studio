// ============================================================================
// ChatServiceLocalLLMExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责本地 GGUF 模型的请求执行与现有聊天生命周期衔接。
// ============================================================================

import Foundation
import OSLog

extension ChatService {
    func handleLocalLLMResponse(
        runnableModel: RunnableModel,
        messagesToSend: [ChatMessage],
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
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
        guard let record = localModelRecord(for: runnableModel) else {
            let message = NSLocalizedString("本地模型文件不存在，请重新导入权重或停用该模型。", comment: "Local model missing error")
            addErrorMessage(message, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "local_model_missing"
            )
            return
        }

        do {
            let stream = try LocalLLMEngine.shared.stream(
                messages: LocalLLMChatMessageBuilder.messages(from: messagesToSend),
                modelURL: localModelStore.fileURL(for: record),
                options: LocalLLMGenerationOptions(
                    contextSize: record.contextSize,
                    maxOutputTokens: record.maxOutputTokens,
                    temperature: aiTemperature,
                    topP: aiTopP
                )
            )

            var output = ""
            var firstTokenAt: Date?
            var lastTokenAt: Date?
            var speedSamples: [MessageResponseMetrics.SpeedSample] = []
            var messages = messagesSnapshot(for: currentSessionID)

            for try await tokenText in stream {
                guard !tokenText.isEmpty else { continue }
                let receivedAt = Date()
                if firstTokenAt == nil {
                    firstTokenAt = receivedAt
                }
                lastTokenAt = receivedAt
                output += tokenText

                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    messages[index].role = .assistant
                    messages[index].content += tokenText
                    messages[index].modelReference = requestLogContext.modelReference
                    if enableResponseSpeedMetrics {
                        let estimatedTokens = estimatedCompletionTokens(from: output)
                        let speed = streamingTokenPerSecond(
                            tokens: estimatedTokens,
                            requestStartedAt: requestStartedAt,
                            firstTokenAt: firstTokenAt,
                            snapshotAt: receivedAt
                        )
                        appendSpeedSample(
                            to: &speedSamples,
                            elapsed: max(0, receivedAt.timeIntervalSince(requestStartedAt)),
                            speed: speed
                        )
                        messages[index].responseMetrics = makeResponseMetrics(
                            requestStartedAt: requestStartedAt,
                            responseCompletedAt: nil,
                            totalResponseDuration: nil,
                            timeToFirstToken: firstTokenAt.map { max(0, $0.timeIntervalSince(requestStartedAt)) },
                            completionTokensForSpeed: estimatedTokens,
                            tokenPerSecond: speed,
                            isEstimated: true,
                            speedSamples: speedSamples.isEmpty ? nil : speedSamples
                        )
                    }
                    messages = publishStreamingMessages(
                        messages,
                        loadingMessageID: loadingMessageID,
                        sessionID: currentSessionID
                    )
                }
            }

            let responseCompletedAt = Date()
            let totalDuration = max(0, responseCompletedAt.timeIntervalSince(requestStartedAt))
            let estimatedCompletionTokens = estimatedCompletionTokens(from: output)
            let finalSpeed = enableResponseSpeedMetrics ? streamingTokenPerSecond(
                tokens: estimatedCompletionTokens,
                requestStartedAt: requestStartedAt,
                firstTokenAt: firstTokenAt,
                snapshotAt: lastTokenAt ?? responseCompletedAt
            ) : nil
            if enableResponseSpeedMetrics {
                appendSpeedSample(
                    to: &speedSamples,
                    elapsed: totalDuration,
                    speed: finalSpeed
                )
            }
            var responseMessage = ChatMessage(
                role: .assistant,
                content: output,
                requestedAt: requestStartedAt,
                modelReference: requestLogContext.modelReference
            )
            if enableResponseSpeedMetrics {
                responseMessage.responseMetrics = makeResponseMetrics(
                    requestStartedAt: requestStartedAt,
                    responseCompletedAt: responseCompletedAt,
                    totalResponseDuration: totalDuration,
                    timeToFirstToken: firstTokenAt.map { max(0, $0.timeIntervalSince(requestStartedAt)) },
                    completionTokensForSpeed: estimatedCompletionTokens,
                    tokenPerSecond: finalSpeed ?? tokenPerSecond(tokens: estimatedCompletionTokens, elapsed: totalDuration),
                    isEstimated: true,
                    speedSamples: speedSamples.isEmpty ? nil : speedSamples
                )
            }
            attachCostEstimateIfPossible(to: &responseMessage, using: requestLogContext)
            persistRequestLog(
                context: requestLogContext,
                status: .success,
                tokenUsage: nil,
                finishedAt: responseCompletedAt
            )
            await processResponseMessage(
                responseMessage: responseMessage,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                availableTools: nil,
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
            logger.info("本地推理请求已取消。")
            finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingMessageID, in: currentSessionID)
            emitSessionRequestStatus(.cancelled, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
        } catch {
            logger.error("本地推理失败: \(error.localizedDescription)")
            addErrorMessage(String(
                format: NSLocalizedString("本地推理失败: %@", comment: "Local LLM generation failed"),
                error.localizedDescription
            ), sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "local_generation_failed"
            )
        }
    }
}
