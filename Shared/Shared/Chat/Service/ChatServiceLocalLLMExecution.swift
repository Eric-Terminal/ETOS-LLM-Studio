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
    func generateDetachedLocalLLMCompletion(
        runnableModel: RunnableModel,
        requestMessages: [ChatMessage],
        temperature: Double,
        requestLogContext: RequestLogContext
    ) async throws -> String {
        guard let recordID = LocalModelProviderBridge.localRecordID(from: runnableModel.id),
              let record = localModelStore.models.first(where: { $0.id == recordID }) else {
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "local_model_missing"
            )
            throw LocalLLMEngineError.modelFileMissing(runnableModel.model.displayName)
        }

        guard localModelStore.fileExists(for: record) else {
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "local_model_missing"
            )
            throw LocalLLMEngineError.modelFileMissing(record.fileName)
        }

        do {
            let overrides = runnableModel.effectiveOverrideParameters
            let output = try await LocalLLMEngine.shared.generate(
                messages: LocalLLMChatMessageBuilder.messages(from: requestMessages),
                modelURL: localModelStore.fileURL(for: record),
                options: LocalLLMGenerationOptions(
                    contextSize: max(1, overrides.localIntValue(for: "context_size") ?? overrides.localIntValue(for: "n_ctx") ?? record.contextSize),
                    maxOutputTokens: max(1, overrides.localIntValue(for: "max_output_tokens") ?? overrides.localIntValue(for: "max_tokens") ?? record.maxOutputTokens),
                    temperature: overrides.localDoubleValue(for: "temperature") ?? temperature,
                    topP: overrides.localDoubleValue(for: "top_p"),
                    gpuLayers: overrides.localIntValue(for: "n_gpu_layers") ?? record.gpuLayers,
                    advancedArguments: overrides.localStringValue(for: "llama_cli_args") ?? record.advancedArguments
                )
            )
            persistRequestLog(
                context: requestLogContext,
                status: .success,
                tokenUsage: nil,
                finishedAt: Date()
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            persistRequestLog(
                context: requestLogContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
            throw CancellationError()
        } catch {
            let errorKind = isCancellationError(error) ? "cancelled" : "local_generation_failed"
            let status: RequestLogStatus = isCancellationError(error) ? .cancelled : .failed
            persistRequestLog(
                context: requestLogContext,
                status: status,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: errorKind
            )
            throw error
        }
    }

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
        requestLogContext: RequestLogContext,
        availableTools: [InternalToolDefinition]?
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
            let overrides = runnableModel.effectiveOverrideParameters
            let localMessagesToSend = LocalLLMChatMessageBuilder.messages(from: messagesToSend)
            let localTools = LocalLLMChatMessageBuilder.toolDefinitions(from: availableTools)
            let stream = try LocalLLMEngine.shared.stream(
                messages: localMessagesToSend,
                tools: localTools,
                modelURL: localModelStore.fileURL(for: record),
                options: LocalLLMGenerationOptions(
                    contextSize: max(1, overrides.localIntValue(for: "context_size") ?? overrides.localIntValue(for: "n_ctx") ?? record.contextSize),
                    maxOutputTokens: max(1, overrides.localIntValue(for: "max_output_tokens") ?? overrides.localIntValue(for: "max_tokens") ?? record.maxOutputTokens),
                    temperature: overrides.localDoubleValue(for: "temperature") ?? aiTemperature,
                    topP: overrides.localDoubleValue(for: "top_p") ?? aiTopP,
                    gpuLayers: overrides.localIntValue(for: "n_gpu_layers") ?? record.gpuLayers,
                    advancedArguments: overrides.localStringValue(for: "llama_cli_args") ?? record.advancedArguments
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
            let parsedOutput: LocalLLMToolCallParseResult
            if localTools.isEmpty {
                parsedOutput = LocalLLMToolCallParseResult(content: output, toolCalls: [])
            } else {
                parsedOutput = try await LocalLLMEngine.shared.parseToolCalls(
                    from: output,
                    messages: localMessagesToSend,
                    tools: localTools,
                    modelURL: localModelStore.fileURL(for: record)
                )
            }
            var responseMessage = ChatMessage(
                role: .assistant,
                content: parsedOutput.content,
                requestedAt: requestStartedAt,
                toolCalls: parsedOutput.toolCalls.isEmpty ? nil : parsedOutput.toolCalls,
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

private extension Dictionary where Key == String, Value == JSONValue {
    func localIntValue(for key: String) -> Int? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            return rawValue
        case .double(let rawValue):
            return Int(rawValue)
        case .string(let rawValue):
            return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func localDoubleValue(for key: String) -> Double? {
        guard let value = self[key] else { return nil }
        switch value {
        case .double(let rawValue):
            return rawValue
        case .int(let rawValue):
            return Double(rawValue)
        case .string(let rawValue):
            return Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func localStringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        switch value {
        case .string(let rawValue):
            return rawValue
        case .int(let rawValue):
            return String(rawValue)
        case .double(let rawValue):
            return String(rawValue)
        case .bool(let rawValue):
            return rawValue ? "true" : "false"
        default:
            return nil
        }
    }
}
