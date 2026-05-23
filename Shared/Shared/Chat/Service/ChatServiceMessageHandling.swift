// ============================================================================
// ChatServiceMessageHandling.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的消息写入、更新、转写回填、取消恢复与重试状态维护。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    // MARK: - 错误消息与消息写入

    public func addErrorMessage(_ content: String, sessionID: UUID? = nil, httpStatusCode: Int? = nil) {
        let resolvedSessionID: UUID
        if let sessionID {
            resolvedSessionID = sessionID
        } else if let currentSessionID = currentSessionSubject.value?.id {
            resolvedSessionID = currentSessionID
        } else {
            return
        }
        var messages = messagesSnapshot(for: resolvedSessionID)

        // 格式化错误内容，使其更简洁易读
        let (formattedContent, fullContent) = formatErrorContent(content, httpStatusCode: httpStatusCode)

        let loadingIndex: Int? = {
            // 优先使用当前请求记录的 loading 消息，避免误命中历史中的空 assistant（例如工具调用占位消息）。
            if let loadingMessageID = loadingMessageID(for: resolvedSessionID),
               let index = messages.firstIndex(where: { $0.id == loadingMessageID && $0.role == .assistant }) {
                return index
            }

            // 兼容重试场景：当 retryTargetMessageID 仍存在时，优先定位该消息。
            if let targetID = retryTargetMessageID,
               let index = messages.firstIndex(where: { $0.id == targetID && $0.role == .assistant }) {
                return index
            }

            // 回退策略仅允许替换“最后一条消息且为空 assistant”，避免破坏中间历史结构。
            guard let lastIndex = messages.indices.last else { return nil }
            let lastMessage = messages[lastIndex]
            let isLastLoadingAssistant = lastMessage.role == .assistant
                && lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return isLastLoadingAssistant ? lastIndex : nil
        }()

        func makeErrorMessage(
            _ requestedAt: Date?,
            _ prefix: String? = nil,
            metadata: ResponseAttemptMetadata? = nil
        ) -> ChatMessage {
            let resolvedContent: String
            let resolvedFullContent: String?
            if let prefix, !prefix.isEmpty {
                resolvedContent = "\(prefix)\n\n\(formattedContent)"
                if let fullContent {
                    resolvedFullContent = "\(prefix)\n\n\(fullContent)"
                } else {
                    resolvedFullContent = nil
                }
            } else {
                resolvedContent = formattedContent
                resolvedFullContent = fullContent
            }
            var message = ChatMessage(
                id: UUID(),
                role: .error,
                content: resolvedContent,
                requestedAt: requestedAt,
                fullErrorContent: resolvedFullContent
            )
            applyResponseAttemptMetadata(metadata, to: &message)
            return message
        }

        // 找到正在加载中的消息
        if let loadingIndex {
            let loadingMessage = finalizeInterruptedReasoningMessage(messages[loadingIndex])
            messages[loadingIndex] = loadingMessage
            let loadingAttemptMetadata = responseAttemptMetadata(from: loadingMessage)
            let shouldPreserveLoadingMessage = messageHasDisplayablePayload(loadingMessage)

            // 检查是否在重试 assistant 场景（有保留的旧 assistant）
            if let targetID = retryTargetMessageID,
               loadingMessage.id == targetID {
                if shouldPreserveLoadingMessage {
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else if let originalAssistant = retryTargetOriginalAssistantMessage {
                    messages[loadingIndex] = originalAssistant
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else if shouldPreserveLoadingMessage {
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else {
                    messages[loadingIndex] = ChatMessage(
                        id: loadingMessage.id,
                        role: .error,
                        content: "重试失败\n\n\(formattedContent)",
                        requestedAt: loadingMessage.requestedAt,
                        modelReference: loadingMessage.modelReference,
                        costEstimate: loadingMessage.costEstimate,
                        fullErrorContent: fullContent.map { "重试失败\n\n\($0)" },
                        responseGroupID: loadingMessage.responseGroupID,
                        responseAttemptID: loadingMessage.responseAttemptID,
                        responseAttemptIndex: loadingMessage.responseAttemptIndex,
                        selectedResponseAttemptID: loadingMessage.selectedResponseAttemptID ?? loadingMessage.responseAttemptID
                    )
                }

                retryTargetMessageID = nil
                retryTargetOriginalAssistantMessage = nil
                logger.error("重试失败，已根据输出情况保留或恢复 assistant，并追加错误气泡: \(content)")
            } else if shouldPreserveLoadingMessage {
                messages.insert(makeErrorMessage(loadingMessage.requestedAt, metadata: loadingAttemptMetadata), at: loadingIndex + 1)
                logger.error("流式内容已保留，并追加错误消息: \(content)")
            } else {
                // 正常场景：将 loading message 转为 error
                messages[loadingIndex] = ChatMessage(
                    id: loadingMessage.id,
                        role: .error,
                        content: formattedContent,
                        requestedAt: loadingMessage.requestedAt,
                        modelReference: loadingMessage.modelReference,
                        costEstimate: loadingMessage.costEstimate,
                        fullErrorContent: fullContent,
                        responseGroupID: loadingMessage.responseGroupID,
                        responseAttemptID: loadingMessage.responseAttemptID,
                        responseAttemptIndex: loadingMessage.responseAttemptIndex,
                    selectedResponseAttemptID: loadingMessage.selectedResponseAttemptID ?? loadingMessage.responseAttemptID
                )
                logger.error("错误消息已添加: \(content)")
            }
        } else {
            // 没有 loading message，直接添加错误
            messages.append(makeErrorMessage(nil))
            logger.error("错误消息已添加: \(content)")
        }

        persistAndPublishMessages(messages, for: resolvedSessionID)
    }

    // MARK: - 附件转写

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

    // MARK: - 消息生命周期与重试恢复

    func finalizeInterruptedReasoningMessage(_ message: ChatMessage, completedAt: Date = Date()) -> ChatMessage {
        var updated = message
        let reasoning = (updated.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return updated }

        var metrics = updated.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt ?? updated.requestedAt ?? completedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = completedAt
        }
        updated.responseMetrics = metrics
        return updated
    }

    func attachCostEstimateIfPossible(
        to message: inout ChatMessage,
        using context: RequestLogContext
    ) {
        message.modelReference = message.modelReference ?? context.modelReference
        message.costEstimate = ModelCostCalculator.estimateCost(
            usage: message.tokenUsage,
            pricing: context.modelPricing
        )
    }

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
        let newMessage = applyMessageRegexRules(to: newMessage, mode: .persist)
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
            targetMessage.modelReference = newMessage.modelReference ?? targetMessage.modelReference
            if newMessage.modelReference != nil {
                targetMessage.costEstimate = newMessage.costEstimate
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
                modelReference: newMessage.modelReference ?? messages[index].modelReference,
                costEstimate: newMessage.costEstimate ?? messages[index].costEstimate,
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

    // MARK: - 成就追踪

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
}
