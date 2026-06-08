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
            let globalTemperatureEnabled = await MainActor.run { AppConfigStore.shared.aiTemperatureEnabled }
            let localModelCacheEnabled = await MainActor.run { AppConfigStore.shared.localModelCacheEnabled }
            let parsedOutput = try await LocalLLMEngine.shared.generateParsed(
                messages: LocalLLMChatMessageBuilder.messages(from: requestMessages),
                modelURL: localModelStore.fileURL(for: record),
                options: LocalLLMGenerationOptions(
                    contextSize: max(1, overrides.localIntValue(for: "context_size") ?? overrides.localIntValue(for: "n_ctx") ?? record.effectiveContextSize),
                    maxOutputTokens: max(1, overrides.localIntValue(for: "max_output_tokens") ?? overrides.localIntValue(for: "max_tokens") ?? record.effectiveMaxOutputTokens),
                    temperature: overrides.localDoubleValue(for: "temperature") ?? record.temperature ?? (globalTemperatureEnabled ? temperature : nil) ?? LocalModelRecord.defaultTemperature,
                    topP: overrides.localDoubleValue(for: "top_p") ?? record.effectiveTopP,
                    gpuLayers: localGPULayers(overrides: overrides, record: record),
                    batchSize: overrides.localIntValue(for: "batch_size") ?? overrides.localIntValue(for: "n_batch") ?? record.effectiveBatchSize,
                    ubatchSize: overrides.localIntValue(for: "ubatch_size") ?? overrides.localIntValue(for: "n_ubatch") ?? record.effectiveUbatchSize,
                    kvOffload: overrides.localBoolValue(for: "kv_offload") ?? record.effectiveKVOffload,
                    flashAttention: overrides.localFlashAttentionValue(for: "flash_attn") ?? record.effectiveFlashAttention,
                    useModelCache: localModelCacheEnabled,
                    seed: overrides.localUInt32Value(for: "seed") ?? record.effectiveSeed,
                    topK: overrides.localIntValue(for: "top_k") ?? record.effectiveTopK,
                    minP: overrides.localDoubleValue(for: "min_p") ?? record.effectiveMinP,
                    repeatLastN: overrides.localIntValue(for: "repeat_last_n") ?? record.effectiveRepeatLastN,
                    repeatPenalty: overrides.localDoubleValue(for: "repeat_penalty") ?? record.effectiveRepeatPenalty,
                    frequencyPenalty: overrides.localDoubleValue(for: "frequency_penalty") ?? record.effectiveFrequencyPenalty,
                    presencePenalty: overrides.localDoubleValue(for: "presence_penalty") ?? record.effectivePresencePenalty,
                    grammar: overrides.localStringValue(for: "grammar") ?? record.effectiveGrammar,
                    ignoreEOS: overrides.localBoolValue(for: "ignore_eos") ?? record.effectiveIgnoreEOS,
                    samplerKinds: overrides.localSamplerKindsValue(for: "sampler_seq") ?? record.effectiveSamplerKinds,
                    chatTemplateKwargs: try overrides.localChatTemplateKwargsValue(),
                    advancedArguments: overrides.localStringValue(for: "llama_cli_args") ?? record.advancedArguments
                )
            )
            persistRequestLog(
                context: requestLogContext,
                status: .success,
                tokenUsage: nil,
                finishedAt: Date()
            )
            if !parsedOutput.content.isEmpty {
                return parsedOutput.content
            }
            return (parsedOutput.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

        var messages = messagesSnapshot(for: currentSessionID)
        var streamingPublishCoalescer = StreamingUIPublishCoalescer.platformDefault()

        do {
            let overrides = runnableModel.effectiveOverrideParameters
            let globalTemperatureEnabled = await MainActor.run { AppConfigStore.shared.aiTemperatureEnabled }
            let globalTopPEnabled = await MainActor.run { AppConfigStore.shared.aiTopPEnabled }
            let localModelCacheEnabled = await MainActor.run { AppConfigStore.shared.localModelCacheEnabled }
            let localMessagesToSend = LocalLLMChatMessageBuilder.messages(from: messagesToSend)
            let localTools = LocalLLMChatMessageBuilder.toolDefinitions(from: availableTools)
            let stream = try LocalLLMEngine.shared.streamParsed(
                messages: localMessagesToSend,
                tools: localTools,
                modelURL: localModelStore.fileURL(for: record),
                options: LocalLLMGenerationOptions(
                    contextSize: max(1, overrides.localIntValue(for: "context_size") ?? overrides.localIntValue(for: "n_ctx") ?? record.effectiveContextSize),
                    maxOutputTokens: max(1, overrides.localIntValue(for: "max_output_tokens") ?? overrides.localIntValue(for: "max_tokens") ?? record.effectiveMaxOutputTokens),
                    temperature: overrides.localDoubleValue(for: "temperature") ?? record.temperature ?? (globalTemperatureEnabled ? aiTemperature : nil) ?? LocalModelRecord.defaultTemperature,
                    topP: overrides.localDoubleValue(for: "top_p") ?? record.topP ?? (globalTopPEnabled ? aiTopP : nil) ?? LocalModelRecord.defaultTopP,
                    gpuLayers: localGPULayers(overrides: overrides, record: record),
                    batchSize: overrides.localIntValue(for: "batch_size") ?? overrides.localIntValue(for: "n_batch") ?? record.effectiveBatchSize,
                    ubatchSize: overrides.localIntValue(for: "ubatch_size") ?? overrides.localIntValue(for: "n_ubatch") ?? record.effectiveUbatchSize,
                    kvOffload: overrides.localBoolValue(for: "kv_offload") ?? record.effectiveKVOffload,
                    flashAttention: overrides.localFlashAttentionValue(for: "flash_attn") ?? record.effectiveFlashAttention,
                    useModelCache: localModelCacheEnabled,
                    seed: overrides.localUInt32Value(for: "seed") ?? record.effectiveSeed,
                    topK: overrides.localIntValue(for: "top_k") ?? record.effectiveTopK,
                    minP: overrides.localDoubleValue(for: "min_p") ?? record.effectiveMinP,
                    repeatLastN: overrides.localIntValue(for: "repeat_last_n") ?? record.effectiveRepeatLastN,
                    repeatPenalty: overrides.localDoubleValue(for: "repeat_penalty") ?? record.effectiveRepeatPenalty,
                    frequencyPenalty: overrides.localDoubleValue(for: "frequency_penalty") ?? record.effectiveFrequencyPenalty,
                    presencePenalty: overrides.localDoubleValue(for: "presence_penalty") ?? record.effectivePresencePenalty,
                    grammar: overrides.localStringValue(for: "grammar") ?? record.effectiveGrammar,
                    ignoreEOS: overrides.localBoolValue(for: "ignore_eos") ?? record.effectiveIgnoreEOS,
                    samplerKinds: overrides.localSamplerKindsValue(for: "sampler_seq") ?? record.effectiveSamplerKinds,
                    chatTemplateKwargs: try overrides.localChatTemplateKwargsValue(),
                    advancedArguments: overrides.localStringValue(for: "llama_cli_args") ?? record.advancedArguments
                )
            )

            var outputForMetrics = ""
            var latestParsedOutput = LocalLLMToolCallParseResult(content: "", toolCalls: [])
            var firstTokenAt: Date?
            var lastTokenAt: Date?
            var reasoningStartedAt: Date?
            var reasoningLastDeltaAt: Date?
            var reasoningCompletedAt: Date?
            var speedSamples: [MessageResponseMetrics.SpeedSample] = []

            for try await parsedStreamingOutput in stream {
                guard !parsedStreamingOutput.content.isEmpty ||
                    parsedStreamingOutput.reasoningContent?.isEmpty == false ||
                    !parsedStreamingOutput.toolCalls.isEmpty else {
                    continue
                }
                let receivedAt = Date()
                if firstTokenAt == nil {
                    firstTokenAt = receivedAt
                }
                lastTokenAt = receivedAt
                latestParsedOutput = parsedStreamingOutput
                outputForMetrics = localResponseMetricText(from: parsedStreamingOutput)
                let parsedReasoning = parsedStreamingOutput.reasoningContent?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !parsedReasoning.isEmpty {
                    if reasoningStartedAt == nil {
                        reasoningStartedAt = receivedAt
                    }
                    reasoningLastDeltaAt = receivedAt
                }
                let parsedContent = parsedStreamingOutput.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if reasoningStartedAt != nil,
                   reasoningCompletedAt == nil,
                   (!parsedContent.isEmpty || !parsedStreamingOutput.toolCalls.isEmpty) {
                    reasoningCompletedAt = reasoningLastDeltaAt ?? receivedAt
                }

                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    let previousStreamingMessage = messages[index]
                    var shouldForceStreamingPublish = previousStreamingMessage.role != .assistant
                    if previousStreamingMessage.content.isEmpty, !parsedStreamingOutput.content.isEmpty {
                        shouldForceStreamingPublish = true
                    }
                    if (previousStreamingMessage.reasoningContent ?? "").isEmpty,
                       parsedStreamingOutput.reasoningContent?.isEmpty == false {
                        shouldForceStreamingPublish = true
                    }

                    messages[index].role = .assistant
                    messages[index].content = parsedStreamingOutput.content
                    messages[index].reasoningContent = parsedStreamingOutput.reasoningContent
                    if parsedStreamingOutput.toolCalls.isEmpty {
                        messages[index].toolCalls = nil
                        messages[index].toolCallsPlacement = nil
                    } else {
                        messages[index].toolCalls = parsedStreamingOutput.toolCalls
                        if messages[index].toolCallsPlacement == nil {
                            messages[index].toolCallsPlacement = inferredToolCallsPlacement(from: parsedStreamingOutput.content)
                        }
                    }
                    let previousToolSignature = (previousStreamingMessage.toolCalls ?? []).map { "\($0.id)|\($0.toolName)" }
                    let currentToolSignature = parsedStreamingOutput.toolCalls.map { "\($0.id)|\($0.toolName)" }
                    if previousToolSignature != currentToolSignature {
                        shouldForceStreamingPublish = true
                    }
                    messages[index].modelReference = requestLogContext.modelReference
                    if enableResponseSpeedMetrics || reasoningStartedAt != nil {
                        let estimatedTokens = estimatedCompletionTokens(from: outputForMetrics)
                        let speed: Double?
                        if enableResponseSpeedMetrics {
                            speed = streamingTokenPerSecond(
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
                            completionTokensForSpeed: enableResponseSpeedMetrics ? estimatedTokens : nil,
                            tokenPerSecond: speed,
                            isEstimated: enableResponseSpeedMetrics,
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

            let responseCompletedAt = Date()
            let totalDuration = max(0, responseCompletedAt.timeIntervalSince(requestStartedAt))
            let estimatedCompletionTokens = estimatedCompletionTokens(from: outputForMetrics)
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
            let parsedOutput = latestParsedOutput
            if reasoningStartedAt != nil && reasoningCompletedAt == nil {
                reasoningCompletedAt = reasoningLastDeltaAt ?? responseCompletedAt
            }
            if reasoningStartedAt == nil,
               !(parsedOutput.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasoningStartedAt = requestStartedAt
                reasoningCompletedAt = responseCompletedAt
            }
            var responseMessage = ChatMessage(
                role: .assistant,
                content: parsedOutput.content,
                requestedAt: requestStartedAt,
                reasoningContent: parsedOutput.reasoningContent,
                toolCalls: parsedOutput.toolCalls.isEmpty ? nil : parsedOutput.toolCalls,
                modelReference: requestLogContext.modelReference
            )
            if enableResponseSpeedMetrics || reasoningStartedAt != nil {
                responseMessage.responseMetrics = makeResponseMetrics(
                    requestStartedAt: requestStartedAt,
                    responseCompletedAt: enableResponseSpeedMetrics ? responseCompletedAt : nil,
                    totalResponseDuration: enableResponseSpeedMetrics ? totalDuration : nil,
                    timeToFirstToken: enableResponseSpeedMetrics ? firstTokenAt.map { max(0, $0.timeIntervalSince(requestStartedAt)) } : nil,
                    reasoningStartedAt: reasoningStartedAt,
                    reasoningCompletedAt: reasoningCompletedAt,
                    completionTokensForSpeed: enableResponseSpeedMetrics ? estimatedCompletionTokens : nil,
                    tokenPerSecond: enableResponseSpeedMetrics ? (finalSpeed ?? tokenPerSecond(tokens: estimatedCompletionTokens, elapsed: totalDuration)) : nil,
                    isEstimated: enableResponseSpeedMetrics,
                    speedSamples: enableResponseSpeedMetrics && !speedSamples.isEmpty ? speedSamples : nil
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
            messages = flushPendingStreamingMessages(
                messages,
                loadingMessageID: loadingMessageID,
                sessionID: currentSessionID,
                coalescer: &streamingPublishCoalescer
            )
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
            logger.error("本地推理失败: \(error.localizedDescription, privacy: .public)")
            messages = flushPendingStreamingMessages(
                messages,
                loadingMessageID: loadingMessageID,
                sessionID: currentSessionID,
                coalescer: &streamingPublishCoalescer
            )
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

    private func localGPULayers(overrides: [String: JSONValue], record: LocalModelRecord) -> Int {
        #if os(watchOS)
        return 0
        #else
        return overrides.localIntValue(for: "n_gpu_layers") ?? record.effectiveGPULayers
        #endif
    }
}

private func localResponseMetricText(from result: LocalLLMToolCallParseResult) -> String {
    var parts: [String] = []
    if let reasoningContent = result.reasoningContent, !reasoningContent.isEmpty {
        parts.append(reasoningContent)
    }
    if !result.content.isEmpty {
        parts.append(result.content)
    }
    for toolCall in result.toolCalls {
        parts.append(toolCall.toolName)
        parts.append(toolCall.arguments)
    }
    return parts.joined(separator: "\n")
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

    func localUInt32Value(for key: String) -> UInt32? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            if rawValue == -1 {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(exactly: rawValue)
        case .double(let rawValue):
            if rawValue == -1 {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(exactly: rawValue)
        case .string(let rawValue):
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-1" {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(trimmed)
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

    func localBoolValue(for key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        switch value {
        case .bool(let rawValue):
            return rawValue
        case .int(let rawValue):
            return rawValue != 0
        case .double(let rawValue):
            return rawValue != 0
        case .string(let rawValue):
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func localSamplerKindsValue(for key: String) -> [LocalLLMSamplerKind]? {
        guard let sequence = localStringValue(for: key) else { return nil }
        let samplerKinds = LocalLLMSamplerKind.parse(sequence)
        return samplerKinds.isEmpty ? nil : samplerKinds
    }

    func localFlashAttentionValue(for key: String) -> LocalLLMFlashAttentionMode? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            return LocalLLMFlashAttentionMode(rawValue: Int32(rawValue))
        case .double(let rawValue):
            return LocalLLMFlashAttentionMode(rawValue: Int32(rawValue))
        case .string(let rawValue):
            return LocalLLMFlashAttentionMode.parse(rawValue)
        case .bool(let rawValue):
            return rawValue ? .enabled : .disabled
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

    func localChatTemplateKwargsValue() throws -> [String: JSONValue] {
        guard let value = self["chat_template_kwargs"] else { return [:] }
        guard case .dictionary(let kwargs) = value else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话模板参数 chat_template_kwargs 必须是 JSON 对象。", comment: "Local LLM chat template kwargs object required"))
        }
        return kwargs
    }
}
